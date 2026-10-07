-- Çekirdek tablolar: kullanıcı profili, haklar, satın alma olayları, kota,
-- AI işleri ve sağlayıcı olayları.
--
-- Kurallar (bkz. docs/KARARLAR.md):
--   * Süreler tamsayı saniye, para birimleri tamsayı mikro-USD.
--   * Durum alanları text + check (enum değil).
--   * İstemci hiçbir tabloya doğrudan yazmaz; yazmalar sunucu fonksiyonlarıyla.
--   * Ses, altyazı metni veya imzalı URL olay tablolarına yazılmaz.

-- ---------------------------------------------------------------------------
-- Ortak yardımcılar
-- ---------------------------------------------------------------------------

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Servis ayarları (tek satır): AI açma/kapama anahtarı, limitler, bütçe
-- ---------------------------------------------------------------------------

create table public.service_settings (
  id                          boolean primary key default true check (id),
  ai_jobs_enabled             boolean not null default true,
  max_audio_seconds           integer not null default 300 check (max_audio_seconds > 0),
  max_audio_bytes             bigint  not null default 15 * 1024 * 1024 check (max_audio_bytes > 0),
  jobs_per_user_per_hour      integer not null default 20 check (jobs_per_user_per_hour > 0),
  reservation_ttl             interval not null default interval '2 hours',
  upload_ttl                  interval not null default interval '30 minutes',
  result_ttl                  interval not null default interval '7 days',
  daily_budget_usd_micros     bigint  not null default 5000000 check (daily_budget_usd_micros >= 0),
  updated_at                  timestamptz not null default now()
);

comment on table public.service_settings is
  'Tek satırlık sunucu ayarları. ai_jobs_enabled=false yeni AI işlerini durdurur; gönderilmiş işler sürer.';

insert into public.service_settings (id) values (true);

create trigger service_settings_updated_at
  before update on public.service_settings
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Sağlayıcı fiyat tablosu (sürümlü; fiyatlar kodda sabit tutulmaz)
-- ---------------------------------------------------------------------------

create table public.provider_prices (
  id                     bigint generated always as identity primary key,
  provider               text not null,
  model                  text not null,
  price_version          text not null,
  usd_micros_per_minute  bigint not null check (usd_micros_per_minute >= 0),
  valid_from             timestamptz not null default now(),
  unique (provider, model, price_version)
);

comment on table public.provider_prices is
  'Tahmini maliyet için sağlayıcı fiyatları. Gerçek faturayla düzenli uzlaştırılır.';

-- ---------------------------------------------------------------------------
-- Profiller
-- ---------------------------------------------------------------------------

create table public.profiles (
  id                 uuid primary key references auth.users (id) on delete cascade,
  -- StoreKit 2 satın alımlarına eklenen kimlik. Sunucu, App Store
  -- bildirimindeki appAccountToken ile kullanıcıyı bu alandan bulur.
  app_account_token  uuid not null unique default gen_random_uuid(),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create trigger profiles_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- Yeni auth kullanıcısı için profil oluştur.
create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id) values (new.id)
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();

-- ---------------------------------------------------------------------------
-- Ücretsiz kota talepleri: hesap silinip açılınca sıfırlanmasın diye
-- kullanıcıya değil, kimlik sağlayıcısındaki sabit kimliğin özetine bağlı.
-- ---------------------------------------------------------------------------

create table public.free_quota_claims (
  identity_hash  text primary key check (identity_hash ~ '^[0-9a-f]{64}$'),
  claimed_at     timestamptz not null default now()
);

comment on table public.free_quota_claims is
  'Ücretsiz kota bir kimliğe bir kez verilir. Kişisel veri değil, sha256 özeti tutulur. Hesap silinince bilerek silinmez.';

-- ---------------------------------------------------------------------------
-- Haklar ve satın alma olayları
-- ---------------------------------------------------------------------------

create table public.entitlements (
  id                       uuid primary key default gen_random_uuid(),
  user_id                  uuid not null references public.profiles (id) on delete cascade,
  kind                     text not null check (kind in ('pro')),
  product_id               text not null,
  original_transaction_id  text not null,
  starts_at                timestamptz not null,
  expires_at               timestamptz,
  revoked_at               timestamptz,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),
  unique (original_transaction_id, kind)
);

create index entitlements_user_idx on public.entitlements (user_id);

create trigger entitlements_updated_at
  before update on public.entitlements
  for each row execute function public.set_updated_at();

create table public.purchase_events (
  id                       uuid primary key default gen_random_uuid(),
  -- App Store Server Notifications V2 notificationUUID: tekrar gelen
  -- bildirimi ayırt eder.
  notification_uuid        uuid not null unique,
  notification_type        text not null,
  subtype                  text,
  environment              text not null check (environment in ('Sandbox', 'Production', 'Xcode', 'LocalTesting')),
  app_account_token        uuid,
  user_id                  uuid references public.profiles (id) on delete set null,
  product_id               text,
  original_transaction_id  text,
  transaction_id           text,
  signed_date              timestamptz,
  processed_at             timestamptz,
  process_error            text,
  received_at              timestamptz not null default now()
);

create index purchase_events_original_tx_idx on public.purchase_events (original_transaction_id);

-- ---------------------------------------------------------------------------
-- Kota
-- ---------------------------------------------------------------------------

create table public.quota_periods (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references public.profiles (id) on delete cascade,
  source           text not null check (source in ('free', 'subscription', 'topup', 'manual')),
  -- Kaynağa özgü idempotency anahtarı (ör. App Store transaction id).
  source_ref       text,
  granted_seconds  integer not null check (granted_seconds >= 0),
  starts_at        timestamptz not null,
  ends_at          timestamptz not null,
  created_at       timestamptz not null default now(),
  check (ends_at > starts_at),
  unique (source, source_ref)
);

create index quota_periods_user_idx on public.quota_periods (user_id, ends_at);

-- ---------------------------------------------------------------------------
-- AI işleri
-- ---------------------------------------------------------------------------

create table public.jobs (
  id                         uuid primary key default gen_random_uuid(),
  user_id                    uuid not null references public.profiles (id) on delete cascade,
  kind                       text not null default 'transcription' check (kind in ('transcription')),
  -- İstemcinin ürettiği istek kimliği: aynı istek tekrar gelirse aynı iş döner.
  client_request_id          text not null check (length(client_request_id) between 8 and 128),
  status                     text not null default 'awaiting_upload' check (status in (
                               'awaiting_upload', 'queued', 'submitted', 'processing',
                               'succeeded', 'failed', 'canceled', 'unknown_provider_state')),
  language                   text not null check (language ~ '^[a-z]{2}(-[A-Z]{2})?$'),
  audio_sha256               text not null check (audio_sha256 ~ '^[0-9a-f]{64}$'),
  audio_bytes                bigint not null check (audio_bytes > 0),
  claimed_duration_seconds   integer not null check (claimed_duration_seconds > 0),
  verified_duration_seconds  integer check (verified_duration_seconds >= 0),
  storage_path               text not null,
  provider                   text not null,
  model                      text not null,
  provider_request_id        text,
  -- Webhook doğrulaması: düz anahtar yalnız sağlayıcıya verilen geri dönüş
  -- adresinde bulunur; burada sha256 özeti saklanır.
  callback_token_hash        text check (callback_token_hash ~ '^[0-9a-f]{64}$'),
  submission_started_at      timestamptz,
  attempt_count              integer not null default 0 check (attempt_count >= 0),
  error_code                 text,
  price_version              text,
  estimated_cost_usd_micros  bigint not null default 0 check (estimated_cost_usd_micros >= 0),
  upload_expires_at          timestamptz not null,
  submitted_at               timestamptz,
  completed_at               timestamptz,
  created_at                 timestamptz not null default now(),
  updated_at                 timestamptz not null default now(),
  unique (user_id, client_request_id),
  unique (provider, provider_request_id)
);

create index jobs_user_created_idx on public.jobs (user_id, created_at desc);
create index jobs_status_idx on public.jobs (status) where status not in ('succeeded', 'failed', 'canceled');

create trigger jobs_updated_at
  before update on public.jobs
  for each row execute function public.set_updated_at();

-- Çözümleme sonucu, kullanıcı alana kadar burada durur (result_ttl sonra
-- silinir). Aynı kullanıcı aynı sesi aynı ayarlarla tekrar gönderirse önbellek
-- olarak kullanılır; kullanıcılar arası paylaşılmaz.
create table public.job_results (
  job_id       uuid primary key references public.jobs (id) on delete cascade,
  user_id      uuid not null references public.profiles (id) on delete cascade,
  transcript   jsonb not null,
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null
);

create index job_results_expires_idx on public.job_results (expires_at);

create table public.quota_reservations (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references public.profiles (id) on delete cascade,
  job_id            uuid not null unique references public.jobs (id) on delete cascade,
  period_id         uuid not null references public.quota_periods (id) on delete cascade,
  reserved_seconds  integer not null check (reserved_seconds > 0),
  status            text not null default 'active' check (status in ('active', 'committed', 'released', 'expired')),
  expires_at        timestamptz not null,
  settled_at        timestamptz,
  created_at        timestamptz not null default now()
);

create index quota_reservations_active_idx on public.quota_reservations (period_id) where status = 'active';
create index quota_reservations_expiry_idx on public.quota_reservations (expires_at) where status = 'active';

-- Yalnız ekleme alan kullanım defteri. seconds > 0 tüketim, < 0 iade/düzeltme.
create table public.usage_ledger (
  id               bigint generated always as identity primary key,
  user_id          uuid not null references public.profiles (id) on delete cascade,
  period_id        uuid not null references public.quota_periods (id) on delete cascade,
  -- İş silinse de defter kalır: bilerek yabancı anahtar yok.
  job_id           uuid,
  reservation_id   uuid,
  entry_type       text not null check (entry_type in ('usage', 'adjustment')),
  seconds          integer not null,
  idempotency_key  text not null unique,
  note             text,
  created_at       timestamptz not null default now()
);

create index usage_ledger_period_idx on public.usage_ledger (period_id);

create or replace function public.usage_ledger_append_only()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- Hesap silinince gelen zincirleme (cascade) silmeye izin ver; derinlik > 1
  -- olur. Doğrudan güncelleme ve silme yasak.
  if tg_op = 'DELETE' and pg_trigger_depth() > 1 then
    return old;
  end if;
  raise exception 'usage_ledger yalnız ekleme alır (% engellendi)', tg_op
    using errcode = '42501';
end;
$$;

create trigger usage_ledger_no_update
  before update or delete on public.usage_ledger
  for each row execute function public.usage_ledger_append_only();

-- ---------------------------------------------------------------------------
-- Sağlayıcı olayları (webhook ve durum sorguları). İçerik tutulmaz.
-- ---------------------------------------------------------------------------

create table public.provider_events (
  id                   uuid primary key default gen_random_uuid(),
  provider             text not null,
  -- Sağlayıcının olay kimliği veya (request_id + tür) gibi tekil anahtar.
  event_key            text not null,
  job_id               uuid references public.jobs (id) on delete set null,
  provider_request_id  text,
  kind                 text not null check (kind in ('webhook', 'poll', 'submit')),
  outcome              text,
  received_at          timestamptz not null default now(),
  unique (provider, event_key)
);

create index provider_events_job_idx on public.provider_events (job_id);
