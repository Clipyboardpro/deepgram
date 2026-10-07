-- Kota fonksiyonları.
--
-- Yaşam döngüsü:  reserve_quota  →  commit_quota   (iş başarılı)
--                                →  release_quota  (iş başarısız/iptal)
--                                →  expire_quota_reservations (süre doldu)
--
-- Aynı kullanıcı için tüm kota işlemleri bir transaction kilidiyle
-- (pg_advisory_xact_lock) sıraya girer; eşzamanlı iki istek aynı saniyeleri
-- iki kez ayıramaz. Fonksiyonlar idempotenttir: aynı iş için tekrar çağrı
-- yeni kayıt üretmez.

create or replace function public._lock_user_quota(p_user_id uuid)
returns void
language sql
set search_path = ''
as $$
  select pg_advisory_xact_lock(hashtextextended('quota:' || p_user_id::text, 0));
$$;

-- Kullanıcının şu an aktif kota dönemleri ve bakiyeleri.
create or replace function public.quota_balance(p_user_id uuid)
returns table (
  period_id          uuid,
  source             text,
  starts_at          timestamptz,
  ends_at            timestamptz,
  granted_seconds    integer,
  used_seconds       integer,
  reserved_seconds   integer,
  available_seconds  integer
)
language sql
stable
set search_path = ''
as $$
  select
    p.id,
    p.source,
    p.starts_at,
    p.ends_at,
    p.granted_seconds,
    coalesce(u.used, 0)::integer,
    coalesce(r.reserved, 0)::integer,
    greatest(p.granted_seconds - coalesce(u.used, 0) - coalesce(r.reserved, 0), 0)::integer
  from public.quota_periods p
  left join lateral (
    select sum(l.seconds) as used
    from public.usage_ledger l
    where l.period_id = p.id
  ) u on true
  left join lateral (
    select sum(q.reserved_seconds) as reserved
    from public.quota_reservations q
    where q.period_id = p.id and q.status = 'active'
  ) r on true
  where p.user_id = p_user_id
    and p.starts_at <= now()
    and p.ends_at > now()
  order by p.ends_at, p.id;
$$;

-- Kota dönemi ekler. (source, source_ref) ile idempotent.
create or replace function public.grant_quota(
  p_user_id     uuid,
  p_seconds     integer,
  p_starts_at   timestamptz,
  p_ends_at     timestamptz,
  p_source      text,
  p_source_ref  text
)
returns public.quota_periods
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_period public.quota_periods;
begin
  if p_source_ref is null then
    raise exception 'source_ref_required' using errcode = '22023';
  end if;

  insert into public.quota_periods (user_id, source, source_ref, granted_seconds, starts_at, ends_at)
  values (p_user_id, p_source, p_source_ref, p_seconds, p_starts_at, p_ends_at)
  on conflict (source, source_ref) do nothing
  returning * into v_period;

  if v_period.id is null then
    select * into v_period
    from public.quota_periods
    where source = p_source and source_ref = p_source_ref;

    if v_period.user_id <> p_user_id then
      raise exception 'source_ref_belongs_to_another_user' using errcode = '42501';
    end if;
  end if;

  return v_period;
end;
$$;

-- Ücretsiz kotayı bir kimliğe yalnız bir kez verir. p_identity_hash, kimlik
-- sağlayıcısındaki sabit kullanıcı kimliğinin (ör. Apple "sub") sha256 özeti.
-- Hesap silinip yeniden açılsa da ikinci kez verilmez. Verildiyse dönemi,
-- verilmediyse null döner.
create or replace function public.grant_free_quota_once(
  p_user_id        uuid,
  p_identity_hash  text,
  p_seconds        integer,
  p_valid_for      interval default interval '30 days'
)
returns public.quota_periods
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_claimed boolean;
begin
  insert into public.free_quota_claims (identity_hash)
  values (p_identity_hash)
  on conflict (identity_hash) do nothing
  returning true into v_claimed;

  if v_claimed is null then
    return null;
  end if;

  return public.grant_quota(
    p_user_id, p_seconds, now(), now() + p_valid_for, 'free', 'free:' || p_identity_hash
  );
end;
$$;

-- Bir iş için kota ayırır. Aynı iş için tekrar çağrılırsa mevcut rezervasyonu
-- döner. Yeterli bakiyesi olan, en erken biten aktif dönemden düşer.
create or replace function public.reserve_quota(
  p_user_id  uuid,
  p_job_id   uuid,
  p_seconds  integer,
  p_ttl      interval default null
)
returns public.quota_reservations
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reservation public.quota_reservations;
  v_period_id   uuid;
  v_ttl         interval;
begin
  if p_seconds is null or p_seconds <= 0 then
    raise exception 'invalid_seconds' using errcode = '22023';
  end if;

  perform public._lock_user_quota(p_user_id);

  select * into v_reservation
  from public.quota_reservations
  where job_id = p_job_id;

  if found then
    if v_reservation.user_id <> p_user_id then
      raise exception 'job_owner_mismatch' using errcode = '42501';
    end if;
    return v_reservation;
  end if;

  select b.period_id into v_period_id
  from public.quota_balance(p_user_id) b
  where b.available_seconds >= p_seconds
  order by b.ends_at, b.period_id
  limit 1;

  if v_period_id is null then
    raise exception 'insufficient_quota' using errcode = 'P0001';
  end if;

  select coalesce(p_ttl, s.reservation_ttl) into v_ttl
  from public.service_settings s;

  insert into public.quota_reservations (user_id, job_id, period_id, reserved_seconds, expires_at)
  values (p_user_id, p_job_id, v_period_id, p_seconds, now() + v_ttl)
  returning * into v_reservation;

  return v_reservation;
end;
$$;

-- Rezervasyonu kesinleştirir: gerçek süre kadar (rezerve edileni aşmadan)
-- kullanım yazar, kalan kendiliğinden serbest kalır. Tekrar çağrı ikinci kez
-- düşmez. Süresi dolmuş ('expired') rezervasyon da kesinleşebilir: sağlayıcı
-- maliyeti oluştuysa kullanım kaydedilmelidir.
create or replace function public.commit_quota(
  p_job_id          uuid,
  p_actual_seconds  integer
)
returns public.quota_reservations
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reservation public.quota_reservations;
  v_charged     integer;
begin
  select * into v_reservation
  from public.quota_reservations
  where job_id = p_job_id;

  if not found then
    raise exception 'reservation_not_found' using errcode = 'P0002';
  end if;

  perform public._lock_user_quota(v_reservation.user_id);

  -- Kilit alındıktan sonra güncel durumu yeniden oku.
  select * into v_reservation
  from public.quota_reservations
  where job_id = p_job_id;

  if v_reservation.status = 'committed' then
    return v_reservation;
  end if;

  if v_reservation.status = 'released' then
    raise exception 'reservation_released' using errcode = 'P0001';
  end if;

  v_charged := least(greatest(coalesce(p_actual_seconds, 0), 0), v_reservation.reserved_seconds);

  insert into public.usage_ledger (
    user_id, period_id, job_id, reservation_id, entry_type, seconds, idempotency_key
  ) values (
    v_reservation.user_id, v_reservation.period_id, v_reservation.job_id,
    v_reservation.id, 'usage', v_charged, 'commit:' || v_reservation.job_id
  );

  update public.quota_reservations
  set status = 'committed', settled_at = now()
  where id = v_reservation.id
  returning * into v_reservation;

  return v_reservation;
end;
$$;

-- Rezervasyonu bırakır (iş başarısız veya iptal). Aktif değilse dokunmaz.
create or replace function public.release_quota(p_job_id uuid)
returns public.quota_reservations
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reservation public.quota_reservations;
begin
  select * into v_reservation
  from public.quota_reservations
  where job_id = p_job_id;

  if not found then
    raise exception 'reservation_not_found' using errcode = 'P0002';
  end if;

  perform public._lock_user_quota(v_reservation.user_id);

  update public.quota_reservations
  set status = 'released', settled_at = now()
  where job_id = p_job_id and status in ('active', 'expired')
  returning * into v_reservation;

  if not found then
    select * into v_reservation
    from public.quota_reservations
    where job_id = p_job_id;
  end if;

  return v_reservation;
end;
$$;

-- Süresi dolan aktif rezervasyonları 'expired' yapar; bakiye serbest kalır.
-- Zamanlanmış temizlik çağırır. Etkilenen satır sayısını döner.
create or replace function public.expire_quota_reservations()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  update public.quota_reservations
  set status = 'expired', settled_at = now()
  where status = 'active' and expires_at <= now();

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- Giriş yapmış kullanıcının kendi bakiyesi (uygulama çağırır).
create or replace function public.my_quota()
returns table (
  period_id          uuid,
  source             text,
  starts_at          timestamptz,
  ends_at            timestamptz,
  granted_seconds    integer,
  used_seconds       integer,
  reserved_seconds   integer,
  available_seconds  integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  return query select * from public.quota_balance(auth.uid());
end;
$$;

-- ---------------------------------------------------------------------------
-- Yetkiler: kota değiştiren fonksiyonlar yalnız sunucu (service_role) içindir.
-- ---------------------------------------------------------------------------

revoke execute on function
  public._lock_user_quota(uuid),
  public.quota_balance(uuid),
  public.grant_quota(uuid, integer, timestamptz, timestamptz, text, text),
  public.grant_free_quota_once(uuid, text, integer, interval),
  public.reserve_quota(uuid, uuid, integer, interval),
  public.commit_quota(uuid, integer),
  public.release_quota(uuid),
  public.expire_quota_reservations(),
  public.my_quota()
from public, anon, authenticated;

grant execute on function
  public.quota_balance(uuid),
  public.grant_quota(uuid, integer, timestamptz, timestamptz, text, text),
  public.grant_free_quota_once(uuid, text, integer, interval),
  public.reserve_quota(uuid, uuid, integer, interval),
  public.commit_quota(uuid, integer),
  public.release_quota(uuid),
  public.expire_quota_reservations()
to service_role;

grant execute on function public.my_quota() to authenticated;
