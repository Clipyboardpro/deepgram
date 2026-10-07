import { assertEquals, assertMatch } from "@std/assert";
import { createApp } from "../api/app.ts";
import { databaseError } from "../api/errors.ts";
import { FakeProvider } from "../_shared/provider.ts";
import type { JobRow, Repository } from "../api/repository.ts";

const id = "00000000-0000-4000-8000-000000000001";
const job: JobRow = {
  id,
  status: "queued",
  created_at: "2026-10-07T00:00:00Z",
  error_code: null,
  storage_path: "private",
  upload_expires_at: "2099-01-01T00:00:00Z",
  audio_bytes: 100,
};
function fixture() {
  const calls: string[] = [];
  const repo: Repository = {
    authenticate: (token) =>
      Promise.resolve(token === "valid" ? "trusted-user" : null),
    create: (user) => {
      calls.push(user);
      return Promise.resolve(job);
    },
    get: (user) => {
      calls.push(user);
      return Promise.resolve(job);
    },
    uploaded: (user) => {
      calls.push(user);
      return Promise.resolve(job);
    },
    cancel: (user) => {
      calls.push(user);
      return Promise.resolve(job);
    },
    upload: () => Promise.resolve(null),
    result: () => Promise.resolve(null),
    quota: () => Promise.resolve([]),
  };
  return { app: createApp(repo), repo, calls };
}
const body = {
  clientRequestId: "request-0001",
  language: "tr",
  audioSha256: "a".repeat(64),
  audioBytes: 100,
  durationSeconds: 1,
};
const headers = {
  Authorization: "Bearer valid",
  "Content-Type": "application/json",
};
Deno.test("kimliksiz/geçersiz JWT hiçbir iş okuyamaz", async () => {
  const { app, calls } = fixture();
  for (const token of [undefined, "Bearer invalid", "Basic valid"]) {
    const response = await app.request(`/v1/jobs/${id}`, {
      headers: token ? { Authorization: token } : {},
    });
    assertEquals(response.status, 401);
    assertEquals((await response.json()).error.code, "not_authenticated");
  }
  assertEquals(calls, []);
});
Deno.test("istemci userId/provider/model seçemez", async () => {
  for (
    const extra of [{ userId: "attacker" }, { provider: "fake" }, {
      model: "expensive",
    }]
  ) {
    const { app, calls } = fixture();
    const r = await app.request("/v1/transcription-jobs", {
      method: "POST",
      headers,
      body: JSON.stringify({ ...body, ...extra }),
    });
    assertEquals(r.status, 400);
    await r.json();
    assertEquals(calls, []);
  }
});
Deno.test("yalnız Auth tarafından doğrulanmış kullanıcı repository'ye gider", async () => {
  const { app, calls } = fixture();
  const r = await app.request("/v1/transcription-jobs", {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
  assertEquals(r.status, 200);
  assertEquals((await r.json()).upload, null);
  assertEquals(calls, ["trusted-user"]);
});
Deno.test("iş görünümü storage yolu ve iç alanları sızdırmaz", async () => {
  const { app } = fixture();
  const r = await app.request(`/v1/jobs/${id}`, { headers });
  assertEquals(r.headers.get("cache-control"), "no-store");
  assertEquals(await r.json(), {
    job: { id, status: "queued", createdAt: job.created_at, errorCode: null },
    result: null,
  });
});
Deno.test("JSON, tür, süre, hash, UUID ve gövde sınırları", async () => {
  const { app } = fixture();
  for (
    const data of [
      null,
      [],
      { ...body, durationSeconds: 1.5 },
      { ...body, audioBytes: 0 },
      { ...body, language: "turkish" },
      { ...body, audioSha256: "short" },
    ]
  ) {
    const r = await app.request("/v1/transcription-jobs", {
      method: "POST",
      headers,
      body: JSON.stringify(data),
    });
    assertEquals(r.status, 400);
    await r.json();
  }
  for (
    const [raw, contentType, expected] of [["{", "application/json", 400], [
      "{}",
      "text/plain",
      415,
    ], [" ".repeat(8193), "application/json", 413]] as const
  ) {
    const r = await app.request("/v1/transcription-jobs", {
      method: "POST",
      headers: { ...headers, "Content-Type": contentType },
      body: raw,
    });
    assertEquals(r.status, expected);
    await r.json();
  }
  const r = await app.request("/v1/jobs/not-a-uuid", { headers });
  assertEquals(r.status, 400);
  await r.json();
});
Deno.test("beklenmedik hata ayrıntısı veya anahtar dışarı çıkmaz", async () => {
  const { repo } = fixture();
  repo.get = () => {
    throw new Error("service_role=SECRET postgres password");
  };
  const r = await createApp(repo).request(`/v1/jobs/${id}`, { headers });
  assertEquals(r.status, 500);
  const value = await r.json();
  assertEquals(value.error.code, "internal_error");
  assertEquals(Object.keys(value.error).sort(), ["code", "requestId"]);
  assertMatch(value.error.requestId, /^[a-f0-9-]{36}$/);
});
Deno.test("transcript tam result.transcript konumunda ve ses sıfırında döner", async () => {
  const { repo } = fixture();
  const transcript = await new FakeProvider().result("fake:job");
  repo.result = () =>
    Promise.resolve({ transcript, expiresAt: "2026-10-14T00:00:00Z" });
  const r = await createApp(repo).request(`/v1/jobs/${id}`, { headers });
  const value = await r.json();
  assertEquals(value.result.transcript, transcript);
  assertEquals(value.result.transcript.words[0].start, 0.12);
  assertEquals("sourceOffset" in value.result.transcript, false);
});
Deno.test("SQLSTATE ve beyaz listedeki mesaj birlikte eşlenir", () => {
  const expected: Record<string, number> = {
    insufficient_quota: 402,
    rate_limited: 429,
    audio_too_long: 413,
    audio_too_large: 413,
    ai_jobs_disabled: 503,
    daily_budget_exceeded: 503,
    price_not_configured: 503,
    client_request_id_reused: 409,
    upload_expired: 409,
    job_not_cancelable: 409,
    job_not_found: 404,
    profile_not_found: 404,
    invalid_duration: 400,
    invalid_seconds: 400,
  };
  for (const [message, status] of Object.entries(expected)) {
    assertEquals(databaseError({ code: "P0001", message }).status, status);
    assertEquals(
      databaseError({ code: "42P01", message }).code,
      "internal_error",
    );
  }
  assertEquals(
    databaseError({ code: "P0001", message: "private detail" }).code,
    "internal_error",
  );
});
