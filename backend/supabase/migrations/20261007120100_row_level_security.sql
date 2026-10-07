-- Satır düzeyi güvenlik (RLS).
--
-- İstemci (anon / authenticated) yalnız kendi satırlarını OKUYABİLİR. Hiçbir
-- tabloda istemciye yazma politikası yok: tüm yazmalar service_role ile çalışan
-- Edge Function'lar veya security definer fonksiyonlar üzerinden yapılır.
-- RLS açık olup politikası olmayan tablolara istemci hiç erişemez.

alter table public.service_settings   enable row level security;
alter table public.provider_prices    enable row level security;
alter table public.profiles           enable row level security;
alter table public.free_quota_claims  enable row level security;
alter table public.entitlements       enable row level security;
alter table public.purchase_events    enable row level security;
alter table public.quota_periods      enable row level security;
alter table public.jobs               enable row level security;
alter table public.job_results        enable row level security;
alter table public.quota_reservations enable row level security;
alter table public.usage_ledger       enable row level security;
alter table public.provider_events    enable row level security;

create policy "profiles: kendi profilini oku"
  on public.profiles for select to authenticated
  using (id = (select auth.uid()));

create policy "entitlements: kendi haklarını oku"
  on public.entitlements for select to authenticated
  using (user_id = (select auth.uid()));

create policy "quota_periods: kendi kota dönemlerini oku"
  on public.quota_periods for select to authenticated
  using (user_id = (select auth.uid()));

create policy "jobs: kendi işlerini oku"
  on public.jobs for select to authenticated
  using (user_id = (select auth.uid()));

create policy "job_results: kendi sonuçlarını oku"
  on public.job_results for select to authenticated
  using (user_id = (select auth.uid()));

create policy "quota_reservations: kendi rezervasyonlarını oku"
  on public.quota_reservations for select to authenticated
  using (user_id = (select auth.uid()));

create policy "usage_ledger: kendi kullanımını oku"
  on public.usage_ledger for select to authenticated
  using (user_id = (select auth.uid()));

-- İstemci webhook anahtar özetini (callback_token_hash) göremez. Tablo
-- düzeyindeki yetki sütun iptalini etkisiz bıraktığı için tablo yetkisi
-- kaldırılıp sütunlar tek tek veriliyor. jobs'a yeni sütun eklenirse buraya da
-- eklenmeli.
revoke all on public.jobs from anon, authenticated;
grant select (
  id, user_id, kind, client_request_id, status, language, audio_sha256,
  audio_bytes, claimed_duration_seconds, verified_duration_seconds,
  storage_path, provider, model, provider_request_id, submission_started_at,
  attempt_count, error_code, price_version, estimated_cost_usd_micros,
  upload_expires_at, submitted_at, completed_at, created_at, updated_at
) on public.jobs to authenticated;
