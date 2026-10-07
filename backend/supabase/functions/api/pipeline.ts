import { Hono } from "hono";
import { bodyLimit } from "hono/body-limit";
import { ApiError } from "./errors.ts";
import { AudioError } from "../_shared/audio.ts";
import { verifyDispatch } from "../_shared/dispatch-auth.ts";
import { isTranscript } from "../_shared/transcript.ts";
import { FakeProvider } from "../_shared/provider.ts";
import type { TranscriptionProvider } from "../_shared/provider.ts";
import type {
  Callback,
  DispatchJob,
  PipelineRepository,
} from "./pipeline-repository.ts";
export interface PipelineOptions {
  repo: PipelineRepository;
  secret: string;
  publicUrl: string;
  provider?: TranscriptionProvider;
  deliver?: (request: Request) => Promise<Response>;
  retryDelayMs?: number;
}
const terminal = new Set([
  "succeeded",
  "failed",
  "canceled",
  "unknown_provider_state",
]);
export function createPipeline(options: PipelineOptions) {
  const { repo } = options;
  const provider = options.provider ?? new FakeProvider();
  const app = new Hono();
  async function retry(operation: () => Promise<void>): Promise<void> {
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        await operation();
        return;
      } catch (error) {
        if (attempt === 2) throw error;
        const delay = (options.retryDelayMs ?? 150) * (attempt + 1);
        if (delay) await new Promise((resolve) => setTimeout(resolve, delay));
      }
    }
  }
  app.onError((error, c) => {
    const safe = error instanceof ApiError
      ? error
      : new ApiError(500, "internal_error");
    return c.json({
      error: { code: safe.code, requestId: crypto.randomUUID() },
    }, safe.status);
  });
  app.post(
    "/v1/providers/:provider/callback/:id/:token",
    bodyLimit({
      maxSize: 1024 * 1024,
      onError: () => {
        throw new ApiError(413, "request_too_large");
      },
    }),
    async (c) => {
      const { provider: name, id, token } = c.req.param();
      if (
        name !== provider.name ||
        !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(
          id,
        ) || !/^[0-9a-f]{64}$/.test(token)
      ) throw new ApiError(404, "job_not_found");
      const job = await repo.verify(name, id, token);
      if (!job) throw new ApiError(404, "job_not_found");
      if (
        !(c.req.header("Content-Type") ?? "").startsWith("application/json")
      ) throw new ApiError(415, "unsupported_media_type");
      let b: Callback;
      try {
        b = await c.req.json();
      } catch {
        throw new ApiError(400, "invalid_callback");
      }
      if (
        !b || typeof b !== "object" || typeof b.requestId !== "string" ||
        b.requestId.length < 1 || b.requestId.length > 256 ||
        typeof b.eventKey !== "string" || b.eventKey.length < 1 ||
        b.eventKey.length > 128 ||
        (b.requestId !== job.provider_request_id &&
          !(job.provider_request_id === null &&
            job.submission_started_at &&
            ["queued", "unknown_provider_state"].includes(job.status)))
      ) throw new ApiError(400, "invalid_callback");
      if (b.status === "succeeded") {
        if (
          !isTranscript(b.transcript) || b.transcript.provider !== name ||
          b.transcript.model !== job.model ||
          b.transcript.language !== job.language ||
          job.inspected_duration_seconds === null ||
          Math.abs(
              b.transcript.durationSeconds - job.inspected_duration_seconds,
            ) > 0.25
        ) throw new ApiError(400, "invalid_callback");
      } else if (
        b.status !== "failed" ||
        !["provider_failed", "invalid_audio", "provider_timeout"].includes(
          b.errorCode ?? "",
        )
      ) throw new ApiError(400, "invalid_callback");
      await repo.callback(name, id, token, b);
      return c.json({ accepted: true });
    },
  );
  async function deliver(job: DispatchJob, token: string) {
    const transcript = await provider.result(job.provider_request_id!);
    // Fake sonuçtaki örnek kelimeyi ölçülen ses süresine taşır; kaynak ofseti yok.
    transcript.durationSeconds = job.inspected_duration_seconds!;
    transcript.language = job.language;
    transcript.words = transcript.words.filter((word) =>
      word.end <= transcript.durationSeconds
    );
    const url = `${
      options.publicUrl.replace(/\/$/, "")
    }/functions/v1/api/v1/providers/${job.provider}/callback/${job.id}/${token}`;
    const request = new Request(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        requestId: job.provider_request_id,
        eventKey: "result:" + job.provider_request_id,
        status: "succeeded",
        transcript,
      }),
    });
    // Ağsız FakeProvider teslimatı aynı webhook yönlendiricisinden geçer. DB hatası
    // olursa ack edilmez; sonraki kira aynı sonucu resubmit etmeden toparlar.
    const response = options.deliver
      ? await options.deliver(request)
      : await app.fetch(
        new Request(url.replace(/\/functions\/v1\/api\//, "/"), request),
      );
    await response.text();
    if (!response.ok) throw new ApiError(503, "callback_delivery_failed");
  }
  app.post("/v1/internal/dispatch", async (c) => {
    if (!await verifyDispatch(c.req.raw.headers, options.secret)) {
      throw new ApiError(401, "not_authenticated");
    }
    let acknowledged = 0;
    let deferred = 0;
    for (const message of await repo.dequeue()) {
      try {
        let job = await repo.get(message.job_id);
        if (job && ["queued", "unknown_provider_state"].includes(job.status)) {
          await repo.resumeSubmission(job.id);
          job = await repo.get(job.id);
        }
        if (!job || terminal.has(job.status)) {
          await repo.ack(message.msg_id);
          acknowledged++;
          continue;
        }
        if (job.provider !== provider.name || job.model !== provider.model) {
          // CX-004 sağlayıcıları kayıtlı değil. Önceden gönderilmiş işi fail etmeyiz.
          if (job.status === "queued") {
            await repo.fail(job.id, "provider_not_configured");
          }
          await repo.ack(message.msg_id);
          acknowledged++;
          continue;
        }
        let token: string | null = null;
        if (job.status === "queued") {
          await repo.preflight(job);
          const audioUrl = await repo.signedAudio(job);
          const claim = await repo.claim(job.id);
          if (claim) {
            token = claim.callback_token;
            // Yalnız submit hatası belirsizdir; DB mark hatası kabul edilmiş
            // sağlayıcı isteğini kaybettirmemeli ve ikinci claim yapılmamalı.
            let requestId: string;
            try {
              const result = await provider.submit({
                jobId: job.id,
                audioUrl,
                language: job.language,
                callbackUrl: `${
                  options.publicUrl.replace(/\/$/, "")
                }/functions/v1/api/v1/providers/${job.provider}/callback/${job.id}/${token}`,
              });
              requestId = result.requestId;
            } catch {
              await repo.markUnknown(job.id);
              throw new ApiError(503, "submission_outcome_unknown");
            }
            // Alındı belgesi önce provider_events'e gider (anahtar/token değil,
            // yalnız requestId). Mark kalıcı başarısızsa sonraki kira bunu okur.
            // DB bütünüyle yoksa bile doğrulanmış callback requestId'yi onarır.
            try {
              await retry(() => repo.rememberSubmission(job!.id, requestId));
            } catch { /* mark veya callback kurtarabilir */ }
            await retry(() => repo.submitted(job!.id, requestId));
          }
          job = await repo.get(job.id);
        }
        if (job?.status === "submitted") {
          token ??= await repo.recover(job.id);
          if (!token) {
            deferred++;
            continue;
          }
          await deliver(job, token);
        } else if (job && !terminal.has(job.status)) {
          deferred++;
          continue;
        }
        await repo.ack(message.msg_id);
        acknowledged++;
      } catch (error) {
        if (error instanceof AudioError) {
          await repo.fail(message.job_id, error.code);
          await repo.ack(message.msg_id);
          acknowledged++;
        } else deferred++; // Lease bitince tekrar; ayrıntı, ses, token loglanmaz.
      }
    }
    return c.json({ acknowledged, deferred });
  });
  return app;
}
