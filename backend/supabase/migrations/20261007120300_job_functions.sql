-- Çözümleme işi yaşam döngüsü ve dağıtım kuyruğu (pgmq).
--
--   create_transcription_job   istemci isteği → awaiting_upload (+ kota rezervasyonu)
--   mark_job_uploaded          yükleme bitti   → queued (+ kuyruğa mesaj)
--   dequeue_dispatch           dispatcher kuyruktan iş alır (görünmezlik süresi = kira)
--   claim_job_for_submission   sağlayıcıya göndermeden hemen önce; geri dönüş anahtarı üretir
--   mark_job_submitted         sağlayıcı istek kimliği kaydedilir → submitted
--   complete_job               sonuç geldi → succeeded (+ sonuç, kota kesinleşir)
--   fail_job                   hata       → failed (+ kota bırakılır)
--   cancel_job                 kullanıcı iptali (yalnız sağlayıcıya gönderilmeden önce)
--   cleanup_expired_work       zamanlanmış temizlik
--
-- Bu fonksiyonları yalnız Edge Function'lar service_role ile çağırır.

create extension if not exists pgmq;

select pgmq.create('transcription_dispatch');

-- Hata kodları istemciye/Edge Function'a 'P0001' + mesaj olarak döner;
-- mesaj metni sabit bir koddur (ör. 'insufficient_quota').

create or replace function public._random_token()
returns text
language sql
volatile
set search_path = ''
as $$
  -- İki rastgele UUID (~244 bit) + saat, sha256 ile 64 hex karaktere indirgenir.
  select encode(
    sha256(convert_to(gen_random_uuid()::text || gen_random_uuid()::text || clock_timestamp()::text, 'UTF8')),
    'hex'
  );
$$;

create or replace function public._sha256_hex(p_value text)
returns text
language sql
immutable
set search_path = ''
as $$
  select encode(sha256(convert_to(p_value, 'UTF8')), 'hex');
$$;

-- ---------------------------------------------------------------------------

create or replace function public.create_transcription_job(
  p_user_id            uuid,
  p_client_request_id  text,
  p_language           text,
  p_audio_sha256       text,
  p_audio_bytes        bigint,
  p_claimed_seconds    integer,
  p_provider           text,
  p_model              text
)
returns public.jobs
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job          public.jobs;
  v_settings     public.service_settings;
  v_price        public.provider_prices;
  v_recent_jobs  integer;
  v_spent_today  bigint;
  v_estimate     bigint;
  v_job_id       uuid := gen_random_uuid();
begin
  if not exists (select 1 from public.profiles where id = p_user_id) then
    raise exception 'profile_not_found' using errcode = 'P0002';
  end if;

  -- Aynı kullanıcının iş oluşturma ve kota işlemleri sıraya girer.
  perform public._lock_user_quota(p_user_id);

  select * into v_job
  from public.jobs
  where user_id = p_user_id and client_request_id = p_client_request_id;

  if found then
    if v_job.audio_sha256 <> p_audio_sha256 then
      raise exception 'client_request_id_reused' using errcode = 'P0001';
    end if;
    return v_job;
  end if;

  select * into v_settings from public.service_settings;

  if not v_settings.ai_jobs_enabled then
    raise exception 'ai_jobs_disabled' using errcode = 'P0001';
  end if;
  if p_claimed_seconds is null or p_claimed_seconds <= 0 then
    raise exception 'invalid_duration' using errcode = 'P0001';
  end if;
  if p_claimed_seconds > v_settings.max_audio_seconds then
    raise exception 'audio_too_long' using errcode = 'P0001';
  end if;
  if p_audio_bytes is null or p_audio_bytes <= 0 or p_audio_bytes > v_settings.max_audio_bytes then
    raise exception 'audio_too_large' using errcode = 'P0001';
  end if;

  select count(*) into v_recent_jobs
  from public.jobs
  where user_id = p_user_id and created_at > now() - interval '1 hour';

  if v_recent_jobs >= v_settings.jobs_per_user_per_hour then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;

  select * into v_price
  from public.provider_prices
  where provider = p_provider and model = p_model and valid_from <= now()
  order by valid_from desc
  limit 1;

  if not found then
    raise exception 'price_not_configured' using errcode = 'P0001';
  end if;

  v_estimate := ceil(p_claimed_seconds * v_price.usd_micros_per_minute / 60.0)::bigint;

  -- Günlük AI bütçesi tüm kullanıcılar için ortaktır; kontrol sıraya girer.
  perform pg_advisory_xact_lock(hashtextextended('daily_budget', 0));

  select coalesce(sum(estimated_cost_usd_micros), 0) into v_spent_today
  from public.jobs
  where created_at >= date_trunc('day', now() at time zone 'utc') at time zone 'utc'
    and status <> 'canceled';

  if v_spent_today + v_estimate > v_settings.daily_budget_usd_micros then
    raise exception 'daily_budget_exceeded' using errcode = 'P0001';
  end if;

  insert into public.jobs (
    id, user_id, client_request_id, language, audio_sha256, audio_bytes,
    claimed_duration_seconds, storage_path, provider, model, price_version,
    estimated_cost_usd_micros, upload_expires_at
  ) values (
    v_job_id, p_user_id, p_client_request_id, p_language, p_audio_sha256, p_audio_bytes,
    p_claimed_seconds, p_user_id::text || '/' || v_job_id::text || '.m4a', p_provider, p_model,
    v_price.price_version, v_estimate, now() + v_settings.upload_ttl
  )
  returning * into v_job;

  -- Kota yetmezse istisna tüm transaction'ı (iş kaydı dahil) geri alır.
  perform public.reserve_quota(p_user_id, v_job.id, p_claimed_seconds);

  return v_job;
end;
$$;

-- ---------------------------------------------------------------------------

create or replace function public.mark_job_uploaded(p_user_id uuid, p_job_id uuid)
returns public.jobs
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job public.jobs;
begin
  select * into v_job
  from public.jobs
  where id = p_job_id and user_id = p_user_id
  for update;

  if not found then
    raise exception 'job_not_found' using errcode = 'P0002';
  end if;

  if v_job.status <> 'awaiting_upload' then
    return v_job;
  end if;

  if v_job.upload_expires_at <= now() then
    raise exception 'upload_expired' using errcode = 'P0001';
  end if;

  update public.jobs set status = 'queued'
  where id = p_job_id
  returning * into v_job;

  perform pgmq.send('transcription_dispatch', jsonb_build_object('job_id', p_job_id));

  return v_job;
end;
$$;

-- ---------------------------------------------------------------------------
-- Kuyruk sarmalayıcıları (Edge Function'lar yalnız public şemayı çağırabilir)
-- ---------------------------------------------------------------------------

-- p_visibility_seconds: mesaj bu süre boyunca başka dispatcher'a görünmez
-- (kira). Süre içinde ack_dispatch çağrılmazsa mesaj tekrar görünür.
create or replace function public.dequeue_dispatch(
  p_visibility_seconds  integer default 120,
  p_batch_size          integer default 5
)
returns table (msg_id bigint, read_count integer, job_id uuid)
language sql
security definer
set search_path = ''
as $$
  select m.msg_id, m.read_ct, (m.message ->> 'job_id')::uuid
  from pgmq.read('transcription_dispatch', p_visibility_seconds, p_batch_size) m;
$$;

create or replace function public.ack_dispatch(p_msg_id bigint)
returns boolean
language sql
security definer
set search_path = ''
as $$
  select pgmq.delete('transcription_dispatch', p_msg_id);
$$;

-- ---------------------------------------------------------------------------

-- Sağlayıcıya göndermeden hemen önce çağrılır. İş gönderilebilir durumdaysa
-- yeni bir geri dönüş anahtarı üretip (yalnız bir kez, düz metin) döner.
-- Önceki deneme gönderime başlayıp sağlayıcı kimliği alamadıysa iş
-- 'unknown_provider_state' olur ve körlemesine tekrar gönderilmez: boş döner.
create or replace function public.claim_job_for_submission(p_job_id uuid)
returns table (
  job_id          uuid,
  user_id         uuid,
  storage_path    text,
  language        text,
  provider        text,
  model           text,
  callback_token  text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job    public.jobs;
  v_token  text;
begin
  select * into v_job from public.jobs j where j.id = p_job_id for update;

  if not found or v_job.status <> 'queued' then
    return;
  end if;

  if v_job.submission_started_at is not null and v_job.provider_request_id is null then
    update public.jobs j
    set status = 'unknown_provider_state', error_code = 'submission_outcome_unknown'
    where j.id = p_job_id;
    return;
  end if;

  v_token := public._random_token();

  update public.jobs j
  set submission_started_at = now(),
      attempt_count = j.attempt_count + 1,
      callback_token_hash = public._sha256_hex(v_token)
  where j.id = p_job_id;

  return query
  select v_job.id, v_job.user_id, v_job.storage_path, v_job.language,
         v_job.provider, v_job.model, v_token;
end;
$$;

create or replace function public.mark_job_submitted(p_job_id uuid, p_provider_request_id text)
returns public.jobs
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job public.jobs;
begin
  select * into v_job from public.jobs where id = p_job_id for update;

  if not found then
    raise exception 'job_not_found' using errcode = 'P0002';
  end if;

  if v_job.provider_request_id is not null then
    if v_job.provider_request_id <> p_provider_request_id then
      raise exception 'provider_request_id_mismatch' using errcode = 'P0001';
    end if;
    return v_job;
  end if;

  if v_job.status not in ('queued', 'unknown_provider_state') then
    raise exception 'invalid_job_state' using errcode = 'P0001';
  end if;

  update public.jobs
  set status = 'submitted', provider_request_id = p_provider_request_id,
      submitted_at = now(), error_code = null
  where id = p_job_id
  returning * into v_job;

  insert into public.provider_events (provider, event_key, job_id, provider_request_id, kind, outcome)
  values (v_job.provider, 'submit:' || p_provider_request_id, p_job_id, p_provider_request_id, 'submit', 'submitted')
  on conflict (provider, event_key) do nothing;

  return v_job;
end;
$$;

-- Webhook'un bu işe ait olduğunu doğrular (sabit zamanlı karşılaştırma
-- gerekmez: düz anahtar değil, özetler karşılaştırılıyor).
create or replace function public.verify_job_callback(p_job_id uuid, p_token text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select j.callback_token_hash = public._sha256_hex(p_token)
     from public.jobs j where j.id = p_job_id),
    false
  );
$$;

-- ---------------------------------------------------------------------------

-- Sonuç geldi. p_event_key aynı sağlayıcı olayını tekilleştirir; tekrar gelen
-- webhook işi ve kotayı yeniden değiştirmez.
create or replace function public.complete_job(
  p_job_id             uuid,
  p_verified_seconds   integer,
  p_transcript         jsonb,
  p_event_key          text,
  p_kind               text default 'webhook'
)
returns public.jobs
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job       public.jobs;
  v_price     bigint;
  v_settings  public.service_settings;
begin
  select * into v_job from public.jobs where id = p_job_id for update;

  if not found then
    raise exception 'job_not_found' using errcode = 'P0002';
  end if;

  insert into public.provider_events (provider, event_key, job_id, provider_request_id, kind, outcome)
  values (v_job.provider, p_event_key, p_job_id, v_job.provider_request_id, p_kind, 'succeeded')
  on conflict (provider, event_key) do nothing;

  if v_job.status = 'succeeded' then
    return v_job;
  end if;

  if v_job.status not in ('submitted', 'processing', 'unknown_provider_state') then
    raise exception 'invalid_job_state' using errcode = 'P0001';
  end if;

  select * into v_settings from public.service_settings;

  select p.usd_micros_per_minute into v_price
  from public.provider_prices p
  where p.provider = v_job.provider and p.model = v_job.model
    and p.price_version = v_job.price_version;

  update public.jobs
  set status = 'succeeded',
      verified_duration_seconds = p_verified_seconds,
      estimated_cost_usd_micros = coalesce(
        ceil(greatest(p_verified_seconds, 0) * v_price / 60.0)::bigint,
        estimated_cost_usd_micros),
      completed_at = now(),
      error_code = null
  where id = p_job_id
  returning * into v_job;

  insert into public.job_results (job_id, user_id, transcript, expires_at)
  values (p_job_id, v_job.user_id, p_transcript, now() + v_settings.result_ttl);

  perform public.commit_quota(p_job_id, p_verified_seconds);

  return v_job;
end;
$$;

create or replace function public.fail_job(
  p_job_id      uuid,
  p_error_code  text,
  p_event_key   text default null,
  p_kind        text default 'webhook'
)
returns public.jobs
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job public.jobs;
begin
  select * into v_job from public.jobs where id = p_job_id for update;

  if not found then
    raise exception 'job_not_found' using errcode = 'P0002';
  end if;

  if p_event_key is not null then
    insert into public.provider_events (provider, event_key, job_id, provider_request_id, kind, outcome)
    values (v_job.provider, p_event_key, p_job_id, v_job.provider_request_id, p_kind, 'failed')
    on conflict (provider, event_key) do nothing;
  end if;

  if v_job.status in ('succeeded', 'failed', 'canceled') then
    return v_job;
  end if;

  update public.jobs
  set status = 'failed', error_code = p_error_code, completed_at = now()
  where id = p_job_id
  returning * into v_job;

  perform public.release_quota(p_job_id);

  return v_job;
end;
$$;

create or replace function public.cancel_job(p_user_id uuid, p_job_id uuid)
returns public.jobs
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job public.jobs;
begin
  select * into v_job
  from public.jobs
  where id = p_job_id and user_id = p_user_id
  for update;

  if not found then
    raise exception 'job_not_found' using errcode = 'P0002';
  end if;

  if v_job.status = 'canceled' then
    return v_job;
  end if;

  -- Sağlayıcıya gönderildiyse maliyet oluşmuştur; iptal kabul edilmez.
  if v_job.status not in ('awaiting_upload', 'queued') or v_job.submission_started_at is not null then
    raise exception 'job_not_cancelable' using errcode = 'P0001';
  end if;

  update public.jobs
  set status = 'canceled', completed_at = now()
  where id = p_job_id
  returning * into v_job;

  perform public.release_quota(p_job_id);

  return v_job;
end;
$$;

-- ---------------------------------------------------------------------------

-- Süresi dolan yüklemeleri iptal eder, rezervasyonları düşürür, eski
-- sonuçları siler. Depolamadaki ses dosyaları Edge Function tarafından
-- Storage API ile silinir (storage.objects'e doğrudan dokunulmaz).
create or replace function public.cleanup_expired_work()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job_id               uuid;
  v_canceled_uploads     integer := 0;
  v_expired_reservations integer;
  v_deleted_results      integer;
begin
  for v_job_id in
    select id from public.jobs
    where status = 'awaiting_upload' and upload_expires_at <= now()
    for update skip locked
  loop
    update public.jobs
    set status = 'canceled', error_code = 'upload_expired', completed_at = now()
    where id = v_job_id;
    perform public.release_quota(v_job_id);
    v_canceled_uploads := v_canceled_uploads + 1;
  end loop;

  v_expired_reservations := public.expire_quota_reservations();

  delete from public.job_results where expires_at <= now();
  get diagnostics v_deleted_results = row_count;

  return jsonb_build_object(
    'canceled_uploads', v_canceled_uploads,
    'expired_reservations', v_expired_reservations,
    'deleted_results', v_deleted_results
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Satın alma
-- ---------------------------------------------------------------------------

-- App Store Server Notification V2 kaydı. notification_uuid ile idempotent.
-- Kullanıcı appAccountToken üzerinden bulunur. is_new=false ise olay daha
-- önce işlenmiştir; Edge Function hakları tekrar uygulamamalıdır.
create or replace function public.record_purchase_event(
  p_notification_uuid        uuid,
  p_notification_type        text,
  p_subtype                  text,
  p_environment              text,
  p_app_account_token        uuid,
  p_product_id               text,
  p_original_transaction_id  text,
  p_transaction_id           text,
  p_signed_date              timestamptz
)
returns table (event_id uuid, user_id uuid, is_new boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id  uuid;
  v_event_id uuid;
begin
  select pr.id into v_user_id
  from public.profiles pr
  where pr.app_account_token = p_app_account_token;

  insert into public.purchase_events (
    notification_uuid, notification_type, subtype, environment, app_account_token,
    user_id, product_id, original_transaction_id, transaction_id, signed_date
  ) values (
    p_notification_uuid, p_notification_type, p_subtype, p_environment, p_app_account_token,
    v_user_id, p_product_id, p_original_transaction_id, p_transaction_id, p_signed_date
  )
  on conflict (notification_uuid) do nothing
  returning id into v_event_id;

  if v_event_id is not null then
    return query select v_event_id, v_user_id, true;
  else
    return query
    select e.id, e.user_id, false
    from public.purchase_events e
    where e.notification_uuid = p_notification_uuid;
  end if;
end;
$$;

create or replace function public.mark_purchase_event_processed(p_event_id uuid, p_error text default null)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.purchase_events
  set processed_at = now(), process_error = p_error
  where id = p_event_id;
$$;

-- Pro hakkını ekler/günceller (yenileme, iptal, iade). original_transaction_id
-- ile idempotent.
create or replace function public.upsert_pro_entitlement(
  p_user_id                  uuid,
  p_product_id               text,
  p_original_transaction_id  text,
  p_starts_at                timestamptz,
  p_expires_at               timestamptz,
  p_revoked_at               timestamptz
)
returns public.entitlements
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ent public.entitlements;
begin
  insert into public.entitlements (user_id, kind, product_id, original_transaction_id, starts_at, expires_at, revoked_at)
  values (p_user_id, 'pro', p_product_id, p_original_transaction_id, p_starts_at, p_expires_at, p_revoked_at)
  on conflict (original_transaction_id, kind) do update
    set product_id = excluded.product_id,
        expires_at = excluded.expires_at,
        revoked_at = excluded.revoked_at
  returning * into v_ent;

  if v_ent.user_id <> p_user_id then
    raise exception 'transaction_belongs_to_another_user' using errcode = '42501';
  end if;

  return v_ent;
end;
$$;

-- ---------------------------------------------------------------------------
-- Yetkiler
-- ---------------------------------------------------------------------------

revoke execute on function
  public._random_token(),
  public._sha256_hex(text),
  public.create_transcription_job(uuid, text, text, text, bigint, integer, text, text),
  public.mark_job_uploaded(uuid, uuid),
  public.dequeue_dispatch(integer, integer),
  public.ack_dispatch(bigint),
  public.claim_job_for_submission(uuid),
  public.mark_job_submitted(uuid, text),
  public.verify_job_callback(uuid, text),
  public.complete_job(uuid, integer, jsonb, text, text),
  public.fail_job(uuid, text, text, text),
  public.cancel_job(uuid, uuid),
  public.cleanup_expired_work(),
  public.record_purchase_event(uuid, text, text, text, uuid, text, text, text, timestamptz),
  public.mark_purchase_event_processed(uuid, text),
  public.upsert_pro_entitlement(uuid, text, text, timestamptz, timestamptz, timestamptz)
from public, anon, authenticated;

grant execute on function
  public.create_transcription_job(uuid, text, text, text, bigint, integer, text, text),
  public.mark_job_uploaded(uuid, uuid),
  public.dequeue_dispatch(integer, integer),
  public.ack_dispatch(bigint),
  public.claim_job_for_submission(uuid),
  public.mark_job_submitted(uuid, text),
  public.verify_job_callback(uuid, text),
  public.complete_job(uuid, integer, jsonb, text, text),
  public.fail_job(uuid, text, text, text),
  public.cancel_job(uuid, uuid),
  public.cleanup_expired_work(),
  public.record_purchase_event(uuid, text, text, text, uuid, text, text, text, timestamptz),
  public.mark_purchase_event_processed(uuid, text),
  public.upsert_pro_entitlement(uuid, text, text, timestamptz, timestamptz, timestamptz)
to service_role;
