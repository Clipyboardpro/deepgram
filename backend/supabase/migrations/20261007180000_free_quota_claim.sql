-- Kimlik başına ömür boyu tek hak + aynı kullanıcı kimlik değiştirse de tek hak.
-- Hash kaydı hesap silinince korunur; mevcut migration'lar değiştirilmez.
create or replace function public.grant_free_quota_once(
  p_user_id uuid, p_identity_hash text, p_seconds integer,
  p_valid_for interval default interval '30 days'
) returns public.quota_periods language plpgsql security definer set search_path = '' as $$
declare v_claimed boolean;
begin
  if p_identity_hash is null or p_identity_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid_identity_hash' using errcode='22023';
  end if;
  if p_seconds is null or p_seconds <= 0 or p_valid_for is null or p_valid_for <= interval '0 seconds' then
    raise exception 'invalid_seconds' using errcode='22023';
  end if;
  perform public._lock_user_quota(p_user_id);
  if exists(select 1 from public.quota_periods where user_id=p_user_id and source='free') then return null; end if;
  insert into public.free_quota_claims(identity_hash) values(p_identity_hash)
    on conflict(identity_hash) do nothing returning true into v_claimed;
  if v_claimed is null then return null; end if;
  return public.grant_quota(p_user_id,p_seconds,now(),now()+p_valid_for,'free','free:'||p_identity_hash);
end;
$$;
revoke all on function public.grant_free_quota_once(uuid,text,integer,interval) from PUBLIC,anon,authenticated;
grant execute on function public.grant_free_quota_once(uuid,text,integer,interval) to service_role;
