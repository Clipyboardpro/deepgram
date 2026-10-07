import {
  FakeProvider,
  type ProviderCallback,
  type ProviderSubmission,
  type Submission,
  type Transcript,
  type TranscriptionProvider,
} from "./provider.ts";
import { isTranscript } from "./transcript.ts";
const requestId = (value: unknown): value is string =>
  typeof value === "string" &&
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
const object = (value: unknown): Record<string, unknown> => {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Invalid provider response");
  }
  return value as Record<string, unknown>;
};
/** Callback-only: hiçbir submit veya HTTP hata kör yeniden denenmez. */
export class DeepgramProvider implements TranscriptionProvider {
  readonly name = "deepgram";
  readonly model = "nova-3";
  constructor(
    private readonly key: string,
    private readonly http: typeof fetch = fetch,
  ) {
    if (!key) throw new Error("Deepgram key required");
  }
  async submit(input: Submission): Promise<ProviderSubmission> {
    if (input.language !== "tr") {
      throw new Error("Only Turkish configuration is enabled");
    }
    const audio = new URL(input.audioUrl);
    const callback = new URL(input.callbackUrl);
    if (audio.protocol !== "https:" || callback.protocol !== "https:") {
      throw new Error("HTTPS required");
    }
    const endpoint = new URL("https://api.eu.deepgram.com/v1/listen");
    endpoint.search = new URLSearchParams({
      model: this.model,
      language: "tr",
      punctuate: "true",
      smart_format: "true",
      callback: callback.href,
      callback_method: "POST",
    }).toString();
    // No response bodies, signed URLs, key, callback token in logs/errors.
    let response: Response;
    try {
      response = await this.http(endpoint, {
        method: "POST",
        headers: {
          Authorization: "Token " + this.key,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ url: audio.href }),
        signal: AbortSignal.timeout(15000),
        redirect: "error",
      });
    } catch {
      throw new Error("Provider submission outcome unknown");
    }
    if (!response.ok) {
      await response.body?.cancel();
      throw new Error("Provider submission failed");
    }
    let body: Record<string, unknown>;
    try {
      body = object(await response.json());
    } catch {
      throw new Error("Invalid provider acceptance");
    }
    if (!requestId(body.request_id)) {
      throw new Error("Invalid provider acceptance");
    }
    return { requestId: body.request_id };
  }
  result(_requestId: string): Promise<Transcript> {
    return Promise.reject(
      new Error("Deepgram results arrive only through callback"),
    );
  }
  parseCallback(value: unknown, language: string): ProviderCallback {
    if (language !== "tr") throw new Error("Invalid language");
    const body = object(value);
    if (typeof body.err_code === "string" && body.results === undefined) {
      if (!requestId(body.request_id)) {
        throw new Error("Invalid provider request ID");
      }
      return {
        requestId: body.request_id,
        eventKey: "result:" + body.request_id,
        status: "failed",
        errorCode: "provider_failed",
      };
    }
    const metadata = object(body.metadata);
    if (!requestId(metadata.request_id) || metadata.channels !== 1) {
      throw new Error("Invalid provider metadata");
    }
    const results = object(body.results);
    if (!Array.isArray(results.channels) || results.channels.length !== 1) {
      throw new Error("Invalid channels");
    }
    const alternatives = object(results.channels[0]).alternatives;
    if (!Array.isArray(alternatives) || !alternatives.length) {
      throw new Error("Missing alternatives");
    }
    const words = object(alternatives[0]).words;
    if (!Array.isArray(words) || words.length > 10000) {
      throw new Error("Invalid words");
    }
    const transcript = {
      schemaVersion: 1,
      provider: this.name,
      model: this.model,
      language,
      durationSeconds: metadata.duration,
      words: words.map((value) => {
        const word = object(value);
        return {
          text: word.word,
          start: word.start,
          end: word.end,
          ...(word.punctuated_word === undefined
            ? {}
            : { display: word.punctuated_word }),
          ...(word.confidence === undefined
            ? {}
            : { confidence: word.confidence }),
        };
      }),
    };
    if (
      !isTranscript(transcript) || transcript.durationSeconds > 300.25 ||
      transcript.words.some((word, index) =>
        index > 0 && word.start < transcript.words[index - 1].start
      )
    ) {
      throw new Error("Invalid provider transcript");
    }
    return {
      requestId: metadata.request_id,
      eventKey: "result:" + metadata.request_id,
      status: "succeeded",
      transcript,
    };
  }
}
export function providerFromEnvironment(): TranscriptionProvider {
  const name = Deno.env.get("TRANSCRIPTION_PROVIDER");
  const model = Deno.env.get("TRANSCRIPTION_MODEL");
  if (name === "fake" && model === "fake-v1") return new FakeProvider();
  if (name === "deepgram" && model === "nova-3") {
    return new DeepgramProvider(Deno.env.get("DEEPGRAM_API_KEY") ?? "");
  }
  throw new Error("Provider configuration not supported");
}
