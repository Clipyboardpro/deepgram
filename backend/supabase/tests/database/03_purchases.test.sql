-- Satın alma olayları: appAccountToken ile kullanıcı eşleşmesi, idempotency,
-- Pro hakkının güncellenmesi.
begin;
select plan(8);

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000000e1'),
  ('00000000-0000-0000-0000-0000000000e2');

select is(
  (select user_id from public.record_purchase_event(
    '11111111-1111-1111-1111-111111111111', 'SUBSCRIBED', 'INITIAL_BUY', 'Sandbox',
    (select app_account_token from public.profiles where id = '00000000-0000-0000-0000-0000000000e1'),
    'pro.monthly', 'otx-1', 'tx-1', now())),
  '00000000-0000-0000-0000-0000000000e1'::uuid,
  'appAccountToken satın alımı doğru kullanıcıya bağlıyor');

select is(
  (select is_new from public.record_purchase_event(
    '11111111-1111-1111-1111-111111111111', 'SUBSCRIBED', 'INITIAL_BUY', 'Sandbox',
    (select app_account_token from public.profiles where id = '00000000-0000-0000-0000-0000000000e1'),
    'pro.monthly', 'otx-1', 'tx-1', now())),
  false,
  'aynı bildirim ikinci kez yeni sayılmıyor');
select is(
  (select count(*)::int from public.purchase_events),
  1, 'aynı bildirim bir kez kaydediliyor');

select is(
  (select user_id from public.record_purchase_event(
    '22222222-2222-2222-2222-222222222222', 'SUBSCRIBED', 'INITIAL_BUY', 'Sandbox',
    gen_random_uuid(), 'pro.monthly', 'otx-9', 'tx-9', now())),
  null::uuid,
  'bilinmeyen appAccountToken kullanıcıya bağlanmıyor');

select is(
  (public.upsert_pro_entitlement('00000000-0000-0000-0000-0000000000e1', 'pro.monthly', 'otx-1',
    now(), now() + interval '1 month', null)).kind,
  'pro', 'Pro hakkı ekleniyor');
select is(
  (public.upsert_pro_entitlement('00000000-0000-0000-0000-0000000000e1', 'pro.monthly', 'otx-1',
    now(), now() + interval '1 month', now())).revoked_at is not null,
  true, 'iade aynı hakkı güncelliyor');
select is(
  (select count(*)::int from public.entitlements), 1, 'aynı işlem için ikinci hak açılmıyor');

select throws_ok(
  $$select public.upsert_pro_entitlement('00000000-0000-0000-0000-0000000000e2', 'pro.monthly', 'otx-1', now(), now() + interval '1 month', null)$$,
  '42501', 'transaction_belongs_to_another_user',
  'başka kullanıcının satın alımı devralınamıyor');

select * from finish();
rollback;
