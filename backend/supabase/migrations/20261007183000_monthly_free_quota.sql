-- CX-008: Europe/Istanbul takvim ayı. Süre devretmez; saat yalnız DB'den gelir.
create table public.monthly_free_quota_claims (
  identity_hash text not null check (identity_hash ~ '^[0-9a-f]{64}$'),
  month_start date not null check (extract(day from month_start)=1),
  user_id uuid, -- FK yok: hesap silinse de ayın hak kaydı kalır.
  claimed_at timestamptz not null default now(),
  primary key (identity_hash,month_start),
  unique (user_id,month_start)
);
alter table public.monthly_free_quota_claims enable row level security;
revoke all on public.monthly_free_quota_claims from PUBLIC,anon,authenticated;
grant select,insert,delete on public.monthly_free_quota_claims to service_role;
comment on table public.monthly_free_quota_claims is
  'Ay başına bir kimlik ve bir kullanıcı hakkı; hesap silinince tombstone korunur.';

-- Önceki tek-sefer hakları yalnız verildikleri ay için koru (silinen hesaplar dahil).
insert into public.monthly_free_quota_claims(identity_hash,month_start,user_id,claimed_at)
select c.identity_hash, date_trunc('month',c.claimed_at at time zone 'Europe/Istanbul')::date,
  (select p.user_id from public.quota_periods p where p.source='free'
   and p.source_ref='free:'||c.identity_hash limit 1), c.claimed_at
from public.free_quota_claims c;

-- Eski ücretsiz dönemlerin kalan süresi sonraki aya taşınmasın.
update public.quota_periods set ends_at=least(ends_at,
  (date_trunc('month',starts_at at time zone 'Europe/Istanbul')+interval '1 month')
    at time zone 'Europe/Istanbul') where source='free';

-- Sınır testi için zaman girdili iç yardımcı; API rollerine/servis rolüne kapalı.
create function public._grant_monthly_free_quota_at(
  p_user_id uuid,p_identity_hash text,p_seconds integer,p_at timestamptz
) returns public.quota_periods language plpgsql security definer set search_path='' as $$
declare
  v_local timestamp;
  v_start timestamptz;
  v_end timestamptz;
  v_claimed boolean;
begin
  if p_identity_hash is null or p_identity_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid_identity_hash' using errcode='22023';
  end if;
  if p_user_id is null or p_at is null or p_seconds is null or p_seconds<=0 then
    raise exception 'invalid_seconds' using errcode='22023';
  end if;
  v_local := date_trunc('month',p_at at time zone 'Europe/Istanbul');
  v_start := v_local at time zone 'Europe/Istanbul';
  v_end := (v_local+interval '1 month') at time zone 'Europe/Istanbul';
  perform public._lock_user_quota(p_user_id);
  -- İki unique kuralı aynı INSERT'te: kullanıcı veya kimlik yarışı tek hak verir.
  insert into public.monthly_free_quota_claims(identity_hash,month_start,user_id,claimed_at)
    values(p_identity_hash,v_local::date,p_user_id,p_at)
    on conflict do nothing returning true into v_claimed;
  if v_claimed is null then return null; end if;
  return public.grant_quota(p_user_id,p_seconds,v_start,v_end,'free',
    'monthly-free:'||v_local::date::text||':'||p_identity_hash);
end;
$$;
revoke all on function public._grant_monthly_free_quota_at(uuid,text,integer,timestamptz)
  from PUBLIC,anon,authenticated,service_role;

create function public.grant_monthly_free_quota(p_user_id uuid,p_identity_hash text,p_seconds integer)
returns public.quota_periods language sql security definer set search_path='' as $$
  select public._grant_monthly_free_quota_at(p_user_id,p_identity_hash,p_seconds,now());
$$;
revoke all on function public.grant_monthly_free_quota(uuid,text,integer) from PUBLIC,anon,authenticated;
grant execute on function public.grant_monthly_free_quota(uuid,text,integer) to service_role;

-- Eski servis RPC de yeni kurala uyar; interval artık bilerek yok sayılır.
create or replace function public.grant_free_quota_once(
  p_user_id uuid,p_identity_hash text,p_seconds integer,p_valid_for interval default interval '30 days'
) returns public.quota_periods language sql security definer set search_path='' as $$
  select public.grant_monthly_free_quota(p_user_id,p_identity_hash,p_seconds);
$$;
revoke all on function public.grant_free_quota_once(uuid,text,integer,interval) from PUBLIC,anon,authenticated;
grant execute on function public.grant_free_quota_once(uuid,text,integer,interval) to service_role;
