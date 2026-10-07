// Yalnız atılabilir yerel Supabase. Gerçek pg_net/Auth/Storage/webhook zinciri.
import { createClient } from "@supabase/supabase-js";
import { assert, assertEquals } from "@std/assert";
import { inspectAudio } from "../backend/supabase/functions/_shared/audio.ts";
const env = (key: string) => {
  const value = Deno.env.get(key);
  if (!value) throw new Error(`Missing ${key}`);
  return value;
};
const url = env("SUPABASE_URL");
assert(
  ["http://127.0.0.1:54321", "http://localhost:54321"].includes(url),
  "Disposable local stack required",
);
const secret = env("DISPATCHER_SECRET");
assert(/^[a-f0-9]{64}$/.test(secret));
const admin = createClient(url, env("SUPABASE_SERVICE_ROLE_KEY"), {
  auth: { persistSession: false, autoRefreshToken: false },
});
const run = crypto.randomUUID();
let userId: string | undefined;
let priceId: number | undefined;
const paths: string[] = [];
const jobs: string[] = [];
let configured = false;
function checked<R extends { data: unknown; error: unknown }>(r: R): R["data"] {
  if (r.error) throw new Error("Supabase smoke setup failed");
  return r.data;
}
async function sql(query: string) {
  const child = new Deno.Command("psql", {
    args: [
      "-X",
      "-q",
      "-v",
      "ON_ERROR_STOP=1",
      "--dbname",
      "postgresql://postgres:postgres@127.0.0.1:54322/postgres",
    ],
    stdin: "piped",
    stdout: "piped",
    stderr: "piped",
  }).spawn();
  const writer = child.stdin.getWriter();
  await writer.write(new TextEncoder().encode(query));
  await writer.close();
  const output = await child.output();
  if (!output.success) {
    throw new Error(
      "Local SQL operation failed (details intentionally suppressed)",
    );
  }
}
let token: string;
async function api(
  path: string,
  body?: unknown,
  expected = 200,
  authenticated = true,
) {
  const r = await fetch(url + "/functions/v1/api" + path, {
    method: body === undefined ? "GET" : "POST",
    headers: {
      "Content-Type": "application/json",
      ...(authenticated ? { Authorization: "Bearer " + token } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const value = await r.json();
  assertEquals(
    r.status,
    expected,
    `HTTP code mismatch; error=${value.error?.code ?? "none"}`,
  );
  return value;
}
async function queue(bytes: Uint8Array, hashOverride?: string) {
  const hash = Array.from(
    new Uint8Array(
      await crypto.subtle.digest("SHA-256", new Uint8Array(bytes).buffer),
    ),
    (x) => x.toString(16).padStart(2, "0"),
  ).join("");
  const input = {
    clientRequestId: crypto.randomUUID(),
    language: "tr",
    audioSha256: hashOverride ?? hash,
    audioBytes: bytes.length,
    durationSeconds: 1,
  };
  const created = await api("/v1/transcription-jobs", input);
  const id = created.job.id;
  jobs.push(id);
  const row = checked(
    await admin.from("jobs").select("storage_path").eq("id", id).single(),
  );
  assert(row);
  paths.push(row.storage_path);
  const put = await fetch(created.upload.url, {
    method: "PUT",
    headers: created.upload.headers,
    body: new Uint8Array(bytes),
  });
  await put.text();
  assert(put.ok);
  assertEquals((await api("/v1/transcription-jobs", input)).upload, null); // bulgu 1
  await api(`/v1/transcription-jobs/${id}/uploaded`, {});
  return { id, input };
}
async function tickUntil(id: string, state: string) {
  for (let n = 0; n < 15; n++) {
    await sql("select public.tick_dispatcher();");
    await new Promise((resolve) => setTimeout(resolve, 700));
    const result = await api(`/v1/jobs/${id}`);
    if (result.job.status === state) return result;
    if (result.job.status === "failed" && state !== "failed") {
      throw new Error("Dispatch failed: " + result.job.errorCode);
    }
  }
  throw new Error("pg_net dispatcher did not reach " + state);
}
async function prepareCallback(
  item: { id: string; input: { audioBytes: number; audioSha256: string } },
  audio: Uint8Array,
) {
  const duration = await inspectAudio(
    audio,
    {
      audio_bytes: item.input.audioBytes,
      audio_sha256: item.input.audioSha256,
      claimed_duration_seconds: 1,
    },
    300,
    15 * 1024 * 1024,
  );
  checked(
    await admin.rpc("record_job_audio_check", {
      p_job_id: item.id,
      p_duration: duration,
    }),
  );
  const rows = checked(
    await admin.rpc("claim_job_for_submission", { p_job_id: item.id }),
  );
  assert(rows[0]);
  const requestId = "fake:" + item.id;
  checked(
    await admin.rpc("mark_job_submitted", {
      p_job_id: item.id,
      p_provider_request_id: requestId,
    }),
  );
  return {
    path: `/v1/providers/fake/callback/${item.id}/${rows[0].callback_token}`,
    requestId,
    duration,
  };
}
try {
  const password = crypto.randomUUID() + "Aa1!";
  const email = `dispatch-${run}@example.com`;
  const user = checked(
    await admin.auth.admin.createUser({ email, password, email_confirm: true }),
  );
  assert(user.user);
  userId = user.user.id;
  const client = createClient(url, env("SUPABASE_ANON_KEY"), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const session = checked(
    await client.auth.signInWithPassword({ email, password }),
  );
  assert(session.session);
  token = session.session.access_token;
  const price = checked(
    await admin.from("provider_prices").insert({
      provider: "fake",
      model: "fake-v1",
      price_version: run,
      usd_micros_per_minute: 0,
      valid_from: new Date(Date.now() - 60000).toISOString(),
    }).select("id").single(),
  );
  assert(price);
  priceId = price.id;
  checked(
    await admin.rpc("grant_quota", {
      p_user_id: userId,
      p_seconds: 60,
      p_starts_at: new Date(Date.now() - 60000).toISOString(),
      p_ends_at: new Date(Date.now() + 3600000).toISOString(),
      p_source: "manual",
      p_source_ref: run,
    }),
  );
  // Ham secret pg_net başlıklarına girmez. SQL çıktısı/sır hiçbir yerde loglanmaz.
  await sql(`begin;
    do $$begin if exists(select 1 from vault.secrets where name in ('dispatcher_url','dispatcher_secret')) then raise exception 'local test Vault must be empty'; end if; end;$$;
    select cron.alter_job((select jobid from cron.job where jobname='dispatch-transcriptions'), active:=false);
    select vault.create_secret('http://kong:8000/functions/v1/api/v1/internal/dispatch','dispatcher_url');
    select vault.create_secret('${secret}','dispatcher_secret'); commit;`);
  configured = true;
  await api("/v1/internal/dispatch", {}, 401); // user JWT yetmez
  const audio = await Deno.readFile(env("SMOKE_AUDIO_PATH"));
  const first = await queue(audio);
  const completed = await tickUntil(first.id, "succeeded");
  assertEquals(completed.result.transcript.schemaVersion, 1);
  assertEquals(completed.result.transcript.provider, "fake");
  const usage = checked(
    await admin.from("usage_ledger").select("seconds").eq("job_id", first.id),
  );
  assertEquals(usage?.length, 1);
  assertEquals(usage?.[0].seconds, 1);
  const duplicate = await queue(audio);
  const cb = await prepareCallback(duplicate, audio);
  const payload = {
    requestId: cb.requestId,
    eventKey: "duplicate-test",
    status: "succeeded",
    transcript: {
      schemaVersion: 1,
      provider: "fake",
      model: "fake-v1",
      language: "tr",
      durationSeconds: cb.duration,
      words: [{ text: "merhaba", start: 0.12, end: 0.48 }],
    },
  };
  await api(
    `/v1/providers/fake/callback/${duplicate.id}/${"0".repeat(64)}`,
    payload,
    404,
    false,
  );
  await api(
    cb.path,
    {
      ...payload,
      transcript: {
        ...payload.transcript,
        words: [{ text: "bad", start: 1, end: 0 }],
      },
    },
    400,
    false,
  );
  await api(cb.path, payload, 200, false);
  await api(cb.path, payload, 200, false);
  assertEquals(
    checked(
      await admin.from("usage_ledger").select("seconds").eq(
        "job_id",
        duplicate.id,
      ),
    )?.length,
    1,
  );
  assertEquals(
    checked(
      await admin.from("provider_events").select("id").eq(
        "job_id",
        duplicate.id,
      ).eq("kind", "webhook"),
    )?.length,
    1,
  );
  const resumed = await queue(audio);
  await prepareCallback(resumed, audio);
  await tickUntil(resumed.id, "succeeded");
  const attempts = checked(
    await admin.from("jobs").select("attempt_count").eq("id", resumed.id)
      .single(),
  );
  assertEquals(attempts?.attempt_count, 1);
  const long = await queue(await Deno.readFile(env("SMOKE_LONG_AUDIO_PATH")));
  const rejected = await tickUntil(long.id, "failed");
  assertEquals(rejected.job.errorCode, "audio_duration_mismatch");
  const longRow = checked(
    await admin.from("jobs").select("attempt_count").eq("id", long.id).single(),
  );
  assertEquals(longRow?.attempt_count, 0);
  assertEquals(
    checked(await admin.from("usage_ledger").select("id").eq("job_id", long.id))
      ?.length,
    0,
  );
  const badHash = await queue(audio, "0".repeat(64));
  assertEquals(
    (await tickUntil(badHash.id, "failed")).job.errorCode,
    "audio_hash_mismatch",
  );
  const failed = await queue(audio);
  const fcb = await prepareCallback(failed, audio);
  await api(
    fcb.path,
    {
      requestId: fcb.requestId,
      eventKey: "failed-test",
      status: "failed",
      errorCode: "provider_failed",
    },
    200,
    false,
  );
  const quota = await api("/v1/quota");
  assertEquals(
    quota.periods.reduce(
      (n: number, p: { reservedSeconds: number }) => n + p.reservedSeconds,
      0,
    ),
    0,
  );
  assertEquals(
    quota.periods.reduce(
      (n: number, p: { usedSeconds: number }) => n + p.usedSeconds,
      0,
    ),
    3,
  );
  console.log(
    "PASS CX-003: Vault/pg_net -> dispatcher -> fake webhook -> succeeded; duplicate tek defter; fake resume submit tekrarı yok; 10 sn/1 sn beyan ve yanlış hash submit olmadan reddedildi; failure kotayı bıraktı; bulgu 1 tekrar yükleme 200/null.",
  );
} finally {
  if (configured) {
    await sql(
      "delete from vault.secrets where name in ('dispatcher_url','dispatcher_secret'); select cron.alter_job((select jobid from cron.job where jobname='dispatch-transcriptions'),active:=true);",
    );
  }
  if (paths.length) {
    checked(await admin.storage.from("transcription-audio").remove(paths));
  }
  if (jobs.length) {
    checked(await admin.from("provider_events").delete().in("job_id", jobs));
  }
  if (userId) checked(await admin.auth.admin.deleteUser(userId));
  if (priceId !== undefined) {
    checked(await admin.from("provider_prices").delete().eq("id", priceId));
  }
}
