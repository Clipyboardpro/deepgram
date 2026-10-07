import type { SupabaseClient } from "@supabase/supabase-js";
import { ApiError, databaseError } from "./errors.ts";
import { AudioError, inspectAudio } from "../_shared/audio.ts";
import type { Transcript } from "../_shared/provider.ts";
export interface DispatchJob {
  id: string;
  status: string;
  storage_path: string;
  language: string;
  provider: string;
  model: string;
  audio_bytes: number;
  audio_sha256: string;
  claimed_duration_seconds: number;
  inspected_duration_seconds: number | null;
  provider_request_id: string | null;
  submission_started_at?: string | null;
}
export interface Claim {
  job_id: string;
  callback_token: string;
}
export interface Callback {
  requestId: string;
  eventKey: string;
  status: "succeeded" | "failed";
  transcript?: Transcript;
  errorCode?: string;
}
export interface PipelineRepository {
  dequeue(): Promise<{ msg_id: number; read_count: number; job_id: string }[]>;
  ack(id: number): Promise<void>;
  get(id: string): Promise<DispatchJob | null>;
  preflight(job: DispatchJob): Promise<void>;
  claim(id: string): Promise<Claim | null>;
  submitted(id: string, requestId: string): Promise<void>;
  rememberSubmission(id: string, requestId: string): Promise<void>;
  resumeSubmission(id: string): Promise<void>;
  markUnknown(id: string): Promise<void>;
  recover(id: string): Promise<string | null>;
  signedAudio(job: DispatchJob): Promise<string>;
  verify(
    provider: string,
    id: string,
    token: string,
  ): Promise<DispatchJob | null>;
  callback(
    provider: string,
    id: string,
    token: string,
    body: Callback,
  ): Promise<void>;
  fail(id: string, code: string): Promise<void>;
}
export class SupabasePipeline implements PipelineRepository {
  constructor(private readonly admin: SupabaseClient) {}
  private async rpc<T>(
    name: string,
    args: Record<string, unknown>,
  ): Promise<T> {
    const { data, error } = await this.admin.rpc(name, args);
    if (error) throw databaseError(error);
    return data as T;
  }
  dequeue(): Promise<{ msg_id: number; read_count: number; job_id: string }[]> {
    return this.rpc("dequeue_dispatch", {
      p_visibility_seconds: 120,
      p_batch_size: 5,
    });
  }
  async ack(id: number): Promise<void> {
    await this.rpc("ack_dispatch", { p_msg_id: id });
  }
  async get(id: string): Promise<DispatchJob | null> {
    const { data, error } = await this.admin.from("jobs").select(
      "id,status,storage_path,language,provider,model,audio_bytes,audio_sha256,claimed_duration_seconds,inspected_duration_seconds,provider_request_id,submission_started_at",
    ).eq("id", id).maybeSingle();
    if (error) throw databaseError(error);
    return data as DispatchJob | null;
  }
  async preflight(job: DispatchJob): Promise<void> {
    const settings = await this.admin.from("service_settings").select(
      "max_audio_bytes,max_audio_seconds",
    ).single();
    if (settings.error || !settings.data) {
      throw new ApiError(503, "storage_unavailable");
    }
    if (job.audio_bytes > settings.data.max_audio_bytes) {
      throw new AudioError("audio_size_mismatch");
    }
    // Boyut Storage info ile önceden denetlenir; download bucket max 15 MiB.
    const info = await this.admin.storage.from("transcription-audio").info(
      job.storage_path,
    );
    if (info.error || !info.data) {
      throw new ApiError(503, "storage_unavailable");
    }
    if (
      Number(info.data.size) !== job.audio_bytes ||
      !["audio/mp4", "audio/m4a", "audio/aac"].includes(
        info.data.contentType ?? "",
      )
    ) throw new AudioError("audio_size_mismatch");
    const download = await this.admin.storage.from("transcription-audio")
      .download(job.storage_path);
    if (download.error || !download.data) {
      throw new ApiError(503, "storage_unavailable");
    }
    const bytes = new Uint8Array(await download.data.arrayBuffer());
    const duration = await inspectAudio(
      bytes,
      job,
      settings.data.max_audio_seconds,
      settings.data.max_audio_bytes,
    );
    await this.rpc("record_job_audio_check", {
      p_job_id: job.id,
      p_duration: duration,
    });
  }
  async claim(id: string): Promise<Claim | null> {
    const rows = await this.rpc<Claim[]>("claim_job_for_submission", {
      p_job_id: id,
    });
    return rows[0] ?? null;
  }
  async submitted(id: string, requestId: string): Promise<void> {
    await this.rpc("mark_job_submitted", {
      p_job_id: id,
      p_provider_request_id: requestId,
    });
  }
  async recover(id: string): Promise<string | null> {
    const rows = await this.rpc<{ callback_token: string }[]>(
      "recover_fake_callback",
      { p_job_id: id },
    );
    return rows[0]?.callback_token ?? null;
  }
  async rememberSubmission(id: string, requestId: string): Promise<void> {
    await this.rpc("remember_provider_submission", {
      p_job_id: id,
      p_request_id: requestId,
    });
  }
  async resumeSubmission(id: string): Promise<void> {
    await this.rpc("resume_provider_submission", { p_job_id: id });
  }
  async markUnknown(id: string): Promise<void> {
    await this.rpc("mark_submission_unknown", { p_job_id: id });
  }
  async signedAudio(job: DispatchJob): Promise<string> {
    const { data, error } = await this.admin.storage.from("transcription-audio")
      .createSignedUrl(job.storage_path, 120);
    if (error || !data) throw new ApiError(503, "storage_unavailable");
    return data.signedUrl;
  }
  async verify(
    provider: string,
    id: string,
    token: string,
  ): Promise<DispatchJob | null> {
    if (
      await this.rpc("verify_job_callback", {
        p_job_id: id,
        p_token: token,
      }) !== true
    ) return null;
    const job = await this.get(id);
    return job?.provider === provider ? job : null;
  }
  async callback(
    provider: string,
    id: string,
    token: string,
    body: Callback,
  ): Promise<void> {
    await this.rpc("receive_provider_callback", {
      p_provider: provider,
      p_job_id: id,
      p_token: token,
      p_request_id: body.requestId,
      p_event_key: body.eventKey,
      p_status: body.status,
      p_transcript: body.transcript ?? null,
      p_error_code: body.errorCode ?? null,
    });
  }
  async fail(id: string, code: string): Promise<void> {
    await this.rpc("fail_job", {
      p_job_id: id,
      p_error_code: code,
      p_event_key: (code === "provider_rejected" ? "rejected:" : "preflight:") +
        id,
      p_kind: code === "provider_rejected" ? "submit" : "poll",
    });
  }
}
