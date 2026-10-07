import { assertEquals, assertMatch, assertRejects } from "@std/assert";
import { freeIdentityHash } from "../_shared/free-quota.ts";
import { SupabaseRepository } from "../api/repository.ts";
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
    () => ({ pepper, seconds: 60, validDays: 7 }),
  );
  assertEquals(await repo.freeClaim("trusted"), true);
  assertEquals(await repo.freeClaim("trusted"), false);
  assertEquals(args.p_user_id, "trusted");
  assertEquals(args.p_seconds, 60);
  assertEquals(args.p_valid_for, "7 days");
  assertEquals(
    args.p_identity_hash,
    await freeIdentityHash({
      id: "trusted",
      email: "user@example.com",
      email_confirmed_at: "today",
    }, pepper),
  );
});
