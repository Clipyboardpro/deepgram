-- İş yaşam döngüsü: oluşturma, yükleme, kuyruk, gönderim, webhook doğrulama,
-- sonuç, hata, iptal, belirsiz sağlayıcı durumu, temizlik, limitler.
begin;
select plan(38);

insert into auth.users (id) values ('00000000-0000-0000-0000-0000000000d1');
insert into public.provider_prices (provider, model, price_version, usd_micros_per_minute, valid_from)
values ('fake', 'fake-1', 'v1', 6000, now() - interval '1 day');
select public.grant_quota('00000000-0000-0000-0000-0000000000d1', 600, now() - interval '1 minute', now() + interval '30 days', 'manual', 'jobs-test');

create temp table t (name text primary key, job_id uuid, token text);
grant all on t to public;

-- --- Oluşturma ------------------------------------------------------------

insert into t (name, job_id)
select 'main', (public.create_transcription_job(
  '00000000-0000-0000-0000-0000000000d1', 'req-main-0001', 'tr', repeat('a', 64), 2000000, 120, 'fake', 'fake-1')).id;

select is(
  (select status from public.jobs where id = (select job_id from t where name = 'main')),
  'awaiting_upload', 'yeni iş yükleme bekliyor');
select is(
  (select reserved_seconds from public.quota_reservations where job_id = (select job_id from t where name = 'main')),
  120, 'iş oluşturulunca kota ayrılıyor');
select is(
  (select estimated_cost_usd_micros from public.jobs where id = (select job_id from t where name = 'main')),
  12000::bigint, 'tahmini maliyet fiyat tablosundan hesaplanıyor (2 dk × 6000)');
select is(
  (select storage_path from public.jobs where id = (select job_id from t where name = 'main')),
  '00000000-0000-0000-0000-0000000000d1/' || (select job_id from t where name = 'main') || '.m4a',
  'depolama yolu kullanıcı/iş kimliğinden üretiliyor');

select is(
  (public.create_transcription_job('00000000-0000-0000-0000-0000000000d1', 'req-main-0001', 'tr', repeat('a', 64), 2000000, 120, 'fake', 'fake-1')).id,
  (select job_id from t where name = 'main'),
  'aynı istek kimliği aynı işi döndürüyor');
select is(
  (select count(*)::int from public.quota_reservations where user_id = '00000000-0000-0000-0000-0000000000d1'),
  1, 'tekrarlanan istek ikinci rezervasyon açmıyor');

select throws_ok(
  $$select public.create_transcription_job('00000000-0000-0000-0000-0000000000d1', 'req-main-0001', 'tr', repeat('b', 64), 2000000, 120, 'fake', 'fake-1')$$,
  'P0001', 'client_request_id_reused', 'aynı istek kimliği farklı sesle kullanılamıyor');
select throws_ok(
  $$select public.create_transcription_job('00000000-0000-0000-0000-0000000000d1', 'req-long-0001', 'tr', repeat('c', 64), 2000000, 301, 'fake', 'fake-1')$$,
  'P0001', 'audio_too_long', '5 dakikadan uzun ses reddediliyor');
select throws_ok(
  $$select public.create_transcription_job('00000000-0000-0000-0000-0000000000d1', 'req-big-0001', 'tr', repeat('c', 64), 999999999, 60, 'fake', 'fake-1')$$,
  'P0001', 'audio_too_large', 'boyut sınırını aşan ses reddediliyor');
select throws_ok(
  $$select public.create_transcription_job('00000000-0000-0000-0000-0000000000d1', 'req-price-001', 'tr', repeat('c', 64), 1000, 60, 'fake', 'yok-model')$$,
  'P0001', 'price_not_configured', 'fiyatı tanımsız modelle iş açılamıyor');
select throws_ok(
  $$select public.create_transcription_job('00000000-0000-0000-0000-0000000000d1', 'req-quota-001', 'tr', repeat('c', 64), 1000, 300, 'fake', 'fake-1')
    from (select public.create_transcription_job('00000000-0000-0000-0000-0000000000d1', 'req-quota-000', 'tr', repeat('c', 64), 1000, 300, 'fake', 'fake-1')) x$$,
  'P0001', 'insufficient_quota', 'kota yetmezse iş açılmıyor');
select is(
  (select count(*)::int from public.jobs where client_request_id in ('req-quota-000', 'req-quota-001')),
  0, 'kota hatasında iş kaydı da geri alınıyor');

update public.service_settings set ai_jobs_enabled = false;
select throws_ok(
  $$select public.create_transcription_job('00000000-0000-0000-0000-0000000000d1', 'req-off-00001', 'tr', repeat('c', 64), 1000, 10, 'fake', 'fake-1')$$,
  'P0001', 'ai_jobs_disabled', 'AI anahtarı kapalıyken yeni iş açılmıyor');
update public.service_settings set ai_jobs_enabled = true;

update public.service_settings set daily_budget_usd_micros = 12500;
select throws_ok(
  $$select public.create_transcription_job('00000000-0000-0000-0000-0000000000d1', 'req-budget-01', 'tr', repeat('c', 64), 1000, 10, 'fake', 'fake-1')$$,
  'P0001', 'daily_budget_exceeded', 'günlük bütçe aşılınca yeni iş açılmıyor');
update public.service_settings set daily_budget_usd_micros = 5000000;

-- --- Yükleme ve kuyruk ----------------------------------------------------

select is(
  (public.mark_job_uploaded('00000000-0000-0000-0000-0000000000d1', (select job_id from t where name = 'main'))).status,
  'queued', 'yükleme bitince iş kuyruğa giriyor');
select public.mark_job_uploaded('00000000-0000-0000-0000-0000000000d1', (select job_id from t where name = 'main'));
select is(
  (select count(*)::int from pgmq.q_transcription_dispatch),
  1, 'tekrar yükleme bildirimi kuyruğa ikinci mesaj koymuyor');
select throws_ok(
  format($$select public.mark_job_uploaded('00000000-0000-0000-0000-0000000000ff', %L)$$, (select job_id from t where name = 'main')),
  'P0002', 'job_not_found', 'başka kullanıcı işi hazır bildiremiyor');

select is(
  (select job_id from public.dequeue_dispatch(60, 5)),
  (select job_id from t where name = 'main'),
  'dispatcher kuyruktan işi alıyor');
select is(
  (select count(*)::int from public.dequeue_dispatch(60, 5)),
  0, 'alınan mesaj görünmezlik süresince başka dispatcher''a görünmüyor');

-- --- Gönderim -------------------------------------------------------------

update t set token = (select callback_token from public.claim_job_for_submission((select job_id from t where name = 'main')))
where name = 'main';

select ok((select token from t where name = 'main') ~ '^[0-9a-f]{64}$', 'gönderim için 64 haneli geri dönüş anahtarı üretiliyor');
select ok(
  public.verify_job_callback((select job_id from t where name = 'main'), (select token from t where name = 'main')),
  'doğru anahtar webhook''u doğruluyor');
select ok(
  not public.verify_job_callback((select job_id from t where name = 'main'), repeat('0', 64)),
  'yanlış anahtar reddediliyor');
select ok(
  not public.verify_job_callback(gen_random_uuid(), (select token from t where name = 'main')),
  'başka işin kimliğiyle anahtar geçmiyor');

select is(
  (public.mark_job_submitted((select job_id from t where name = 'main'), 'prov-req-1')).status,
  'submitted', 'sağlayıcı istek kimliği kaydedilince iş submitted');
select is(
  (public.mark_job_submitted((select job_id from t where name = 'main'), 'prov-req-1')).provider_request_id,
  'prov-req-1', 'aynı istek kimliğiyle tekrar kayıt idempotent');

select throws_ok(
  format($$select public.cancel_job('00000000-0000-0000-0000-0000000000d1', %L)$$, (select job_id from t where name = 'main')),
  'P0001', 'job_not_cancelable', 'sağlayıcıya gönderilmiş iş iptal edilemiyor');

-- --- Sonuç ----------------------------------------------------------------

select is(
  (public.complete_job((select job_id from t where name = 'main'), 100, '{"words": []}'::jsonb, 'evt-1')).status,
  'succeeded', 'sonuç gelince iş başarılı');
select is(
  (select transcript from public.job_results where job_id = (select job_id from t where name = 'main')),
  '{"words": []}'::jsonb, 'sonuç saklanıyor');
select is(
  (select used_seconds from public.quota_balance('00000000-0000-0000-0000-0000000000d1')),
  100, 'doğrulanmış süre kadar kota kesinleşiyor');

select public.complete_job((select job_id from t where name = 'main'), 100, '{"words": []}'::jsonb, 'evt-1');
select is(
  (select count(*)::int from public.usage_ledger where job_id = (select job_id from t where name = 'main')),
  1, 'aynı webhook tekrar gelince kota tekrar düşmüyor');
select is(
  (select count(*)::int from public.provider_events where event_key = 'evt-1'),
  1, 'tekrar gelen olay bir kez kaydediliyor');

-- --- Belirsiz gönderim ----------------------------------------------------

insert into t (name, job_id)
select 'lost', (public.create_transcription_job(
  '00000000-0000-0000-0000-0000000000d1', 'req-lost-0001', 'tr', repeat('d', 64), 1000, 30, 'fake', 'fake-1')).id;
select public.mark_job_uploaded('00000000-0000-0000-0000-0000000000d1', (select job_id from t where name = 'lost'));
select public.claim_job_for_submission((select job_id from t where name = 'lost'));
-- Dispatcher gönderim sırasında çöktü; sağlayıcı kimliği hiç kaydedilmedi.
select is(
  (select count(*)::int from public.claim_job_for_submission((select job_id from t where name = 'lost'))),
  0, 'sonucu belirsiz gönderim tekrar gönderilmiyor');
select is(
  (select status from public.jobs where id = (select job_id from t where name = 'lost')),
  'unknown_provider_state', 'belirsiz gönderim unknown_provider_state olarak işaretleniyor');

-- --- Hata -----------------------------------------------------------------

select is(
  (public.fail_job((select job_id from t where name = 'lost'), 'provider_error', 'evt-fail-1')).status,
  'failed', 'hata bildirimi işi failed yapıyor');
select is(
  (select status from public.quota_reservations where job_id = (select job_id from t where name = 'lost')),
  'released', 'başarısız işin kotası bırakılıyor');

-- --- İptal ----------------------------------------------------------------

insert into t (name, job_id)
select 'cancel', (public.create_transcription_job(
  '00000000-0000-0000-0000-0000000000d1', 'req-cancel-001', 'tr', repeat('e', 64), 1000, 30, 'fake', 'fake-1')).id;
select is(
  (public.cancel_job('00000000-0000-0000-0000-0000000000d1', (select job_id from t where name = 'cancel'))).status,
  'canceled', 'yükleme bekleyen iş iptal edilebiliyor');
select is(
  (select status from public.quota_reservations where job_id = (select job_id from t where name = 'cancel')),
  'released', 'iptal edilen işin kotası bırakılıyor');

-- --- Temizlik -------------------------------------------------------------

insert into t (name, job_id)
select 'stale', (public.create_transcription_job(
  '00000000-0000-0000-0000-0000000000d1', 'req-stale-0001', 'tr', repeat('f', 64), 1000, 30, 'fake', 'fake-1')).id;
update public.jobs set upload_expires_at = now() - interval '1 second' where id = (select job_id from t where name = 'stale');
update public.job_results set expires_at = now() - interval '1 second';

select is(
  public.cleanup_expired_work(),
  '{"canceled_uploads": 1, "expired_reservations": 0, "deleted_results": 1}'::jsonb,
  'temizlik süresi dolan yüklemeyi iptal edip eski sonucu siliyor');

select * from finish();
rollback;
