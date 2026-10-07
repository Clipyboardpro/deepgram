import type { Transcript } from "./provider.ts";
export function isTranscript(value: unknown): value is Transcript {
  if (!value || typeof value !== "object") return false;
  const t = value as Transcript;
  return t.schemaVersion === 1 && typeof t.provider === "string" &&
    t.provider.length > 0 &&
    typeof t.model === "string" && t.model.length > 0 &&
    typeof t.language === "string" &&
    /^[a-z]{2}(-[A-Z]{2})?$/.test(t.language) &&
    Number.isFinite(t.durationSeconds) && t.durationSeconds > 0 &&
    Array.isArray(t.words) && t.words.length <= 10000 &&
    t.words.every((w) =>
      w && typeof w === "object" && typeof w.text === "string" &&
      (w.display === undefined || typeof w.display === "string") &&
      Number.isFinite(w.start) && w.start >= 0 && Number.isFinite(w.end) &&
      w.end >= w.start && w.end <= t.durationSeconds &&
      (w.confidence === undefined ||
        (Number.isFinite(w.confidence) && w.confidence >= 0 &&
          w.confidence <= 1))
    );
}
