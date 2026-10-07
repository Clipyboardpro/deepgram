import type { ContentfulStatusCode } from "hono/utils/http-status";

const databaseCodes: Record<string, ContentfulStatusCode> = {
  invalid_callback: 400,
  audio_duration_mismatch: 400,
  invalid_job_state: 409,
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
export class ApiError extends Error {
  constructor(readonly status: ContentfulStatusCode, readonly code: string) {
    super(code);
  }
}
export function databaseError(
  error: { code?: string; message?: string },
): ApiError {
  if (
    (error.code === "P0001" || error.code === "P0002" ||
      error.code === "22023") &&
    error.message && databaseCodes[error.message]
  ) {
    return new ApiError(databaseCodes[error.message], error.message);
  }
  return new ApiError(500, "internal_error");
}
