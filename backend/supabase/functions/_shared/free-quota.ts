import { ApiError } from "../api/errors.ts";
export interface FreeQuotaIdentity {
  id: string;
  is_anonymous?: boolean;
  email?: string;
  email_confirmed_at?: string;
  identities?: { provider: string; identity_data?: Record<string, unknown> }[];
}
export interface FreeQuotaConfig {
  pepper: string;
  seconds: number;
  validDays: number;
}
export function freeQuotaConfig(): FreeQuotaConfig {
  const pepper = Deno.env.get("FREE_QUOTA_PEPPER") ?? "";
  const seconds = Number(Deno.env.get("FREE_QUOTA_SECONDS"));
  const validDays = Number(Deno.env.get("FREE_QUOTA_VALID_DAYS"));
  if (
    pepper.length < 32 || !Number.isSafeInteger(seconds) || seconds < 1 ||
    seconds > 2147483647 ||
    !Number.isSafeInteger(validDays) || validDays < 1 || validDays > 365
  ) {
    throw new ApiError(503, "free_quota_not_configured");
  }
  return { pepper, seconds, validDays };
}
export function freeIdentity(user: FreeQuotaIdentity): string {
  if (user.is_anonymous) throw new ApiError(403, "free_quota_not_eligible");
  const apple = user.identities?.find((identity) =>
    identity.provider === "apple" &&
    typeof identity.identity_data?.sub === "string" &&
    identity.identity_data.sub.length > 0
  );
  const identity = apple
    ? "apple:" + apple.identity_data!.sub
    : user.email && user.email_confirmed_at
    ? "email:" + user.email.trim().toLowerCase()
    : null;
  if (!identity) throw new ApiError(403, "free_quota_not_eligible");
  return identity;
}
export async function freeIdentityHash(
  user: FreeQuotaIdentity,
  pepper: string,
): Promise<string> {
  const identity = freeIdentity(user);
  // HMAC-SHA256 pepper'ı kimlikten ayrı anahtar olarak bağlar; PII/log yok.
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(pepper),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return [
    ...new Uint8Array(
      await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(identity)),
    ),
  ]
    .map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
