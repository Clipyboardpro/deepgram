// Canlı mutasyon: yalnız açık onayla çalıştır. FakeProvider dışında durur.
import { createClient } from "@supabase/supabase-js";
import { assert, assertEquals } from "@std/assert";
const env = (name: string) => {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing ${name}`);
  return value;
};
const url = env("SUPABASE_URL");
assertEquals(url, "https://yjtpfyowzyszeoitlubx.supabase.co");
assertEquals(env("LIVE_SMOKE_APPROVED"), "fake-create-and-cleanup");
const admin = createClient(url, env("SUPABASE_SERVICE_ROLE_KEY"), {
  auth: { persistSession: false, autoRefreshToken: false },
});
const checked = <R extends { data: unknown; error: unknown }>(
  r: R,
): R["data"] => {
  if (r.error) {
    throw new Error("Live smoke operation failed (details suppressed)");
  }
  return r.data;
};
const users: string[] = [];
const paths: string[] = [];
const jobs: string[] = [];
const run = crypto.randomUUID();
async function identity() {
  const email = `codex-smoke-${crypto.randomUUID()}@example.com`;
  const password = crypto.randomUUID() + "Aa1!";
  const user = checked(
    await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
    }),
  ).user;
  assert(user);
  users.push(user.id);
  const client = createClient(url, env("SUPABASE_ANON_KEY"), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const session =
    checked(await client.auth.signInWithPassword({ email, password })).session;
  assert(session);
  return { id: user.id, token: session.access_token, client };
}
async function api(
  path: string,
  token: string,
  body?: unknown,
  expected = 200,
  method = body === undefined ? "GET" : "POST",
) {
  const r = await fetch(url + "/functions/v1/api" + path, {
    method,
    headers: {
      Authorization: "Bearer " + token,
      "Content-Type": "application/json",
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  assertEquals(
    r.status,
    expected,
    "Live API status mismatch; tokens suppressed",
  );
  return await r.json();
}
try {
  const owner = await identity();
  const other = await identity();
  assertEquals(
    await api("/v1/quota/free-claim", owner.token, undefined, 200, "POST"),
    { granted: true },
  );
  assertEquals(
    await api("/v1/quota/free-claim", owner.token, undefined, 200, "POST"),
    { granted: false },
  );
  const quota = await api("/v1/quota", owner.token);
  assertEquals(quota.periods.length, 1);
  assertEquals(quota.periods[0].grantedSeconds, 900);
  assertEquals(quota.periods[0].availableSeconds, 900);
  const lazy = await api("/v1/quota", other.token);
  assertEquals(lazy.periods[0].grantedSeconds, 900);
  const audio = await Deno.readFile(env("SMOKE_AUDIO_PATH"));
  const hash = [...new Uint8Array(await crypto.subtle.digest("SHA-256", audio))]
    .map((byte) => byte.toString(16).padStart(2, "0")).join("");
  const body = {
    clientRequestId: run,
    language: "tr",
    audioSha256: hash,
    audioBytes: audio.length,
    durationSeconds: 1,
  };
  const created = await api("/v1/transcription-jobs", owner.token, body);
  const id: string = created.job.id;
  jobs.push(id);
  const row = checked(
    await admin.from("jobs").select("storage_path,provider").eq("id", id)
      .single(),
  );
  assert(row);
  paths.push(row.storage_path);
  assertEquals(row.provider, "fake");
  await api(`/v1/jobs/${id}`, other.token, undefined, 404);
  assertEquals(
    checked(await other.client.from("jobs").select("id").eq("id", id)),
    [],
  );
  const uploaded = await fetch(created.upload.url, {
    method: created.upload.method,
    headers: created.upload.headers,
    body: audio,
  });
  assert(uploaded.ok, "Signed upload failed; URL suppressed");
  await uploaded.body?.cancel();
  assertEquals(
    (await api("/v1/transcription-jobs", owner.token, body)).upload,
    null,
  );
  await api(`/v1/transcription-jobs/${id}/uploaded`, owner.token, {});
  // Dispatcher HTTP çağrısı yapmayız; gerçek dakikalık pg_cron + pg_net çalışsın.
  let result;
  for (let poll = 0; poll < 36; poll++) {
    result = await api(`/v1/jobs/${id}`, owner.token);
    if (result.job.status === "succeeded") break;
    assert(
      !["failed", "unknown_provider_state"].includes(result.job.status),
      "Fake job failed",
    );
    await new Promise((resolve) => setTimeout(resolve, 5000));
  }
  assertEquals(result.job.status, "succeeded");
  assertEquals(result.result.transcript.schemaVersion, 1);
  assertEquals(
    checked(await admin.from("usage_ledger").select("id").eq("job_id", id))
      ?.length,
    1,
  );
  console.log(
    "PASS CX-008: live free-claim true/false, GET quota 900 sn/lazy; Auth/RLS/upload, natural cron/net -> fake succeeded; one ledger.",
  );
} finally {
  if (paths.length) {
    checked(await admin.storage.from("transcription-audio").remove(paths));
  }
  if (jobs.length) {
    checked(await admin.from("provider_events").delete().in("job_id", jobs));
  }
  // Yalnız bu testin hak tombstone'ları da temizlenir; gerçek haklar korunur.
  if (users.length) {
    checked(
      await admin.from("monthly_free_quota_claims").delete().in(
        "user_id",
        users,
      ),
    );
  }
  for (const id of users) checked(await admin.auth.admin.deleteUser(id));
  console.log(
    "Only this run's temporary Auth users/audio/events cleaned; production configuration preserved.",
  );
}
