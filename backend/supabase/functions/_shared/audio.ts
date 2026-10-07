// Sınırlı AAC/M4A preflight: codec decode değil, kapsayıcı/frame zamanı + hash.
export class AudioError extends Error {
  constructor(readonly code: string) {
    super(code);
  }
}
type Box = { type: string; start: number; end: number };
function boxes(bytes: Uint8Array, start = 0, end = bytes.length): Box[] {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const result: Box[] = [];
  while (start < end) {
    if (end - start < 8 || result.length > 10000) {
      throw new AudioError("invalid_audio");
    }
    let size = view.getUint32(start);
    let header = 8;
    if (size === 1) {
      if (end - start < 16) throw new AudioError("invalid_audio");
      const large = view.getBigUint64(start + 8);
      if (large > BigInt(Number.MAX_SAFE_INTEGER)) {
        throw new AudioError("invalid_audio");
      }
      size = Number(large);
      header = 16;
    } else if (size === 0) size = end - start;
    if (size < header || size > end - start) {
      throw new AudioError("invalid_audio");
    }
    const type = String.fromCharCode(...bytes.subarray(start + 4, start + 8));
    result.push({ type, start: start + header, end: start + size });
    start += size;
  }
  return result;
}
function m4aDuration(bytes: Uint8Array): number {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const top = boxes(bytes);
  const moov = top.find((b) => b.type === "moov");
  if (
    !moov || !top.some((b) => b.type === "ftyp") ||
    !top.some((b) => b.type === "mdat" && b.end > b.start)
  ) throw new AudioError("invalid_audio");
  const movie = boxes(bytes, moov.start, moov.end);
  if (movie.some((b) => b.type === "mvex")) {
    throw new AudioError("unsupported_audio");
  }
  const durations: number[] = [];
  for (const track of movie.filter((b) => b.type === "trak")) {
    const mdia = boxes(bytes, track.start, track.end).find((b) =>
      b.type === "mdia"
    );
    if (!mdia) throw new AudioError("invalid_audio");
    const media = boxes(bytes, mdia.start, mdia.end);
    const handler = media.find((b) => b.type === "hdlr");
    if (
      !handler || handler.end - handler.start < 12 ||
      String.fromCharCode(
          ...bytes.subarray(handler.start + 8, handler.start + 12),
        ) !== "soun"
    ) throw new AudioError("unsupported_audio");
    const header = media.find((b) => b.type === "mdhd");
    const minf = media.find((b) => b.type === "minf");
    if (!header || !minf) throw new AudioError("invalid_audio");
    const version = bytes[header.start];
    const offset = version === 0 ? 12 : version === 1 ? 20 : -1;
    if (
      offset < 0 ||
      header.end - header.start < offset + (version === 1 ? 12 : 8)
    ) throw new AudioError("invalid_audio");
    const timescale = view.getUint32(header.start + offset);
    const stbl = boxes(bytes, minf.start, minf.end).find((b) =>
      b.type === "stbl"
    );
    if (!stbl || !timescale) throw new AudioError("invalid_audio");
    const sample = boxes(bytes, stbl.start, stbl.end);
    const stsd = sample.find((b) => b.type === "stsd");
    const stts = sample.find((b) => b.type === "stts");
    if (
      !stsd || stsd.end - stsd.start < 8 ||
      view.getUint32(stsd.start + 4) !== 1 || !stts || stts.end - stts.start < 8
    ) throw new AudioError("invalid_audio");
    const codecs = boxes(bytes, stsd.start + 8, stsd.end);
    if (codecs.length !== 1 || codecs[0].type !== "mp4a") {
      throw new AudioError("unsupported_audio");
    }
    const count = view.getUint32(stts.start + 4);
    if (!count || count > 100000 || stts.end - stts.start !== 8 + count * 8) {
      throw new AudioError("invalid_audio");
    }
    let ticks = 0;
    for (let n = 0; n < count; n++) {
      const at = stts.start + 8 + n * 8;
      ticks += view.getUint32(at) * view.getUint32(at + 4);
      if (!Number.isSafeInteger(ticks)) throw new AudioError("invalid_audio");
    }
    durations.push(ticks / timescale);
  }
  if (durations.length !== 1) throw new AudioError("unsupported_audio");
  return durations[0];
}
function adtsDuration(bytes: Uint8Array): number {
  const rates = [
    96000,
    88200,
    64000,
    48000,
    44100,
    32000,
    24000,
    22050,
    16000,
    12000,
    11025,
    8000,
    7350,
  ];
  let at = 0;
  let duration = 0;
  while (at < bytes.length) {
    if (
      bytes.length - at < 7 || bytes[at] !== 255 ||
      (bytes[at + 1] & 0xf6) !== 0xf0
    ) throw new AudioError("invalid_audio");
    const rate = rates[(bytes[at + 2] >> 2) & 15];
    const length = ((bytes[at + 3] & 3) << 11) | (bytes[at + 4] << 3) |
      (bytes[at + 5] >> 5);
    const header = bytes[at + 1] & 1 ? 7 : 9;
    if (!rate || length <= header || length > bytes.length - at) {
      throw new AudioError("invalid_audio");
    }
    duration += 1024 * ((bytes[at + 6] & 3) + 1) / rate;
    at += length;
  }
  return duration;
}
export async function inspectAudio(
  bytes: Uint8Array,
  expected: {
    audio_bytes: number;
    audio_sha256: string;
    claimed_duration_seconds: number;
  },
  maximumSeconds: number,
  maximumBytes: number,
): Promise<number> {
  if (bytes.length !== expected.audio_bytes || bytes.length > maximumBytes) {
    throw new AudioError("audio_size_mismatch");
  }
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new Uint8Array(bytes).buffer,
  );
  const hash = Array.from(
    new Uint8Array(digest),
    (b) => b.toString(16).padStart(2, "0"),
  ).join("");
  if (hash !== expected.audio_sha256) {
    throw new AudioError("audio_hash_mismatch");
  }
  const duration = bytes[0] === 255 ? adtsDuration(bytes) : m4aDuration(bytes);
  if (!Number.isFinite(duration) || duration <= 0) {
    throw new AudioError("invalid_audio");
  }
  // AAC encoder priming / saniyeye yuvarlama için en fazla 250 ms pay.
  if (
    duration > maximumSeconds + 0.25 ||
    duration > expected.claimed_duration_seconds + 0.25
  ) throw new AudioError("audio_duration_mismatch");
  if (bytes.length > duration * 64000 + 65536) {
    throw new AudioError("audio_duration_mismatch");
  }
  return duration;
}
