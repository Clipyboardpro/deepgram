import { assertEquals } from "@std/assert";
import { Ajv2020 } from "ajv";
import { FakeProvider } from "../_shared/provider.ts";
const schema = JSON.parse(
  await Deno.readTextFile(
    new URL("../../../../contracts/transcript.schema.json", import.meta.url),
  ),
);
const example = JSON.parse(
  await Deno.readTextFile(
    new URL(
      "../../../../contracts/examples/transcript-v1.json",
      import.meta.url,
    ),
  ),
);
const validate = new Ajv2020({ strict: true }).compile(schema);
Deno.test("IS-BOLUMU §3 örneği transcript v1 sözleşmesine uyar", () => {
  assertEquals(validate(example), true);
});
Deno.test("display/confidence isteğe bağlı; bilinmeyen alanlar tolere edilir", () => {
  assertEquals(
    validate({
      ...example,
      future: true,
      words: [{ text: "merhaba", start: 0.12, end: 0.48, future: 1 }],
    }),
    true,
  );
});
Deno.test("sürüm, süre, confidence ve zorunlu alan ihlalleri reddedilir", () => {
  for (
    const invalid of [{ ...example, schemaVersion: 2 }, {
      ...example,
      durationSeconds: -1,
    }, {
      ...example,
      words: [{ text: "a", start: 0, end: 1, confidence: 1.1 }],
    }, { ...example, words: [{ text: "a", end: 1 }] }]
  ) assertEquals(validate(invalid), false);
});
Deno.test("FakeProvider ağ izni olmadan sabit ve bağımsız sonuç döndürür", async () => {
  const provider = new FakeProvider();
  const submitted = await provider.submit({
    jobId: "job-1",
    audioUrl: "https://not-called.invalid",
    callbackUrl: "https://not-called.invalid",
    language: "tr",
  });
  assertEquals(submitted.requestId, "fake:job-1");
  const first = await provider.result(submitted.requestId);
  const second = await provider.result(submitted.requestId);
  assertEquals(first, second);
  assertEquals(validate(first), true);
  first.words[0].text = "mutated";
  assertEquals(second.words[0].text, "merhaba");
});
