#!/usr/bin/env bash
# Yalnız yerel, geçici Supabase test yığını. Anahtarlar/loglar yazdırılmaz.
set -euo pipefail
test_dir=$(mktemp -d)
function_pid=''
cleanup() {
  if [[ -n "$function_pid" ]]; then kill "$function_pid" 2>/dev/null || true; fi
  # Yalnız bu scriptin mktemp ile oluşturduğu dizin temizlenir.
  rm -f -- "$test_dir/audio.m4a" "$test_dir/functions.log"
  rmdir -- "$test_dir"
}
trap cleanup EXIT
status=$(supabase status --workdir backend --output json)
export SUPABASE_URL=$(jq -r '.API_URL' <<<"$status")
export SUPABASE_ANON_KEY=$(jq -r '.ANON_KEY' <<<"$status")
export SUPABASE_SERVICE_ROLE_KEY=$(jq -r '.SERVICE_ROLE_KEY' <<<"$status")
export SMOKE_AUDIO_PATH="$test_dir/audio.m4a"
ffmpeg -hide_banner -loglevel error -f lavfi -i 'sine=frequency=440:duration=1' -c:a aac "$SMOKE_AUDIO_PATH"
supabase functions serve api --workdir backend --env-file backend/supabase/functions/.env.example >"$test_dir/functions.log" 2>&1 &
function_pid=$!
ready=0
for i in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$SUPABASE_URL/functions/v1/api/v1/quota" || true)
  if [[ "$code" == 401 ]]; then ready=1; break; fi
  sleep 1
done
if [[ "$ready" != 1 ]]; then echo 'API hazır olmadı; function logunu yerelde inceleyin.'; exit 1; fi
deno run --allow-env --allow-net --allow-read --config backend/supabase/functions/deno.json scripts/api-smoke.ts
