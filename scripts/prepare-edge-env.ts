// Yerel .env girdisinden yalnız Edge'e gereken alanları ayırır. Değer loglamaz.
// DB şifresi asla Edge secret olarak yüklenmez. Üretilen .env.* Git-dışıdır.
const local = await Deno.readTextFile(".env.codex.local");
const key = local.split(/\r?\n/).find((line) =>
  line.startsWith("DEEPGRAM_API_KEY=")
)
  ?.slice("DEEPGRAM_API_KEY=".length).trim().replace(/^(['"])(.*)\1$/, "$2");
if (!key || /[\r\n]/.test(key)) throw new Error("Missing local Deepgram key");
const path = ".env.codex.edge";
let secret: string;
try {
  const existing = await Deno.readTextFile(path);
  secret = existing.match(/^DISPATCHER_SECRET=([a-f0-9]{64})$/m)?.[1] ?? "";
  if (!secret) {
    throw new Error("Existing edge env is invalid; do not rotate blindly");
  }
} catch (error) {
  if (!(error instanceof Deno.errors.NotFound)) throw error;
  secret = [...crypto.getRandomValues(new Uint8Array(32))]
    .map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
await Deno.writeTextFile(
  path,
  [
    "TRANSCRIPTION_PROVIDER=fake",
    "TRANSCRIPTION_MODEL=fake-v1",
    "PUBLIC_SUPABASE_URL=https://yjtpfyowzyszeoitlubx.supabase.co",
    "DISPATCHER_SECRET=" + secret,
    "DEEPGRAM_API_KEY=" + key,
    "",
  ].join("\n"),
  { mode: 0o600 },
);
// SQL yalnız yerel, repo-dışı dosyada; mevcut Vault değerlerine dokunmaz.
const vaultFile = Deno.env.get("LOCAL_VAULT_SQL_PATH");
if (!vaultFile) throw new Error("Missing repo-external LOCAL_VAULT_SQL_PATH");
await Deno.writeTextFile(
  vaultFile,
  `begin;
do $$ begin
  if exists(select 1 from vault.secrets where name in ('dispatcher_url','dispatcher_secret')) then
    raise exception 'dispatcher Vault records already exist: manual reconciliation required';
  end if;
end $$;
select vault.create_secret('https://yjtpfyowzyszeoitlubx.supabase.co/functions/v1/api/v1/internal/dispatch','dispatcher_url');
select vault.create_secret('${secret}','dispatcher_secret');
commit;\n`,
  { mode: 0o600 },
);
console.log(
  "Git-dışı Edge env ve repo-dışı Vault kurulum dosyası hazır; sırlar gösterilmedi.",
);
