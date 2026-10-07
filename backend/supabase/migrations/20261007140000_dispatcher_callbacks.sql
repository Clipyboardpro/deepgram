-- CX-003: yeni migration; önceki uygulanmış dosyalar değiştirilmez.
alter table public.jobs add column inspected_duration_seconds double precision
  check (inspected_duration_seconds > 0 and inspected_duration_seconds < 'Infinity'::float8);
revoke select on public.jobs from authenticated;
grant select (id, user_id, kind, client_request_id, status, language, audio_sha256,
  audio_bytes, claimed_duration_seconds, verified_duration_seconds, storage_path,
  provider, model, provider_request_id, submission_started_at, attempt_count,
  error_code, price_version, estimated_cost_usd_micros, upload_expires_at,
  submitted_at, completed_at, created_at, updated_at) on public.jobs to authenticated;

create function public.record_job_audio_check(p_job_id uuid, p_duration double precision)
returns void language plpgsql security definer set search_path = '' as $$
declare v_job public.jobs; v_settings public.service_settings;
begin
  select * into v_job from public.jobs where id = p_job_id for update;
  if not found or v_job.status <> 'queued' or v_job.submission_started_at is not null then return; end if;
  select * into v_settings from public.service_settings;
  if p_duration is null or p_duration <= 0 or p_duration > v_job.claimed_duration_seconds + 0.25
      or p_duration > v_settings.max_audio_seconds + 0.25 or p_duration = 'NaN'::float8 then
    raise exception 'audio_duration_mismatch' using errcode = 'P0001';
  end if;
  update public.jobs set inspected_duration_seconds = p_duration where id = p_job_id;
end;
$$;

-- FakeProvider ağsızdır. Worker mark_submitted sonrası kesilirse aynı sonucu
-- yeni callback anahtarıyla teslim eder; provider.submit tekrar çağrılmaz.
create function public.recover_fake_callback(p_job_id uuid)
returns table(callback_token text) language plpgsql security definer set search_path = '' as $$
declare v_job public.jobs; v_token text;
begin
  select * into v_job from public.jobs where id = p_job_id for update;
  if not found or v_job.provider <> 'fake' or v_job.model <> 'fake-v1'
    or v_job.status <> 'submitted' or v_job.provider_request_id is null
    or v_job.inspected_duration_seconds is null then return; end if;
  v_token := public._random_token();
  update public.jobs set callback_token_hash = public._sha256_hex(v_token) where id = p_job_id;
  return query select v_token;
end;
$$;

-- Doğrulama ve mutasyon aynı transaction/row lock altında. Olay anahtarı iş
-- kimliğiyle isimlendirilir; iki iş birbirinin olayını kullanamaz.
create function public.apply_provider_callback(
  p_provider text, p_job_id uuid, p_token text, p_request_id text,
  p_event_key text, p_status text, p_transcript jsonb default null,
  p_error_code text default null
) returns public.jobs language plpgsql security definer set search_path = '' as $$
declare v_job public.jobs; v_event text; v_duration double precision;
begin
  select * into v_job from public.jobs where id = p_job_id for update;
  if not found or v_job.provider <> p_provider
    or public.verify_job_callback(p_job_id, p_token) is not true
    or v_job.provider_request_id is distinct from p_request_id then
    raise exception 'job_not_found' using errcode = 'P0002';
  end if;
  if p_event_key is null or length(p_event_key) not between 1 and 128 then
    raise exception 'invalid_callback' using errcode = 'P0001';
  end if;
  if v_job.status in ('succeeded', 'failed', 'canceled') then return v_job; end if;
  if v_job.status not in ('submitted', 'processing', 'unknown_provider_state') then
    raise exception 'invalid_job_state' using errcode = 'P0001';
  end if;
  v_event := 'callback:' || p_job_id::text || ':' || p_event_key;
  if p_status = 'succeeded' then
    v_duration := (p_transcript ->> 'durationSeconds')::double precision;
    if v_job.inspected_duration_seconds is null or v_duration is null
      or abs(v_duration - v_job.inspected_duration_seconds) > 0.25
      or v_duration = 'NaN'::float8 then
      raise exception 'audio_duration_mismatch' using errcode = 'P0001';
    end if;
    return public.complete_job(p_job_id,
      least(v_job.claimed_duration_seconds, ceil(v_job.inspected_duration_seconds)::integer),
      p_transcript, v_event);
  elsif p_status = 'failed' and p_error_code in ('provider_failed', 'invalid_audio', 'provider_timeout') then
    return public.fail_job(p_job_id, p_error_code, v_event);
  end if;
  raise exception 'invalid_callback' using errcode = 'P0001';
end;
$$;
revoke all on function public.record_job_audio_check(uuid, double precision),
  public.recover_fake_callback(uuid),
  public.apply_provider_callback(text, uuid, text, text, text, text, jsonb, text)
  from PUBLIC, anon, authenticated;
grant execute on function public.record_job_audio_check(uuid, double precision),
  public.recover_fake_callback(uuid),
  public.apply_provider_callback(text, uuid, text, text, text, text, jsonb, text) to service_role;

create extension if not exists pg_net with schema extensions;
create extension if not exists supabase_vault with schema vault;
create extension if not exists pgcrypto with schema extensions;
-- pg_net kuyruğuna ham secret/service_role yazılmaz: kısa ömürlü HMAC.
create function public.tick_dispatcher() returns bigint
language plpgsql security definer set search_path = '' as $$
declare v_url text; v_secret text; v_timestamp text; v_signature text;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'dispatcher_url';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'dispatcher_secret';
  if v_url is null or v_secret is null then return null; end if;
  v_timestamp := floor(extract(epoch from clock_timestamp()))::bigint::text;
  v_signature := encode(extensions.hmac(convert_to('dispatch:' || v_timestamp, 'UTF8'),
    convert_to(v_secret, 'UTF8'), 'sha256'), 'hex');
  return net.http_post(url := v_url,
    headers := jsonb_build_object('Content-Type', 'application/json',
      'X-Dispatcher-Timestamp', v_timestamp, 'X-Dispatcher-Signature', v_signature),
    body := '{}'::jsonb, timeout_milliseconds := 10000);
end;
$$;
revoke all on function public.tick_dispatcher() from PUBLIC, anon, authenticated, service_role;
select cron.schedule('dispatch-transcriptions', '* * * * *', $$select public.tick_dispatcher()$$);
