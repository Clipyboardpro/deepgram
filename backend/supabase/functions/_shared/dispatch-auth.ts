async function signature(secret: string, timestamp: string): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return Array.from(
    new Uint8Array(
      await crypto.subtle.sign(
        "HMAC",
        key,
        encoder.encode("dispatch:" + timestamp),
      ),
    ),
    (b) => b.toString(16).padStart(2, "0"),
  ).join("");
}
export async function dispatchHeaders(
  secret: string,
  now = Date.now(),
): Promise<Record<string, string>> {
  const timestamp = String(Math.floor(now / 1000));
  return {
    "X-Dispatcher-Timestamp": timestamp,
    "X-Dispatcher-Signature": await signature(secret, timestamp),
  };
}
export async function verifyDispatch(
  headers: Headers,
  secret: string,
  now = Date.now(),
): Promise<boolean> {
  const timestamp = headers.get("X-Dispatcher-Timestamp") ?? "";
  const supplied = headers.get("X-Dispatcher-Signature") ?? "";
  if (
    !/^\d{10}$/.test(timestamp) || !/^[a-f0-9]{64}$/.test(supplied) ||
    Math.abs(now / 1000 - Number(timestamp)) > 60
  ) return false;
  const expected = await signature(secret, timestamp);
  let difference = 0;
  for (let n = 0; n < 64; n++) {
    difference |= expected.charCodeAt(n) ^ supplied.charCodeAt(n);
  }
  return difference === 0;
}
