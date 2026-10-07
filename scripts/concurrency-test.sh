#!/usr/bin/env bash
# Eşzamanlı kota testi. pgTAP tek transaction içinde çalıştığı için gerçek
# eşzamanlılığı test edemez; burada aynı anda açılan ayrı psql oturumları
# kullanılır. db-test.sh içinden, PG* ortam değişkenleri ayarlıyken çağrılır.
set -euo pipefail

PSQL=(psql -X -q -t -A -v ON_ERROR_STOP=1)
U1=00000000-0000-0000-0000-0000000c0001
U2=00000000-0000-0000-0000-0000000c0002
U3=00000000-0000-0000-0000-0000000c0003
U4=00000000-0000-0000-0000-0000000c0004
fail=0

# Bariyer: tüm oturumlar bağlanıp hazır olana kadar bekletilir, sonra aynı
# anda serbest bırakılır. Böylece istekler gerçekten üst üste biner.
BARRIER=424242
hold_barrier() {
  "${PSQL[@]}" -c "select pg_advisory_lock($BARRIER); select pg_sleep(2);" >/dev/null &
  sleep 0.5
}
at_barrier() {
  "${PSQL[@]}" -c "select pg_advisory_lock_shared($BARRIER); select pg_advisory_unlock_shared($BARRIER);" -c "$1" >/dev/null 2>&1
}

check() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "ok - $desc"
  else
    echo "not ok - $desc (beklenen: $expected, gelen: $actual)"
    fail=1
  fi
}

"${PSQL[@]}" >/dev/null <<SQL
insert into auth.users (id) values ('$U1'), ('$U2'), ('$U3'), ('$U4');
insert into public.provider_prices (provider, model, price_version, usd_micros_per_minute, valid_from)
values ('fake', 'fake-conc', 'v1', 6000, now() - interval '1 day');
select public.grant_quota('$U1', 300, now() - interval '1 minute', now() + interval '30 days', 'manual', 'conc-1');
select public.grant_quota('$U2', 300, now() - interval '1 minute', now() + interval '30 days', 'manual', 'conc-2');
select public.grant_quota('$U3', 300, now() - interval '1 minute', now() + interval '30 days', 'manual', 'conc-3');
select public.grant_quota('$U4', 300, now() - interval '1 minute', now() + interval '30 days', 'manual', 'conc-4');
insert into public.jobs (id, user_id, client_request_id, language, audio_sha256, audio_bytes,
                         claimed_duration_seconds, storage_path, provider, model, upload_expires_at)
select ('00000000-0000-0000-0000-0000000d00' || lpad(n::text, 2, '0'))::uuid, '$U4', 'conc-direct-' || n,
       'tr', repeat('d', 64), 1000, 60, 'x', 'fake', 'fake-conc', now() + interval '1 hour'
from generate_series(1, 15) n;
SQL

# 1) 300 saniyelik kotaya aynı anda 60'ar saniyelik 15 farklı iş: tam 5'i geçmeli.
hold_barrier
for i in $(seq -w 1 15); do
  at_barrier "select public.create_transcription_job('$U1', 'conc-distinct-$i', 'tr', repeat('a', 64), 1000, 60, 'fake', 'fake-conc')" &
done
wait
check "eşzamanlı farklı işler kotayı aşmıyor (5 iş)" 5 \
  "$("${PSQL[@]}" -c "select count(*) from public.jobs where user_id = '$U1'")"
check "eşzamanlı farklı işlerde ayrılan toplam 300 sn" 300 \
  "$("${PSQL[@]}" -c "select coalesce(sum(reserved_seconds), 0) from public.quota_reservations where user_id = '$U1' and status = 'active'")"

# 1b) Aynı senaryo doğrudan reserve_quota ile (iş oluşturmadaki diğer
#     kilitlerden bağımsız olarak kota kilidinin kendisini sınar).
hold_barrier
for i in $(seq -w 1 15); do
  at_barrier "select public.reserve_quota('$U4', '00000000-0000-0000-0000-0000000d00$i', 60)" &
done
wait
check "eşzamanlı doğrudan ayırmalar kotayı aşmıyor (300 sn)" 300 \
  "$("${PSQL[@]}" -c "select coalesce(sum(reserved_seconds), 0) from public.quota_reservations where user_id = '$U4' and status = 'active'")"

# 2) Aynı istek kimliğiyle aynı anda 10 istek: tek iş, tek rezervasyon.
hold_barrier
for i in $(seq 1 10); do
  at_barrier "select public.create_transcription_job('$U2', 'conc-same-0001', 'tr', repeat('b', 64), 1000, 60, 'fake', 'fake-conc')" &
done
wait
check "aynı istek eşzamanlı tekrarlanınca tek iş açılıyor" 1 \
  "$("${PSQL[@]}" -c "select count(*) from public.jobs where user_id = '$U2'")"
check "aynı istek eşzamanlı tekrarlanınca tek rezervasyon" 60 \
  "$("${PSQL[@]}" -c "select coalesce(sum(reserved_seconds), 0) from public.quota_reservations where user_id = '$U2'")"

# 3) Aynı webhook aynı anda 10 kez: kota bir kez kesinleşiyor.
JOB=$("${PSQL[@]}" -c "select (public.create_transcription_job('$U3', 'conc-hook-0001', 'tr', repeat('c', 64), 1000, 60, 'fake', 'fake-conc')).id")
"${PSQL[@]}" >/dev/null <<SQL
select public.mark_job_uploaded('$U3', '$JOB');
select public.claim_job_for_submission('$JOB');
select public.mark_job_submitted('$JOB', 'conc-prov-1');
SQL
hold_barrier
for i in $(seq 1 10); do
  at_barrier "select public.complete_job('$JOB', 45, '{}'::jsonb, 'conc-evt-1')" &
done
wait
check "eşzamanlı tekrar webhook kotayı bir kez düşüyor" "1|45" \
  "$("${PSQL[@]}" -c "select count(*) || '|' || sum(seconds) from public.usage_ledger where job_id = '$JOB'")"
check "eşzamanlı tekrar webhook tek sonuç yazıyor" 1 \
  "$("${PSQL[@]}" -c "select count(*) from public.job_results where job_id = '$JOB'")"

# CX-007: aynı kullanıcı farklı kimlikle, sonra farklı kullanıcı aynı kimlikle yarışır.
hold_barrier
for i in $(seq 1 10); do
  at_barrier "select public.grant_free_quota_once('$U1', lpad('$i',64,'e'), 60, interval '7 days')" &
done
wait
check "aynı kullanıcının eşzamanlı farklı kimlikleri tek ücretsiz hak" 1 \
  "$("${PSQL[@]}" -c "select count(*) from public.quota_periods where user_id='$U1' and source='free'")"
hold_barrier
for user_id in "$U2" "$U3" "$U4"; do
  at_barrier "select public.grant_free_quota_once('$user_id', repeat('f',64), 60, interval '7 days')" &
done
wait
check "aynı kimlik eşzamanlı farklı kullanıcılara tek hak verir" 1 \
  "$("${PSQL[@]}" -c "select count(*) from public.quota_periods where source_ref='free:' || repeat('f',64)")"

exit $fail
