import { assertEquals, assertMatch, assertRejects } from "@std/assert";
import { freeIdentityHash } from "../_shared/free-quota.ts";
import { type CreateJob, SupabaseRepository } from "../api/repository.ts";
import { ApiError } from "../api/errors.ts";
import type { SupabaseClient } from "@supabase/supabase-js";
const pepper = "mock-only-free-quota-pepper-00000000000000";
Deno.test("doğrulanmış e-posta küçük harf kimliğiyle, pepper'lı hash üretir", async () => {
  const first = await freeIdentityHash({
    id: "one",
    email: "USER@EXAMPLE.COM",
    email_confirmed_at: "today",
  }, pepper);
  assertEquals(
    first,
    await freeIdentityHash({
      id: "other",
      email: "user@example.com",
      email_confirmed_at: "today",
    }, pepper),
  );
  assertMatch(first, /^[a-f0-9]{64}$/);
  assertEquals(
    first ===
      await freeIdentityHash({
        id: "one",
        email: "user@example.com",
        email_confirmed_at: "today",
      }, pepper + "other"),
    false,
  );
});

const jobInput: CreateJob = {
  clientRequestId: "monthly-test-0001",
  language: "tr",
  audioSha256: "a".repeat(64),
  audioBytes: 1000,
  durationSeconds: 1,
};
function lazyFixture(eligible = true, fail = false) {
  const calls: string[] = [];
  const admin = {
    auth: {
      admin: {
        getUserById: (id: string) =>
          Promise.resolve({
            data: {
              user: eligible
                ? {
                  id,
                  email: "verified@example.com",
                  email_confirmed_at: "today",
                }
                : { id, is_anonymous: true },
            },
            error: null,
          }),
      },
    },
    rpc: (name: string) => {
      calls.push(name);
      return Promise.resolve({
        data: name === "quota_balance" ? [] : { id: "period" },
        error: fail ? { code: "XX000" } : null,
      });
    },
  } as unknown as SupabaseClient;
  return {
    calls,
    repo: new SupabaseRepository(
      admin,
      "fake",
      "fake-v1",
      "http://localhost",
      () => ({ pepper, seconds: 900 }),
    ),
  };
}
Deno.test("ilk iş ücretsiz ay hakkını rezervasyondan önce tembel verir", async () => {
  const { calls, repo } = lazyFixture();
  await repo.create("owner", jobInput);
  assertEquals(calls, ["grant_monthly_free_quota", "create_transcription_job"]);
});
Deno.test("kota sorgusu ay hakkını bakiyeden önce tembel verir", async () => {
  const { calls, repo } = lazyFixture();
  await repo.quota("owner");
  assertEquals(calls, ["grant_monthly_free_quota", "quota_balance"]);
});
Deno.test("uygun olmayan kimlik lazy yollarda diğer kotasını korur", async () => {
  const { calls, repo } = lazyFixture(false);
  await repo.quota("owner");
  await repo.create("owner", jobInput);
  assertEquals(calls, ["quota_balance", "create_transcription_job"]);
});
Deno.test("lazy hak DB hatası rezervasyonu ve eksik bakiye dönüşünü engeller", async () => {
  const { calls, repo } = lazyFixture(true, true);
  await assertRejects(() => repo.create("owner", jobInput), ApiError);
  await assertRejects(() => repo.quota("owner"), ApiError);
  assertEquals(calls, ["grant_monthly_free_quota", "grant_monthly_free_quota"]);
});
Deno.test("anonim ve doğrulanmamış kimlik ücretsiz kota alamaz", async () => {
  for (
    const user of [
      {
        id: "anon",
        is_anonymous: true,
        email: "user@example.com",
        email_confirmed_at: "today",
      },
      { id: "unverified", email: "user@example.com" },
      { id: "no-email" },
    ]
  ) {
    await assertRejects(
      () => freeIdentityHash(user, pepper),
      ApiError,
      "free_quota_not_eligible",
    );
  }
});
Deno.test("Apple sub kimliği e-postadan bağımsız; client metadata kullanılmaz", async () => {
  const identities = [{
    provider: "apple",
    identity_data: { sub: "verified-apple-sub" },
  }];
  assertEquals(
    await freeIdentityHash({ id: "one", identities }, pepper),
    await freeIdentityHash({
      id: "two",
      email: "changed@example.com",
      email_confirmed_at: "today",
      identities,
    }, pepper),
  );
});
Deno.test("repository güncel Auth kaydından miktar/kimlik türetir; ikinci RPC null=false", async () => {
  let args: Record<string, unknown> = {};
  let calls = 0;
  const admin = {
    auth: {
      admin: {
        getUserById: (id: string) =>
          Promise.resolve({
            data: {
              user: {
                id,
                email: "USER@example.com",
                email_confirmed_at: "today",
              },
            },
            error: null,
          }),
      },
    },
    rpc: (_name: string, input: Record<string, unknown>) => {
      args = input;
      calls++;
      return Promise.resolve({
        data: calls === 1 ? { id: "period" } : null,
        error: null,
      });
    },
  } as unknown as SupabaseClient;
  const repo = new SupabaseRepository(
    admin,
    "fake",
    "fake-v1",
    "http://localhost",
    () => ({ pepper, seconds: 900 }),
  );
  assertEquals(await repo.freeClaim("trusted"), true);
  assertEquals(await repo.freeClaim("trusted"), false);
  assertEquals(args.p_user_id, "trusted");
  assertEquals(args.p_seconds, 900);
  assertEquals(args.p_valid_for, undefined);
  assertEquals(
    args.p_identity_hash,
    await freeIdentityHash({
      id: "trusted",
      email: "user@example.com",
      email_confirmed_at: "today",
    }, pepper),
  );
});

Deno.test("anonim Auth kaydı config yokken de 403; miktar ayarı okunmaz", async () => {
  const admin = {
    auth: {
      admin: {
        getUserById: () =>
          Promise.resolve({
            data: { user: { id: "anon", is_anonymous: true } },
            error: null,
          }),
      },
    },
  } as unknown as SupabaseClient;
  let configCalls = 0;
  const repo = new SupabaseRepository(
    admin,
    "fake",
    "fake-v1",
    "http://localhost",
    () => {
      configCalls++;
      throw new Error("not configured");
    },
  );
  await assertRejects(
    () => repo.freeClaim("anon"),
    ApiError,
    "free_quota_not_eligible",
  );
  assertEquals(configCalls, 0);
});
