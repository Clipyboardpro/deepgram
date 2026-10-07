import { Hono } from "hono";
import { bodyLimit } from "hono/body-limit";
import { ApiError } from "./errors.ts";
import type { CreateJob, JobRow, Repository } from "./repository.ts";
type Env = { Variables: { userId: string; requestId: string } };
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function validId(id: string) {
  if (!uuid.test(id)) throw new ApiError(400, "invalid_request");
  return id;
}
function validate(value: unknown): CreateJob {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new ApiError(400, "invalid_request");
  }
  const b = value as Record<string, unknown>;
  const keys = [
    "clientRequestId",
    "language",
    "audioSha256",
    "audioBytes",
    "durationSeconds",
  ];
  if (
    Object.keys(b).some((key) => !keys.includes(key)) ||
    typeof b.clientRequestId !== "string" || b.clientRequestId.length < 8 ||
    b.clientRequestId.length > 128 ||
    typeof b.language !== "string" ||
    !/^[a-z]{2}(-[A-Z]{2})?$/.test(b.language) ||
    typeof b.audioSha256 !== "string" ||
    !/^[0-9a-f]{64}$/.test(b.audioSha256) ||
    !Number.isSafeInteger(b.audioBytes) || Number(b.audioBytes) <= 0 ||
    !Number.isSafeInteger(b.durationSeconds) || Number(b.durationSeconds) <= 0
  ) {
    throw new ApiError(400, "invalid_request");
  }
  // PostgreSQL integer sınırından büyük değer RPC çözümlemesinde 500 olmamalı.
  if (Number(b.durationSeconds) > 2147483647) {
    throw new ApiError(413, "audio_too_long");
  }
  return b as unknown as CreateJob;
}
function view(job: JobRow) {
  return {
    id: job.id,
    status: job.status,
    createdAt: job.created_at,
    errorCode: job.error_code,
  };
}
export function createApp(repo: Repository) {
  const app = new Hono<Env>();
  app.use("*", async (c, next) => {
    c.set("requestId", crypto.randomUUID());
    c.header("Cache-Control", "no-store");
    await next();
  });
  app.onError((err, c) => {
    const e = err instanceof ApiError
      ? err
      : new ApiError(500, "internal_error");
    return c.json(
      { error: { code: e.code, requestId: c.get("requestId") } },
      e.status,
    );
  });
  app.notFound((c) =>
    c.json({ error: { code: "not_found", requestId: c.get("requestId") } }, 404)
  );
  app.use("*", async (c, next) => {
    const match = /^Bearer ([^\s]+)$/i.exec(
      c.req.header("Authorization") ?? "",
    );
    if (!match) throw new ApiError(401, "not_authenticated");
    const userId = await repo.authenticate(match[1]);
    if (!userId) throw new ApiError(401, "not_authenticated");
    c.set("userId", userId);
    await next();
  });
  app.use(
    "*",
    bodyLimit({
      maxSize: 8192,
      onError: () => {
        throw new ApiError(413, "request_too_large");
      },
    }),
  );
  app.post("/v1/transcription-jobs", async (c) => {
    if (
      !(c.req.header("Content-Type") ?? "").toLowerCase().startsWith(
        "application/json",
      )
    ) {
      throw new ApiError(415, "unsupported_media_type");
    }
    let body: unknown;
    try {
      body = await c.req.json();
    } catch {
      throw new ApiError(400, "invalid_request");
    }
    const job = await repo.create(c.get("userId"), validate(body));
    return c.json({ job: view(job), upload: await repo.upload(job) }, 200);
  });
  app.post("/v1/transcription-jobs/:id/uploaded", async (c) => {
    return c.json({
      job: view(
        await repo.uploaded(c.get("userId"), validId(c.req.param("id"))),
      ),
    });
  });
  app.post("/v1/transcription-jobs/:id/cancel", async (c) => {
    return c.json({
      job: view(await repo.cancel(c.get("userId"), validId(c.req.param("id")))),
    });
  });
  app.get("/v1/jobs/:id", async (c) => {
    const id = validId(c.req.param("id"));
    const job = await repo.get(c.get("userId"), id);
    return c.json({
      job: view(job),
      result: await repo.result(c.get("userId"), id),
    });
  });
  app.get("/v1/quota", async (c) => {
    const periods = (await repo.quota(c.get("userId"))).map((p) => ({
      id: p.period_id,
      source: p.source,
      startsAt: p.starts_at,
      endsAt: p.ends_at,
      grantedSeconds: p.granted_seconds,
      usedSeconds: p.used_seconds,
      reservedSeconds: p.reserved_seconds,
      availableSeconds: p.available_seconds,
    }));
    return c.json({ periods });
  });
  return app;
}
