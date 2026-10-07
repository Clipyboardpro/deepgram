import { assertEquals, assertRejects, assertThrows } from "@std/assert";
import { DeepgramProvider } from "../_shared/deepgram.ts";
const id = "11111111-1111-4111-8111-111111111111";
export function deepgramResult() {
  return {
    metadata: { request_id: id, channels: 1, duration: 1 },
    results: {
      channels: [{
        alternatives: [{
          transcript: "Merhaba!",
          words: [{
            word: "merhaba",
            punctuated_word: "Merhaba!",
            start: 0.12,
            end: 0.48,
            confidence: 0.98,
          }],
        }],
      }],
    },
  };
}
Deno.test("Deepgram submit EU HTTPS + language tr + signed read URL + callback; ağsız", async () => {
  let calls = 0;
  const http: typeof fetch = async (input, init) => {
    calls++;
    const url = new URL(String(input));
    assertEquals(url.origin, "https://api.eu.deepgram.com");
    assertEquals(url.searchParams.get("language"), "tr");
    assertEquals(url.searchParams.get("model"), "nova-3");
    assertEquals(url.searchParams.get("punctuate"), "true");
    assertEquals(
      url.searchParams.get("callback"),
      "https://callback.invalid/token",
    );
    assertEquals(
      new Headers(init?.headers).get("Authorization"),
      "Token mock-only",
    );
    assertEquals(JSON.parse(String(init?.body)), {
      url: "https://storage.invalid/signed-read",
    });
    return new Response(JSON.stringify({ request_id: id }));
  };
  const provider = new DeepgramProvider("mock-only", http);
  assertEquals(
    await provider.submit({
      jobId: id,
      language: "tr",
      audioUrl: "https://storage.invalid/signed-read",
      callbackUrl: "https://callback.invalid/token",
    }),
    { requestId: id },
  );
  assertEquals(calls, 1);
});
Deno.test("Deepgram noktalama, güven ve ses sıfır zamanları Transcript v1'e eşlenir", () => {
  const callback = new DeepgramProvider("mock-only").parseCallback(
    deepgramResult(),
    "tr",
  );
  assertEquals(callback.requestId, id);
  assertEquals(callback.transcript, {
    schemaVersion: 1,
    provider: "deepgram",
    model: "nova-3",
    language: "tr",
    durationSeconds: 1,
    words: [{
      text: "merhaba",
      display: "Merhaba!",
      start: 0.12,
      end: 0.48,
      confidence: 0.98,
    }],
  });
});
Deno.test("Deepgram bozuk ID/kanal/süre/zaman/confidence reddedilir", () => {
  const provider = new DeepgramProvider("mock-only");
  for (
    const mutate of [
      (b: ReturnType<typeof deepgramResult>) => {
        b.metadata.request_id = "wrong";
      },
      (b: ReturnType<typeof deepgramResult>) => {
        b.metadata.channels = 2;
      },
      (b: ReturnType<typeof deepgramResult>) => {
        b.metadata.duration = 301;
      },
      (b: ReturnType<typeof deepgramResult>) => {
        b.results.channels[0].alternatives[0].words[0].end = 2;
      },
      (b: ReturnType<typeof deepgramResult>) => {
        b.results.channels[0].alternatives[0].words[0].confidence = 1.1;
      },
    ]
  ) {
    const body = deepgramResult();
    mutate(body);
    assertThrows(() => provider.parseCallback(body, "tr"));
  }
});
Deno.test("Deepgram HTTP timeout/429/bozuk kabul kör yeniden denenmez; hata içeriği sızmaz", async () => {
  for (const kind of ["timeout", "429", "bad-id"]) {
    let calls = 0;
    const http: typeof fetch = () => {
      calls++;
      if (kind === "timeout") throw new Error("private URL/token");
      return Promise.resolve(
        new Response(
          kind === "429"
            ? "private detail"
            : JSON.stringify({ request_id: "bad" }),
          { status: kind === "429" ? 429 : 200 },
        ),
      );
    };
    const provider = new DeepgramProvider("mock-only", http);
    const error = await assertRejects(() =>
      provider.submit({
        jobId: id,
        language: "tr",
        audioUrl: "https://storage.invalid/audio",
        callbackUrl: "https://callback.invalid/token",
      })
    );
    assertEquals(
      error instanceof Error && error.message.includes("private"),
      false,
    );
    assertEquals(calls, 1);
  }
});
Deno.test("Deepgram hata callback'i beyaz listedeki genel provider_failed olur", () => {
  assertEquals(
    new DeepgramProvider("mock-only").parseCallback({
      request_id: id,
      err_code: "REMOTE_ERROR",
      err_msg: "private",
    }, "tr"),
    {
      requestId: id,
      eventKey: "result:" + id,
      status: "failed",
      errorCode: "provider_failed",
    },
  );
});

Deno.test("300 sn sınırındaki encoder payı korunur; 250 ms üzeri reddedilir", () => {
  const body = deepgramResult();
  const provider = new DeepgramProvider("mock-only");
  body.metadata.duration = 300.25;
  assertEquals(
    provider.parseCallback(body, "tr").transcript?.durationSeconds,
    300.25,
  );
  body.metadata.duration = 300.251;
  assertThrows(() => provider.parseCallback(body, "tr"));
});
Deno.test("5 dk sentetik 2000 Türkçe kelime callback'i 1 MiB sınırına sığar (gerçek ölçüm değil)", () => {
  const body = deepgramResult();
  body.metadata.duration = 300;
  body.results.channels[0].alternatives[0].words = Array.from(
    { length: 2000 },
    (_, i) => ({
      word: "altyazı",
      punctuated_word: "Altyazı,",
      start: i * 0.15,
      end: i * 0.15 + 0.1,
      confidence: 0.98,
    }),
  );
  const bytes = new TextEncoder().encode(JSON.stringify(body)).length;
  assertEquals(bytes < 1024 * 1024, true);
  assertEquals(
    new DeepgramProvider("mock-only").parseCallback(body, "tr").transcript
      ?.words.length,
    2000,
  );
});
