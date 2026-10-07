import { assertEquals, assertRejects } from "@std/assert";
import { AudioError, inspectAudio } from "../_shared/audio.ts";
function join(...arrays: Uint8Array[]) {
  const result = new Uint8Array(arrays.reduce((n, a) => n + a.length, 0));
  let at = 0;
  for (const a of arrays) {
    result.set(a, at);
    at += a.length;
  }
  return result;
}
function u32(...values: number[]) {
  const result = new Uint8Array(values.length * 4);
  const view = new DataView(result.buffer);
  values.forEach((v, n) => view.setUint32(n * 4, v));
  return result;
}
function box(type: string, ...body: Uint8Array[]) {
  const data = join(...body);
  return join(u32(data.length + 8), new TextEncoder().encode(type), data);
}
export function m4a(seconds = 1, handler = "soun") {
  const stbl = box(
    "stbl",
    box("stsd", u32(0, 1), box("mp4a")),
    box("stts", u32(0, 1, 1, seconds * 1000)),
  );
  const mdia = box(
    "mdia",
    box("mdhd", u32(0, 0, 0, 1000, seconds * 1000)),
    box("hdlr", u32(0, 0), new TextEncoder().encode(handler)),
    box("minf", stbl),
  );
  return join(
    box("ftyp"),
    box("moov", box("trak", mdia)),
    box("mdat", new Uint8Array([1])),
  );
}
async function metadata(bytes: Uint8Array, claimed = 1) {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new Uint8Array(bytes).buffer,
  );
  return {
    audio_bytes: bytes.length,
    audio_sha256: Array.from(
      new Uint8Array(digest),
      (b) => b.toString(16).padStart(2, "0"),
    ).join(""),
    claimed_duration_seconds: claimed,
  };
}
Deno.test("M4A sample timing gerçek süreyi verir", async () => {
  const bytes = m4a();
  assertEquals(
    await inspectAudio(bytes, await metadata(bytes), 300, 15 * 1024 * 1024),
    1,
  );
});
Deno.test("boyut ve hash uyuşmazlığı sağlayıcıdan önce reddedilir", async () => {
  const bytes = m4a();
  const meta = await metadata(bytes);
  await assertRejects(
    () => inspectAudio(bytes, { ...meta, audio_bytes: 1 }, 300, 99999),
    AudioError,
    "audio_size_mismatch",
  );
  await assertRejects(
    () =>
      inspectAudio(
        bytes,
        { ...meta, audio_sha256: "0".repeat(64) },
        300,
        99999,
      ),
    AudioError,
    "audio_hash_mismatch",
  );
});
Deno.test("uzun ses kısa beyanla / servis sınırı üzerinde gönderilemez", async () => {
  const bytes = m4a(60);
  const short = await metadata(bytes, 1);
  const long = await metadata(bytes, 60);
  await assertRejects(
    () => inspectAudio(bytes, short, 300, 99999),
    AudioError,
    "audio_duration_mismatch",
  );
  await assertRejects(
    () => inspectAudio(bytes, long, 30, 99999),
    AudioError,
    "audio_duration_mismatch",
  );
});
Deno.test("bozuk/video kapsayıcı kabul edilmez", async () => {
  for (
    const bytes of [
      m4a().slice(0, -1),
      m4a(1, "vide"),
      new Uint8Array([0, 0, 0, 7, 1, 2, 3, 4]),
    ]
  ) {
    const meta = await metadata(bytes);
    await assertRejects(
      () => inspectAudio(bytes, meta, 300, 99999),
      AudioError,
    );
  }
});
Deno.test("AAC ADTS frame zamanı ölçülür ve kesik frame reddedilir", async () => {
  const bytes = new Uint8Array([255, 241, 80, 128, 1, 31, 252, 0]); // 44.1kHz, 8 byte frame
  assertEquals(
    await inspectAudio(bytes, await metadata(bytes), 300, 99999),
    1024 / 44100,
  );
  const cut = bytes.slice(0, -1);
  const meta = await metadata(cut);
  await assertRejects(
    () => inspectAudio(cut, meta, 300, 99999),
    AudioError,
    "invalid_audio",
  );
});
