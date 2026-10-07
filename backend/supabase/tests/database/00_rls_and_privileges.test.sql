-- RLS ve yetkiler: istemci yalnız kendi satırlarını okur, hiçbir şey yazamaz,
-- sunucu fonksiyonlarını çağıramaz.
begin;
select plan(17);

-- Hazırlık (postgres olarak)
insert into auth.users (id) values
  ('00000000-0000-0000-0000-00000000000a'),
  ('00000000-0000-0000-0000-00000000000b');

insert into public.provider_prices (provider, model, price_version, usd_micros_per_minute, valid_from)
values ('fake', 'fake-1', 'v1', 6000, now() - interval '1 day');

select public.grant_quota('00000000-0000-0000-0000-00000000000a', 600, now() - interval '1 minute', now() + interval '30 days', 'manual', 'test-a');
select public.grant_quota('00000000-0000-0000-0000-00000000000b', 600, now() - interval '1 minute', now() + interval '30 days', 'manual', 'test-b');

select public.create_transcription_job('00000000-0000-0000-0000-00000000000a', 'req-a-0001', 'tr', repeat('a', 64), 1000, 60, 'fake', 'fake-1');
select public.create_transcription_job('00000000-0000-0000-0000-00000000000b', 'req-b-0001', 'tr', repeat('b', 64), 1000, 60, 'fake', 'fake-1');

select is(
  (select count(*)::int from pg_tables t
   where t.schemaname = 'public' and not t.rowsecurity),
  0,
  'public şemasındaki her tabloda RLS açık'
);

select ok(
  exists (select 1 from public.profiles where id = '00000000-0000-0000-0000-00000000000a'),
  'auth kullanıcısı oluşunca profil otomatik açılıyor'
);

-- Kullanıcı A olarak
set local role authenticated;
set local request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';

select is((select count(*)::int from public.profiles), 1, 'A yalnız kendi profilini görüyor');
select is((select count(*)::int from public.jobs), 1, 'A yalnız kendi işini görüyor');
select is(
  (select client_request_id from public.jobs),
  'req-a-0001',
  'A''nın gördüğü iş kendi işi'
);
select is((select count(*)::int from public.quota_reservations), 1, 'A yalnız kendi rezervasyonunu görüyor');
select is((select count(*)::int from public.quota_periods), 1, 'A yalnız kendi kota dönemini görüyor');
select is((select count(*)::int from public.purchase_events), 0, 'satın alma olayları istemciye kapalı');
select is((select count(*)::int from public.service_settings), 0, 'servis ayarları istemciye kapalı');

select throws_ok(
  $$select callback_token_hash from public.jobs$$,
  '42501', null,
  'istemci webhook anahtar özetini okuyamıyor'
);

select throws_ok(
  $$insert into public.quota_periods (user_id, source, source_ref, granted_seconds, starts_at, ends_at)
    values ('00000000-0000-0000-0000-00000000000a', 'manual', 'hile', 99999, now(), now() + interval '1 day')$$,
  '42501', null,
  'istemci kendine kota yazamıyor'
);

select throws_ok(
  $$update public.jobs set status = 'succeeded'$$,
  '42501', null,
  'istemci iş durumunu değiştiremiyor'
);

select throws_ok(
  $$select public.reserve_quota('00000000-0000-0000-0000-00000000000a', gen_random_uuid(), 10)$$,
  '42501', null,
  'istemci reserve_quota çağıramıyor'
);

select throws_ok(
  $$select public.create_transcription_job('00000000-0000-0000-0000-00000000000a', 'req-a-0002', 'tr', repeat('c', 64), 1000, 60, 'fake', 'fake-1')$$,
  '42501', null,
  'istemci iş oluşturma fonksiyonunu doğrudan çağıramıyor'
);

select is(
  (select available_seconds from public.my_quota()),
  540,
  'my_quota kendi bakiyesini döndürüyor (600 - 60 rezerve)'
);

-- Anonim
reset role;
set local role anon;
set local request.jwt.claim.sub = '';

select throws_ok(
  $$select * from public.jobs$$,
  '42501', null,
  'anonim kullanıcı işleri okuyamıyor'
);
select throws_ok(
  $$select * from public.my_quota()$$,
  '42501', null,
  'anonim kullanıcı my_quota çağıramıyor'
);

reset role;
select * from finish();
rollback;
