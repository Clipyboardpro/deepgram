import { assertEquals } from "@std/assert";
import { createPipeline } from "../api/pipeline.ts";
import { AudioError } from "../_shared/audio.ts";
import { dispatchHeaders, verifyDispatch } from "../_shared/dispatch-auth.ts";
import { FakeProvider } from "../_shared/provider.ts";
import type {
  DispatchJob,
  PipelineRepository,
} from "../api/pipeline-repository.ts";
const secret = "test-only-not-a-real-secret-000000000000";
const id = "00000000-0000-4000-8000-000000000001";
const token = "a".repeat(64);
function fixture() {
  const job: DispatchJob = {
    id,
    status: "queued",
    storage_path: "private",
    language: "tr",
    provider: "fake",
    model: "fake-v1",
    audio_bytes: 100,
    audio_sha256: "b".repeat(64),
    claimed_duration_seconds: 1,
    inspected_duration_seconds: null,
    provider_request_id: null,
  };
  const calls: string[] = [];
  let pending = true;
  let receipt: string | null = null;
  const repo: PipelineRepository = {
    dequeue: () =>
      Promise.resolve(
        pending ? [{ msg_id: 1, read_count: 1, job_id: id }] : [],
      ),
    ack: () => {
      pending = false;
      calls.push("ack");
      return Promise.resolve();
    },
    get: () => Promise.resolve({ ...job }),
    preflight: () => {
      job.inspected_duration_seconds = 1;
      calls.push("check");
      return Promise.resolve();
    },
    claim: () => {
      calls.push("claim");
      job.submission_started_at = new Date().toISOString();
      return Promise.resolve({ job_id: id, callback_token: token });
    },
    rememberSubmission: (_id, requestId) => {
      receipt = requestId;
      calls.push("receipt");
      return Promise.resolve();
    },
    resumeSubmission: () => {
      if (
        receipt && ["queued", "unknown_provider_state"].includes(job.status)
      ) {
        job.provider_request_id = receipt;
        job.status = "submitted";
        calls.push("resume");
      }
      return Promise.resolve();
    },
    markUnknown: () => {
      job.status = "unknown_provider_state";
      calls.push("unknown");
      return Promise.resolve();
    },
    submitted: (_id, requestId) => {
      job.status = "submitted";
      job.provider_request_id = requestId;
      calls.push("submitted");
      return Promise.resolve();
    },
    recover: () => {
      calls.push("recover");
      return Promise.resolve(token);
    },
    signedAudio: () => Promise.resolve("https://not-called.invalid/audio"),
    verify: (_provider, _id, supplied) =>
      Promise.resolve(supplied === token ? { ...job } : null),
    callback: () => {
      if (job.status !== "succeeded") {
        job.status = "succeeded";
        calls.push("complete");
      }
      return Promise.resolve();
    },
    fail: (_id, code) => {
      job.status = "failed";
      calls.push(code);
      return Promise.resolve();
    },
  };
  const provider = new FakeProvider();
  const submit = provider.submit.bind(provider);
  provider.submit = (input) => {
    calls.push("submit");
    return submit(input);
  };
  const app = createPipeline({
    repo,
    secret,
    publicUrl: "https://project.invalid",
    provider,
    retryDelayMs: 0,
  });
  return { app, repo, job, calls, provider };
}
Deno.test("dispatcher imzasız veya user JWT ile tetiklenemez", async () => {
  const { app, calls } = fixture();
  for (
    const headers of [
      {},
      { Authorization: "Bearer userJWT" },
      await dispatchHeaders("wrong-secret"),
    ]
  ) {
    const r = await app.request("/v1/internal/dispatch", {
      method: "POST",
      headers,
    });
    assertEquals(r.status, 401);
    await r.json();
  }
  assertEquals(calls, []);
});
Deno.test("HMAC süresi ve imzası doğrulanır; secret başlığa çıkmaz", async () => {
  const now = Date.now();
  const headers = new Headers(await dispatchHeaders(secret, now));
  assertEquals(await verifyDispatch(headers, secret, now), true);
  assertEquals(await verifyDispatch(headers, secret, now + 61000), false);
  assertEquals(await verifyDispatch(headers, "other", now), false);
  assertEquals(JSON.stringify([...headers]).includes(secret), false);
});
Deno.test("check -> claim -> submit -> submitted -> webhook -> ack sırası", async () => {
  const { app, calls, job } = fixture();
  const r = await app.request("/v1/internal/dispatch", {
    method: "POST",
    headers: await dispatchHeaders(secret),
  });
  assertEquals(await r.json(), { acknowledged: 1, deferred: 0 });
  assertEquals(job.status, "succeeded");
  assertEquals(calls, [
    "check",
    "claim",
    "submit",
    "receipt",
    "submitted",
    "complete",
    "ack",
  ]);
});
Deno.test("makul olmayan ses submit olmadan başarısız ve ack olur", async () => {
  const { app, repo, calls } = fixture();
  repo.preflight = () => {
    throw new AudioError("audio_duration_mismatch");
  };
  const r = await app.request("/v1/internal/dispatch", {
    method: "POST",
    headers: await dispatchHeaders(secret),
  });
  assertEquals(await r.json(), { acknowledged: 1, deferred: 0 });
  assertEquals(calls, ["audio_duration_mismatch", "ack"]);
});
Deno.test("kesilen fake callback sonraki kirada submit tekrarı olmadan toparlanır", async () => {
  const { app, job, calls } = fixture();
  job.status = "submitted";
  job.provider_request_id = "fake:" + id;
  job.inspected_duration_seconds = 1;
  const r = await app.request("/v1/internal/dispatch", {
    method: "POST",
    headers: await dispatchHeaders(secret),
  });
  assertEquals(await r.json(), { acknowledged: 1, deferred: 0 });
  assertEquals(calls, ["recover", "complete", "ack"]);
});
Deno.test("geçersiz callback token/provider 404; bozuk transcript 400", async () => {
  const { app, job } = fixture();
  job.status = "submitted";
  job.provider_request_id = "fake:" + id;
  job.inspected_duration_seconds = 1;
  for (
    const [name, supplied, expected] of [["fake", "b".repeat(64), 404], [
      "deepgram",
      token,
      404,
    ], ["fake", token, 400]] as const
  ) {
    const r = await app.request(
      `/v1/providers/${name}/callback/${id}/${supplied}`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: "{}",
      },
    );
    assertEquals(r.status, expected);
    await r.json();
  }
});
Deno.test("callback DB kesintisi ack yapmaz; lease tekrar görünür", async () => {
  const { app, repo, calls } = fixture();
  repo.callback = () => {
    throw new Error("do not leak database details");
  };
  const r = await app.request("/v1/internal/dispatch", {
    method: "POST",
    headers: await dispatchHeaders(secret),
  });
  assertEquals(await r.json(), { acknowledged: 0, deferred: 1 });
  assertEquals(calls.includes("ack"), false);
});
Deno.test("terminal işte sağlayıcıya yeniden gönderim olmaz", async () => {
  const { app, job, calls } = fixture();
  job.status = "canceled";
  const r = await app.request("/v1/internal/dispatch", {
    method: "POST",
    headers: await dispatchHeaders(secret),
  });
  await r.json();
  assertEquals(calls, ["ack"]);
});
Deno.test("submit sonucu belirsizse kör tekrar/ack yok", async () => {
  const { repo, provider, calls } = fixture();
  provider.submit = () => {
    calls.push("submit");
    throw new Error("timeout");
  };
  const app = createPipeline({
    repo,
    secret,
    publicUrl: "https://project.invalid",
    provider,
  });
  const r = await app.request("/v1/internal/dispatch", {
    method: "POST",
    headers: await dispatchHeaders(secret),
  });
  assertEquals(await r.json(), { acknowledged: 0, deferred: 1 });
  assertEquals(calls, ["check", "claim", "submit", "unknown"]);
});

Deno.test("submit kabulünden sonra ilk mark hatası aynı requestId ile toparlanır", async () => {
  const { app, repo, job, calls } = fixture();
  const submitted = repo.submitted;
  const ids: string[] = [];
  repo.submitted = (jobId, requestId) => {
    ids.push(requestId);
    if (ids.length === 1) throw new Error("temporary DB outage");
    return submitted(jobId, requestId);
  };
  const response = await app.request("/v1/internal/dispatch", {
    method: "POST",
    headers: await dispatchHeaders(secret),
  });
  assertEquals(await response.json(), { acknowledged: 1, deferred: 0 });
  assertEquals(ids, ["fake:" + id, "fake:" + id]);
  assertEquals(job.provider_request_id, "fake:" + id);
  assertEquals(job.status, "succeeded");
  assertEquals(calls.filter((call) => call === "submit").length, 1);
  assertEquals(calls.filter((call) => call === "claim").length, 1);
});

Deno.test("kalıcı mark hatasında alındı sonraki kirada yeniden submit olmadan kullanılır", async () => {
  const { app, repo, job, calls } = fixture();
  let attempts = 0;
  repo.submitted = () => {
    attempts++;
    throw new Error("DB mark unavailable");
  };
  // İmzayı her lease için tekrar üret.
  const first = await app.request("/v1/internal/dispatch", {
    method: "POST",
    headers: await dispatchHeaders(secret),
  });
  assertEquals(await first.json(), { acknowledged: 0, deferred: 1 });
  assertEquals(attempts, 3);
  assertEquals(job.status, "queued");
  const second = await app.request("/v1/internal/dispatch", {
    method: "POST",
    headers: await dispatchHeaders(secret),
  });
  assertEquals(await second.json(), { acknowledged: 1, deferred: 0 });
  assertEquals(job.status, "succeeded");
  assertEquals(calls.filter((call) => call === "submit").length, 1);
  assertEquals(calls.includes("resume"), true);
});
