-- Kota: ayırma, kesinleştirme, bırakma, süre dolumu, idempotency, ücretsiz
-- kotanın tek seferlik olması, defterin yalnız ekleme alması.
begin;
select plan(27);

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-0000000000b1');

insert into public.provider_prices (provider, model, price_version, usd_micros_per_minute, valid_from)
values ('fake', 'fake-1', 'v1', 6000, now() - interval '1 day');

-- İş kayıtları (rezervasyonun yabancı anahtarı için). Kota bu testte doğrudan
-- fonksiyonlarla yönetildiği için işleri tabloya elle ekliyoruz.
insert into public.jobs (id, user_id, client_request_id, language, audio_sha256, audio_bytes,
                         claimed_duration_seconds, storage_path, provider, model, upload_expires_at)
select ('00000000-0000-0000-0000-00000000010' || n)::uuid,
       '00000000-0000-0000-0000-0000000000a1', 'req-quota-' || n, 'tr', repeat('a', 64), 1000,
       60, 'x', 'fake', 'fake-1', now() + interval '1 hour'
from generate_series(1, 6) n;

-- --- Dönem yokken ---------------------------------------------------------

select throws_ok(
  $$select public.reserve_quota('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000101', 60)$$,
  'P0001', 'insufficient_quota',
  'kota dönemi yokken ayırma reddediliyor'
);

-- --- Dönem ve ayırma ------------------------------------------------------

select public.grant_quota('00000000-0000-0000-0000-0000000000a1', 300, now() - interval '1 minute', now() + interval '30 days', 'subscription', 'tx-1');

select is(
  (select count(*)::int from (select public.grant_quota('00000000-0000-0000-0000-0000000000a1', 300, now() - interval '1 minute', now() + interval '30 days', 'subscription', 'tx-1')) g),
  1, 'aynı source_ref ile tekrar verme hata vermiyor');
select is(
  (select count(*)::int from public.quota_periods where user_id = '00000000-0000-0000-0000-0000000000a1'),
  1, 'aynı source_ref ikinci dönem açmıyor');

select throws_ok(
  $$select public.grant_quota('00000000-0000-0000-0000-0000000000b1', 300, now(), now() + interval '1 day', 'subscription', 'tx-1')$$,
  '42501', 'source_ref_belongs_to_another_user',
  'başka kullanıcının işlem kimliğiyle kota alınamıyor'
);

select throws_ok(
  $$select public.reserve_quota('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000101', 0)$$,
  '22023', 'invalid_seconds',
  'sıfır saniyelik ayırma reddediliyor'
);

select public.reserve_quota('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000101', 120);

select is(
  (select available_seconds from public.quota_balance('00000000-0000-0000-0000-0000000000a1')),
  180, 'ayırma bakiyeden düşüyor (300 - 120)');

select public.reserve_quota('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000101', 120);
select is(
  (select available_seconds from public.quota_balance('00000000-0000-0000-0000-0000000000a1')),
  180, 'aynı iş için tekrar ayırma ikinci kez düşmüyor');

select throws_ok(
  $$select public.reserve_quota('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-000000000101', 10)$$,
  '42501', 'job_owner_mismatch',
  'başka kullanıcının işi için ayırma yapılamıyor'
);

select throws_ok(
  $$select public.reserve_quota('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000102', 181)$$,
  'P0001', 'insufficient_quota',
  'bakiyeyi aşan ayırma reddediliyor'
);

-- --- Kesinleştirme --------------------------------------------------------

select is(
  (public.commit_quota('00000000-0000-0000-0000-000000000101', 95)).status,
  'committed', 'kesinleştirme durumu committed yapıyor');

select is(
  (select used_seconds from public.quota_balance('00000000-0000-0000-0000-0000000000a1')),
  95, 'yalnız gerçek süre kadar kullanım yazılıyor');
select is(
  (select available_seconds from public.quota_balance('00000000-0000-0000-0000-0000000000a1')),
  205, 'kalan rezervasyon serbest kalıyor (300 - 95)');

select public.commit_quota('00000000-0000-0000-0000-000000000101', 95);
select is(
  (select count(*)::int from public.usage_ledger where job_id = '00000000-0000-0000-0000-000000000101'),
  1, 'tekrar kesinleştirme deftere ikinci satır yazmıyor');

select public.reserve_quota('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000102', 60);
select public.commit_quota('00000000-0000-0000-0000-000000000102', 500);
select is(
  (select seconds from public.usage_ledger where job_id = '00000000-0000-0000-0000-000000000102'),
  60, 'kesinleşen süre rezerve edileni aşamıyor');

-- --- Bırakma --------------------------------------------------------------

select public.reserve_quota('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000103', 50);
select is(
  (public.release_quota('00000000-0000-0000-0000-000000000103')).status,
  'released', 'bırakma durumu released yapıyor');
select is(
  (select available_seconds from public.quota_balance('00000000-0000-0000-0000-0000000000a1')),
  145, 'bırakılan rezervasyon bakiyeye dönüyor (300 - 95 - 60)');
select throws_ok(
  $$select public.commit_quota('00000000-0000-0000-0000-000000000103', 10)$$,
  'P0001', 'reservation_released',
  'bırakılmış rezervasyon kesinleştirilemiyor'
);
select is(
  (public.release_quota('00000000-0000-0000-0000-000000000101')).status,
  'committed', 'kesinleşmiş rezervasyonu bırakmak onu değiştirmiyor');

-- --- Süre dolumu ----------------------------------------------------------

select public.reserve_quota('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000104', 40, interval '-1 second');
select is(public.expire_quota_reservations(), 1, 'süresi dolan rezervasyon düşürülüyor');
select is(
  (select available_seconds from public.quota_balance('00000000-0000-0000-0000-0000000000a1')),
  145, 'süresi dolan rezervasyon bakiyeyi tutmuyor');
select is(
  (public.commit_quota('00000000-0000-0000-0000-000000000104', 30)).status,
  'committed', 'süresi dolmuş rezervasyon yine de kesinleşebiliyor (sağlayıcı maliyeti oluştu)');

-- --- Dönem seçimi ---------------------------------------------------------

select public.grant_quota('00000000-0000-0000-0000-0000000000a1', 100, now() - interval '1 minute', now() + interval '2 days', 'topup', 'topup-1');
select public.reserve_quota('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000105', 80);
select is(
  (select q.period_id from public.quota_reservations q where q.job_id = '00000000-0000-0000-0000-000000000105'),
  (select id from public.quota_periods where source_ref = 'topup-1'),
  'ayırma en erken biten, yeterli dönemden düşüyor');

-- --- Defter yalnız ekleme alır --------------------------------------------

select throws_ok(
  $$update public.usage_ledger set seconds = 0$$,
  '42501', null, 'defter satırı güncellenemiyor');
select throws_ok(
  $$delete from public.usage_ledger$$,
  '42501', null, 'defter satırı doğrudan silinemiyor');

-- --- Ücretsiz kota tek seferlik -------------------------------------------

select ok(
  (public.grant_free_quota_once('00000000-0000-0000-0000-0000000000b1', repeat('f', 64), 120)).id is not null,
  'ücretsiz kota ilk seferde veriliyor');

-- Hesap silinir (zincirleme silme defter satırlarını da kaldırabilmeli).
delete from auth.users where id = '00000000-0000-0000-0000-0000000000a1';
select is(
  (select count(*)::int from public.usage_ledger where user_id = '00000000-0000-0000-0000-0000000000a1'),
  0, 'hesap silinince kullanıcının defter satırları zincirleme siliniyor');

-- Aynı Apple kimliğiyle yeni hesap açılır.
insert into auth.users (id) values ('00000000-0000-0000-0000-0000000000c1');
select ok(
  (public.grant_free_quota_once('00000000-0000-0000-0000-0000000000c1', repeat('f', 64), 120)).id is null,
  'aynı kimlik yeni hesapta ücretsiz kotayı tekrar alamıyor');

select * from finish();
rollback;
