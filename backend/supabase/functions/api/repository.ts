import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { ApiError, databaseError } from "./errors.ts";
import type { Transcript } from "../_shared/provider.ts";
import {
  freeIdentity,
  freeIdentityHash,
  type FreeQuotaConfig,
  freeQuotaConfig,
} from "../_shared/free-quota.ts";

export interface CreateJob {
  clientRequestId: string;
  language: string;
  audioSha256: string;
  audioBytes: number;
  durationSeconds: number;
}
export interface JobRow {
  id: string;
  status: string;
  storage_path: string;
  upload_expires_at: string;
  created_at: string;
  error_code: string | null;
  audio_bytes: number;
}
export interface Upload {
  url: string;
  method: "PUT";
  headers: { "Content-Type": string };
  expiresAt: string;
}
export interface JobResult {
  transcript: Transcript;
  expiresAt: string;
}
export interface QuotaPeriod {
  period_id: string;
  source: string;
  starts_at: string;
  ends_at: string;
  granted_seconds: number;
  used_seconds: number;
  reserved_seconds: number;
  available_seconds: number;
}
export interface Repository {
  authenticate(token: string): Promise<string | null>;
  create(userId: string, input: CreateJob): Promise<JobRow>;
  get(userId: string, id: string): Promise<JobRow>;
  uploaded(userId: string, id: string): Promise<JobRow>;
  cancel(userId: string, id: string): Promise<JobRow>;
  upload(job: JobRow): Promise<Upload | null>;
  result(userId: string, id: string): Promise<JobResult | null>;
  quota(userId: string): Promise<QuotaPeriod[]>;
  freeClaim(userId: string): Promise<boolean>;
}
const bucket = "transcription-audio";
const columns =
  "id,status,storage_path,upload_expires_at,created_at,error_code,audio_bytes";
export class SupabaseRepository implements Repository {
  constructor(
    private readonly admin: SupabaseClient,
    private readonly provider: string,
    private readonly model: string,
    private readonly externalUrl: string,
    private readonly freeConfig: () => FreeQuotaConfig = freeQuotaConfig,
  ) {}
  async authenticate(token: string): Promise<string | null> {
    const { data, error } = await this.admin.auth.getUser(token);
    return error ? null : data.user?.id ?? null;
  }
  private async rpc<T>(
    name: string,
    args: Record<string, unknown>,
  ): Promise<T> {
    const { data, error } = await this.admin.rpc(name, args);
    if (error) throw databaseError(error);
    return data as T;
  }
  async create(userId: string, input: CreateJob): Promise<JobRow> {
    await this.ensureMonthlyFree(userId);
    return this.rpc("create_transcription_job", {
      p_user_id: userId,
      p_client_request_id: input.clientRequestId,
      p_language: input.language,
      p_audio_sha256: input.audioSha256,
      p_audio_bytes: input.audioBytes,
      p_claimed_seconds: input.durationSeconds,
      p_provider: this.provider,
      p_model: this.model,
    });
  }
  async get(userId: string, id: string): Promise<JobRow> {
    const { data, error } = await this.admin.from("jobs").select(columns)
      .eq("id", id).eq("user_id", userId).maybeSingle();
    if (error) throw databaseError(error);
    if (!data) throw new ApiError(404, "job_not_found");
    return data as JobRow;
  }
  async uploaded(userId: string, id: string): Promise<JobRow> {
    const job = await this.get(userId, id);
    if (job.status === "awaiting_upload") {
      if (Date.parse(job.upload_expires_at) <= Date.now()) {
        throw new ApiError(409, "upload_expired");
      }
      const { data, error } = await this.admin.storage.from(bucket).info(
        job.storage_path,
      );
      if (error) {
        if ("statusCode" in error && String(error.statusCode) === "404") {
          throw new ApiError(409, "upload_not_found");
        }
        throw new ApiError(503, "storage_unavailable");
      }
      if (!data) throw new ApiError(409, "upload_not_found");
      if (
        Number(data.size) !== job.audio_bytes ||
        !["audio/mp4", "audio/m4a", "audio/aac"].includes(
          data.contentType ?? "",
        )
      ) {
        throw new ApiError(409, "upload_metadata_mismatch");
      }
    }
    return this.rpc("mark_job_uploaded", { p_user_id: userId, p_job_id: id });
  }
  cancel(userId: string, id: string): Promise<JobRow> {
    return this.rpc("cancel_job", { p_user_id: userId, p_job_id: id });
  }
  async upload(job: JobRow): Promise<Upload | null> {
    if (job.status !== "awaiting_upload") return null;
    if (Date.parse(job.upload_expires_at) <= Date.now()) {
      throw new ApiError(409, "upload_expired");
    }
    const existing = await this.admin.storage.from(bucket).info(
      job.storage_path,
    );
    if (!existing.error && existing.data) return null;
    if (
      existing.error &&
      !("statusCode" in existing.error &&
        String(existing.error.statusCode) === "404")
    ) {
      throw new ApiError(503, "storage_unavailable");
    }
    const { data, error } = await this.admin.storage.from(bucket)
      .createSignedUploadUrl(job.storage_path, { upsert: false });
    if (error || !data) throw new ApiError(503, "storage_unavailable");
    // Sunucu içi kong adresi iPhone'a dönmemeli. Yalnız kendi Storage yolu taşınır.
    const url = new URL(data.signedUrl);
    const external = new URL(this.externalUrl);
    url.protocol = external.protocol;
    url.host = external.host;
    return {
      url: url.toString(),
      method: "PUT",
      headers: { "Content-Type": "audio/mp4" },
      expiresAt: job.upload_expires_at,
    };
  }
  async result(userId: string, id: string): Promise<JobResult | null> {
    const { data, error } = await this.admin.from("job_results")
      .select("transcript,expires_at").eq("job_id", id).eq("user_id", userId)
      .gt("expires_at", new Date().toISOString()).maybeSingle();
    if (error) throw databaseError(error);
    return data
      ? {
        transcript: data.transcript as Transcript,
        expiresAt: data.expires_at,
      }
      : null;
  }
  async quota(userId: string): Promise<QuotaPeriod[]> {
    await this.ensureMonthlyFree(userId);
    return this.rpc("quota_balance", { p_user_id: userId });
  }
  private async ensureMonthlyFree(userId: string): Promise<void> {
    try {
      await this.freeClaim(userId);
    } catch (error) {
      // Uygun olmayan kimlik mevcut ücretli/manual kotasını kullanabilir.
      // Config/Auth/DB hatasını yutmayız: sessiz 402 veya yanlış bakiye olmaz.
      if (
        !(error instanceof ApiError && error.status === 403 &&
          error.code === "free_quota_not_eligible")
      ) throw error;
    }
  }
  async freeClaim(userId: string): Promise<boolean> {
    // Auth.getUser ile doğrulanan id'nin güncel Auth kaydı; client metadata yok.
    const { data, error } = await this.admin.auth.admin.getUserById(userId);
    if (error || !data.user || data.user.id !== userId) {
      throw new ApiError(503, "auth_unavailable");
    }
    freeIdentity(data.user);
    const config = this.freeConfig();
    const identityHash = await freeIdentityHash(data.user, config.pepper);
    const period = await this.rpc<{ id: string } | null>(
      "grant_monthly_free_quota",
      {
        p_user_id: userId,
        p_identity_hash: identityHash,
        p_seconds: config.seconds,
      },
    );
    return Boolean(period?.id);
  }
}
export function repositoryFromEnvironment(): Repository {
  const required = (name: string) => {
    const value = Deno.env.get(name);
    if (!value) throw new Error("Missing configuration: " + name);
    return value;
  };
  return new SupabaseRepository(
    createClient(
      required("SUPABASE_URL"),
      required("SUPABASE_SERVICE_ROLE_KEY"),
      { auth: { persistSession: false, autoRefreshToken: false } },
    ),
    required("TRANSCRIPTION_PROVIDER"),
    required("TRANSCRIPTION_MODEL"),
    required("PUBLIC_SUPABASE_URL"),
  );
}
