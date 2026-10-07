-- CX-003b: kabul edilen sağlayıcı requestId'si mark sırasında kaybolmasın.
create function public.remember_provider_submission(p_job_id uuid, p_request_id text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_job public.jobs;
begin
  select * into v_job from public.jobs where id = p_job_id for update;
  if not found or v_job.submission_started_at is null then
    raise exception 'invalid_job_state' using errcode = 'P0001';
  end if;
  if p_request_id is null or length(p_request_id) not between 1 and 256 then
    raise exception 'invalid_callback' using errcode = 'P0001';
  end if;
  if v_job.provider_request_id is not null and v_job.provider_request_id <> p_request_id then
    raise exception 'provider_request_id_mismatch' using errcode = 'P0001';
  end if;
  if exists(select 1 from public.provider_events where job_id = p_job_id and kind = 'submit'
    and outcome = 'accepted_pending_mark' and provider_request_id <> p_request_id) then
    raise exception 'provider_request_id_mismatch' using errcode = 'P0001';
  end if;
  insert into public.provider_events(provider,event_key,job_id,provider_request_id,kind,outcome)
  values(v_job.provider,'accepted:' || p_job_id::text,p_job_id,p_request_id,'submit','accepted_pending_mark')
  on conflict(provider,event_key) do nothing;
end;
$$;
create function public.resume_provider_submission(p_job_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_job public.jobs; v_request_id text;
begin
  select * into v_job from public.jobs where id = p_job_id for update;
  if not found or v_job.status not in ('queued','unknown_provider_state') then return; end if;
  select provider_request_id into v_request_id from public.provider_events
    where job_id = p_job_id and provider = v_job.provider and kind = 'submit'
      and outcome = 'accepted_pending_mark' order by received_at limit 1;
  if v_request_id is not null then perform public.mark_job_submitted(p_job_id,v_request_id); end if;
end;
$$;
create function public.mark_submission_unknown(p_job_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.jobs j set status = 'unknown_provider_state', error_code = 'submission_outcome_unknown'
    where j.id = p_job_id and j.status = 'queued' and j.submission_started_at is not null
      and j.provider_request_id is null;
end;
$$;
-- Bütün DB yazmaları kesilmişse requestId ancak sağlayıcıdan gelen güvenilir
-- callback'te tekrar görülebilir. Token doğrulaması/onarım/sonuç tek transaction.
create function public.receive_provider_callback(
  p_provider text, p_job_id uuid, p_token text, p_request_id text,
  p_event_key text, p_status text, p_transcript jsonb default null,
  p_error_code text default null
) returns public.jobs language plpgsql security definer set search_path = '' as $$
declare v_job public.jobs;
begin
  select * into v_job from public.jobs where id = p_job_id for update;
  if not found or v_job.provider <> p_provider or public.verify_job_callback(p_job_id,p_token) is not true then
    raise exception 'job_not_found' using errcode = 'P0002';
  end if;
  if v_job.provider_request_id is null and v_job.status in ('queued','unknown_provider_state')
    and v_job.submission_started_at is not null and v_job.inspected_duration_seconds is not null then
    perform public.remember_provider_submission(p_job_id,p_request_id);
    perform public.mark_job_submitted(p_job_id,p_request_id);
  end if;
  return public.apply_provider_callback(p_provider,p_job_id,p_token,p_request_id,p_event_key,p_status,p_transcript,p_error_code);
end;
$$;
revoke all on function public.remember_provider_submission(uuid,text), public.resume_provider_submission(uuid),
  public.mark_submission_unknown(uuid), public.receive_provider_callback(text,uuid,text,text,text,text,jsonb,text)
  from PUBLIC, anon, authenticated;
grant execute on function public.remember_provider_submission(uuid,text), public.resume_provider_submission(uuid),
  public.mark_submission_unknown(uuid), public.receive_provider_callback(text,uuid,text,text,text,text,jsonb,text)
  to service_role;
