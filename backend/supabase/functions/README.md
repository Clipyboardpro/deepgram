# API (CX-002)

Sözleşme: `contracts/openapi.yaml`; transcript:
`contracts/transcript.schema.json`. Temel URL:
`http://127.0.0.1:54321/functions/v1/api`. Beş yolun hepsi Auth `getUser` ile
Bearer JWT doğrular. Gateway JWT kontrolü bunun için kapalıdır; bu, API'nin
kimlik kontrolünü kaldırmaz. `service_role` yalnız sunucudadır.

Yerel yığın: `supabase start --workdir backend`, ardından
`supabase db reset --workdir backend`. API:
`supabase functions serve api --workdir backend --env-file backend/supabase/functions/.env.example`.
`.env.example` yalnız fake sağlayıcı seçimidir; gerçek sağlayıcı veya ücret
bilgisi değildir. Bulutta `PUBLIC_SUPABASE_URL` proje URL'si olmalı; platform
Supabase anahtarlarını sağlar.

Kontrol:
`deno check --config backend/supabase/functions/deno.json backend/supabase/functions/api/index.ts`.
Test:
`deno test --allow-read --config backend/supabase/functions/deno.json backend/supabase/functions/tests/`.
Gerçek Auth/Storage/API smoke: çalışan yerel yığında `bash scripts/api-smoke.sh`
(Deno, ffmpeg, jq, curl gerekir). Script yalnız oluşturduğu test
kullanıcılarını, ses nesnelerini ve fake fiyat kaydını temizler. Üretimde
çalıştırmayın.

Önce create, sonra dönen `upload.url` adresine `upload.method` ve
`upload.headers` ile AAC/M4A PUT, ardından uploaded çağrısı yapılır. URL bir
sırdır; loglamayın. Sunucu dosyanın boyut/MIME bilgisini ve job upload süresini
doğrular. Storage imzası 2 saat geçerli olabilir; iş kabulü daha kısa
`expiresAt` ile sınırlıdır. Sesin gerçek hash/süresinin incelenmesi dispatcher
aşamasına aittir.

FakeProvider bağımsız ve ağsızdır. Bu aşamada dispatcher/webhook yoktur:
uploaded sonrası iş queued kalır, `result: null` döner. Transcript mevcut
olduğunda `result.transcript` altında döner. start/end yüklenen sesin sıfır
noktasından saniyedir; kaynak videoya kaydırmayı iOS yapar.
`display`/`confidence` opsiyoneldir, bilinmeyen transcript alanları kabul
edilir. Şema sürümü 1'dir.
