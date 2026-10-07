import { createClient } from "@supabase/supabase-js";
import { assert, assertEquals } from "@std/assert";
const required = (key: string) => {
  const value = Deno.env.get(key);
  if (!value) throw new Error(`Missing ${key}`);
  return value;
};
const url = required("SUPABASE_URL");
assert(
  ["http://127.0.0.1:54321", "http://localhost:54321"].includes(url),
  "Disposable local stack only",
);
const admin = createClient(url, required("SUPABASE_SERVICE_ROLE_KEY"), {
  auth: { persistSession: false, autoRefreshToken: false },
});
const anon = required("SUPABASE_ANON_KEY");
const run = crypto.randomUUID();
const users: string[] = [];
const paths: string[] = [];
let priceId: number | undefined;
function checked<R extends { data: unknown; error: unknown }>(
  response: R,
): R["data"] {
  if (response.error) {
    throw new Error("Supabase setup/cleanup operation failed");
  }
  return response.data;
}
async function identity() {
  const email = `smoke-${crypto.randomUUID()}@example.com`;
  const password = crypto.randomUUID() + "Aa1!";
  const created = checked(
    await admin.auth.admin.createUser({ email, password, email_confirm: true }),
  );
  assert(created.user);
  users.push(created.user.id);
  const client = createClient(url, anon, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const session = checked(
    await client.auth.signInWithPassword({ email, password }),
  );
  assert(session.session);
  return { id: created.user.id, token: session.session.access_token };
}
async function api(
  path: string,
  token: string | null,
  method = "GET",
  body?: unknown,
  expected = 200,
) {
  const response = await fetch(`${url}/functions/v1/api${path}`, {
    method,
    headers: {
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      "Content-Type": "application/json",
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const value = await response.json();
  assertEquals(
    response.status,
    expected,
    `Unexpected status: ${method} ${path}; code=${value.error?.code ?? "none"}`,
  );
  return value;
}
try {
  const owner = await identity();
  const other = await identity();
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
      p_user_id: owner.id,
      p_seconds: 60,
      p_starts_at: new Date(Date.now() - 60000).toISOString(),
      p_ends_at: new Date(Date.now() + 3600000).toISOString(),
      p_source: "manual",
      p_source_ref: run,
    }),
  );
  const audio = await Deno.readFile(required("SMOKE_AUDIO_PATH"));
  const hash = Array.from(
    new Uint8Array(await crypto.subtle.digest("SHA-256", audio)),
  ).map((x) => x.toString(16).padStart(2, "0")).join("");
  const input = {
    clientRequestId: run,
    language: "tr",
    audioSha256: hash,
    audioBytes: audio.length,
    durationSeconds: 1,
  };
  assertEquals(
    (await api("/v1/quota", null, "GET", undefined, 401)).error.code,
    "not_authenticated",
  );
  const created = await api(
    "/v1/transcription-jobs",
    owner.token,
    "POST",
    input,
  );
  assertEquals(created.job.status, "awaiting_upload");
  assert(created.upload.url);
  const id = created.job.id;
  const row = checked(
    await admin.from("jobs").select("storage_path").eq("id", id).single(),
  );
  assert(row);
  paths.push(row.storage_path);
  const retry = await api("/v1/transcription-jobs", owner.token, "POST", input);
  assertEquals(retry.job.id, id);
  assertEquals(
    (await api("/v1/transcription-jobs", owner.token, "POST", {
      ...input,
      audioSha256: "0".repeat(64),
    }, 409)).error.code,
    "client_request_id_reused",
  );
  await api("/v1/quota", "invalid-token", "GET", undefined, 401);
  const quota = await api("/v1/quota", owner.token);
  assertEquals(quota.periods[0].reservedSeconds, 1);
  assertEquals(
    (await api(`/v1/jobs/${id}`, other.token, "GET", undefined, 404)).error
      .code,
    "job_not_found",
  );
  await api(
    `/v1/transcription-jobs/${id}/uploaded`,
    other.token,
    "POST",
    undefined,
    404,
  );
  await api(
    `/v1/transcription-jobs/${id}/cancel`,
    other.token,
    "POST",
    undefined,
    404,
  );
  assertEquals(
    (await api(
      `/v1/transcription-jobs/${id}/uploaded`,
      owner.token,
      "POST",
      undefined,
      409,
    )).error.code,
    "upload_not_found",
  );
  assertEquals(
    (await api("/v1/transcription-jobs", other.token, "POST", {
      ...input,
      clientRequestId: crypto.randomUUID(),
    }, 402)).error.code,
    "insufficient_quota",
  );
  const put = await fetch(created.upload.url, {
    method: created.upload.method,
    headers: created.upload.headers,
    body: audio,
  });
  await put.text();
  assert(put.ok, `Signed upload HTTP ${put.status}`);
  const afterUploadRetry = await api(
    "/v1/transcription-jobs",
    owner.token,
    "POST",
    input,
  );
  assertEquals(afterUploadRetry.job.id, id);
  assertEquals(afterUploadRetry.upload, null);
  assertEquals(
    (await api(`/v1/transcription-jobs/${id}/uploaded`, owner.token, "POST"))
      .job.status,
    "queued",
  );
  assertEquals(
    (await api(`/v1/transcription-jobs/${id}/uploaded`, owner.token, "POST"))
      .job.status,
    "queued",
  );
  const fetched = await api(`/v1/jobs/${id}`, owner.token);
  assertEquals(fetched.job.status, "queued");
  assertEquals(fetched.result, null);
  assertEquals(Object.keys(fetched.job).sort(), [
    "createdAt",
    "errorCode",
    "id",
    "status",
  ]);
  assertEquals(
    (await api(`/v1/transcription-jobs/${id}/cancel`, owner.token, "POST")).job
      .status,
    "canceled",
  );
  assertEquals(
    (await api(`/v1/transcription-jobs/${id}/cancel`, owner.token, "POST")).job
      .status,
    "canceled",
  );
  assertEquals(
    (await api("/v1/quota", owner.token)).periods[0].reservedSeconds,
    0,
  );
  assertEquals(await api("/v1/quota/free-claim", owner.token, "POST"), {
    granted: true,
  });
  assertEquals(await api("/v1/quota/free-claim", owner.token, "POST"), {
    granted: false,
  });
  const freePeriods = (await api("/v1/quota", owner.token)).periods.filter((
    period: { source: string },
  ) => period.source === "free");
  assertEquals(freePeriods.length, 1);
  assertEquals(freePeriods[0].grantedSeconds, 60);
  console.log(
    "PASS: gerçek Auth/JWT, kota, idempotency, sahiplik, signed upload, queued GET, cancel; dispatcher yok.",
  );
} finally {
  if (paths.length) {
    checked(await admin.storage.from("transcription-audio").remove(paths));
  }
  for (const id of users) checked(await admin.auth.admin.deleteUser(id));
  if (priceId !== undefined) {
    checked(await admin.from("provider_prices").delete().eq("id", priceId));
  }
}
