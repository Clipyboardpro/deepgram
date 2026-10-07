import { assertEquals, assertRejects } from "@std/assert";
import type { SupabaseClient } from "@supabase/supabase-js";
import { type JobRow, SupabaseRepository } from "../api/repository.ts";
import { ApiError } from "../api/errors.ts";
const job: JobRow = {
  id: "job",
  status: "awaiting_upload",
  storage_path: "owner/job.m4a",
  upload_expires_at: "2099-01-01T00:00:00Z",
  created_at: "2026-10-07T00:00:00Z",
  error_code: null,
  audio_bytes: 100,
};
function fixture(found: boolean, status = "404") {
  let signed = 0;
  const storage = {
    info: () =>
      Promise.resolve(
        found
          ? { data: { size: 100 }, error: null }
          : { data: null, error: { statusCode: status } },
      ),
    createSignedUploadUrl: () => {
      signed++;
      return Promise.resolve({
        data: {
          signedUrl:
            "http://kong:8000/storage/v1/upload/sign/test?token=private",
        },
        error: null,
      });
    },
  };
  const admin = {
    storage: { from: () => storage },
  } as unknown as SupabaseClient;
  return {
    repo: new SupabaseRepository(
      admin,
      "fake",
      "fake-v1",
      "http://127.0.0.1:54321",
    ),
    signed: () => signed,
  };
}
Deno.test("bulgu 1: yüklenmiş nesne için tekrar URL imzalanmaz, null döner", async () => {
  const { repo, signed } = fixture(true);
  assertEquals(await repo.upload(job), null);
  assertEquals(signed(), 0);
});
Deno.test("nesne yoksa yalnız 404 yeni imzalı URL üretir", async () => {
  const { repo, signed } = fixture(false);
  const result = await repo.upload(job);
  assertEquals(result?.method, "PUT");
  assertEquals(new URL(result!.url).host, "127.0.0.1:54321");
  assertEquals(signed(), 1);
});
Deno.test("Storage 403/500 nesne yok sanılmaz; güvenli 503", async () => {
  for (const status of ["403", "500"]) {
    const { repo, signed } = fixture(false, status);
    await assertRejects(
      () => repo.upload(job),
      ApiError,
      "storage_unavailable",
    );
    assertEquals(signed(), 0);
  }
});
