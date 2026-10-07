# API ve dispatcher (CX-002 / CX-003)

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

FakeProvider bağımsız ve ağsızdır. uploaded sonrası iş queued olur; CX-003
dispatcher etkin olduğunda asenkron olarak tamamlanır. Transcript mevcut
olduğunda `result.transcript` altında döner. start/end yüklenen sesin sıfır
noktasından saniyedir; kaynak videoya kaydırmayı iOS yapar.
`display`/`confidence` opsiyoneldir, bilinmeyen transcript alanları kabul
edilir. Şema sürümü 1'dir.

## CX-003 kurulumu ve güvenlik

`DISPATCHER_SECRET` en az 32 karakter rastgele sır olmalı ve Edge Function
secret'ı olarak kurulmalı. Yoksa iç dispatcher/callback yolları etkin değildir;
iOS API'si çalışmaya devam eder. Aynı sır Vault'ta `dispatcher_secret` adıyla,
tam tetikleme URL'si `dispatcher_url` adıyla tutulur. Sır migration, log veya
commit içine konmaz. Platform API URL'si HTTPS ve kök olmalı; yol önekli reverse
proxy URL'leri signed-upload URL yeniden yazımında desteklenmez (Claude bulgu
2).

Kurulum yalnız yetkili operatörün Dashboard/SQL Editor ve Supabase secrets
araçlarıyla yapılır. Vault kayıt adları:

```sql
select vault.create_secret('<proje-kök-URL>/functions/v1/api/v1/internal/dispatch', 'dispatcher_url');
select vault.create_secret('<Edge-Function-ile-aynı-rastgele-sır>', 'dispatcher_secret');
```

Migration `dispatch-transcriptions` görevini dakikada bir kurar. Vault kayıtları
yokken `tick_dispatcher()` güvenli no-op'tur. pg_net ham sır değil,
`dispatch:<epoch-saniye>` mesajı için SHA-256 HMAC hex imzasını taşır; API en
fazla 60 saniyelik zaman farkını kabul eder. Kullanıcı JWT'si dispatcher
çalıştıramaz. Kısa ömürlü imzanın tekrar kullanımı yalnız aynı idempotent
tüketimi tetikler.

5 mesaj/batch, 120 saniye görünmezlik. Akış: preflight → claim → submit →
mark_submitted → callback → ack. Cancel/terminal işler ack edilip atlanır.
Geçici DB/Storage/callback hatasında ack yoktur; kira bitince tekrar görünür.
Gönderim sonucu belirsizse kör submit tekrarı yoktur: DB
`unknown_provider_state` yapar. Operatör uzlaştırması gerekir. Fake iş submitted
ile callback arasındayken kesilirse yeni tokenla sonucu yeniden teslim eder;
provider.submit tekrarlanmaz. `fake/fake-v1` ve `deepgram/nova-3` kayıtlıdır;
canlı sağlayıcı değiştirmek ayrıca maliyet onayı gerektirir.

FakeProvider'ın ağsız sonucu aynı callback yönlendiricisinden işlem içi teslim
edilir; dış sağlayıcı callback HTTP ucu da aynıdır. Token yalnız URL'de geçici
olarak vardır; DB'de hash tutulur. Provider/requestId/token kontrolü ve durum
mutasyonu aynı row lock transaction'ında yapılır. Başarı/failure ve tekrarlar
tek kota işlemi üretir. Callback başarısı `result.transcript` olarak okunur.

Preflight: boyut/MIME, SHA-256, M4A tek AAC audio-track `stts` zamanı veya ADTS
AAC frame süresi. Video, parçalı MP4, bozuk/bilinmeyen kapsayıcı reddedilir.
Süre beyanını/service limitini en fazla 250 ms encoder payı aşabilir; boyut üst
sınırı `64000 × ölçülen_saniye + 65536` byte'dır. Kota ölçülen sürenin yukarı
yuvarlanmasıyla, ayrılan kota sınırında kesinleşir. Bu bir codec decoder
değildir; saldırganca hazırlanmış sample metadata'yı tam decode ederek kanıtlama
tam decode kanıtı henüz yoktur. Deepgram callback süresi preflight ile en fazla
250 ms farklı olabilir; daha büyük fark sonuç mutasyonu yapmadan reddedilir.

## CX-007/008 · aylık ücretsiz hak ve kesin ret

`POST /v1/quota/free-claim`: JWT zorunlu, boş gövde, yanıt `{granted:boolean}`.
Auth.getUser ile doğrulanan kullanıcının güncel Auth kaydı tekrar okunur.
Anonim veya doğrulanmamış e-posta (Apple kimliği yoksa) → 403
`free_quota_not_eligible`. User metadata/client kimlik veya miktarı kullanılmaz.
Apple identity_data.sub veya doğrulanmış küçük-harf e-posta, sunucu pepper'ıyla
HMAC-SHA256 olur. Ay başına kimlik ve kullanıcı benzersizliği atomik kontrol edilir;
aynı ay tekrar / e-posta değişikliği / aynı kimlikle başka hesap yeni hak vermez.
Hesap silinince ayın hash tombstone'u korunur. Pepper sabit tutulmalı; döndürme işlemi
eski kimlik hash'lerini uzlaştırmadan yapılmamalı.

`FREE_QUOTA_PEPPER` rastgele >=32 karakter, `FREE_QUOTA_SECONDS` pozitif integer;
başlangıç değeri 900 sn/ay (Eymen CX-008 kararı). Eksik/bozuk config → 503
`free_quota_not_configured`. `FREE_QUOTA_VALID_DAYS` kaldırıldı/yok sayılır.
DB saati Europe/Istanbul ay başı/sonraki ay başını hesaplar; devretmez, cron gerekmez.
GET /v1/quota ve ilk POST /v1/transcription-jobs rezervasyondan önce tembel hak verir.
Uygun olmayan kimliğin bu yollarda ücretsiz hakkı atlanır, mevcut diğer kota işler;
açık free-claim yine 403 verir. Auth/config/DB arızaları yutulmaz.
Yeni monthly_free_quota_claims tablosu RLS ile istemciye kapalıdır; ay/zaman parametreli
iç yardımcı service_role'a bile kapalıdır. API RPC'si zaman girdisi almaz.
Eski tek-sefer RPC yeni aylık kurala yönlenir (interval yok sayılır); eski hash kayıtları
verildikleri aya taşınır, eski free dönem bitişi ay sınırına kısaltılır. Geçmiş harcama
ve rezervasyon kayıtları değişmez. Canlı örnek pepper kullanılamaz.
Dağıtım Eymen tarafından onaylandı fakat yalnız CI yeşil + Claude PR merge sonrası yapılır.
Auth ayarları değişmez, sağlayıcı fake kalır; ücretli Deepgram yok.

Deepgram 4xx → ProviderRejected → `failed/provider_rejected` + rezervasyon
iadesi + ack (kör retry yok). Fail RPC geçici hatası üç kez yeniden denenir;
bütün DB yazmaları başarısızsa lease ack edilmez, operatör incelemesi gerekir.
Timeout/ağ/5xx/bozuk 2xx kabul `unknown_provider_state` kalır; bu belirsizlik
ücretli çağrıyı kör tekrarlamaz. Raw sağlayıcı yanıtı loglanmaz.

`scripts/report-auth.ps1` canlı ayarları salt okunur CLI diff ile allowlist
alanlarından raporlar; Auth secrets ve istemci anahtarını basmaz. Çıktıda
"no diff" alanları CLI'ın beyan edilmiş yerel ayarla aynı gördüğü alanlardır.
Auth ayarları değişmez. Native Apple id_token akışı için Apple Developer App ID,
bundle ID capability ve Supabase Client IDs gerekir. Web OAuth eklenirse
Services ID, Team ID/Key ID/.p8 ile client secret (6 aylık yenileme) gerekir.
[Supabase Apple akışları](https://supabase.com/docs/guides/auth/social-login/auth-apple).

## CX-004 · Deepgram adaptörü (ücretli test/aktivasyon kapalı)

`TRANSCRIPTION_PROVIDER=deepgram`, `TRANSCRIPTION_MODEL=nova-3` ve
`DEEPGRAM_API_KEY` yalnız açık maliyet onayı sonrası Edge secrets ile ayarlanır.
Şu an canlı konfigürasyon fake/fake-v1'dir; bu değişiklik dağıtılmadı.
Deepgram'a tek POST: EU `/v1/listen`, language=tr, punctuate=true,
smart_format=true, signed READ URL + callback. İstek/timeout otomatik yeniden
gönderilmez; belirsiz sonuç operatör uzlaştırmasına gider. Submitted işi ack
etmek sonuç oluşturmaz; gerçek callback beklenir. Callback token + requestId
kontrolü, native words → Transcript v1; display=punctuated_word. Kaynak video
ofseti eklenmez. Başarısız callback'in özel hata metni saklanmaz.

1 MiB callback sınırı korunur; tek kanal, 300 sn + 250 ms encoder payı / 10000 kelime.
2000 kelimelik sentetik 5 dk gövde testi bu sınıra sığar; gerçek Türkçe ölçümü
değildir. Fazla büyük callback 413, bozuk veri 400; kota kesinleştirilmez.
Gerçek WER/zamanlama/latans ve ücretli canlı iş yapılmadı: kullanıcı yalnız
adaptörü istedi. Eyyoverse örnekleri bu repo klasöründe bulunmadı.

2026-10-07 kaynak kontrolü: Nova-3 tr/tr-TR destekler. Pay-as-you-go
pre-recorded monolingual liste fiyatı $0.0043/dk (4300 USD micros/dk),
multilingual $0.0052/dk; language=tr tek dil seçilir. Hesap indirimleri veya
model improvement opt-out gibi fiyat etkileri ayrıca doğrulanmalıdır. Bu fiyat
canlı DB'ye eklenmedi; onay sonrası idempotent yönetim adımı gerekir.

[Deepgram model/diller](https://developers.deepgram.com/docs/models-languages-overview),
[Pre-recorded API](https://developers.deepgram.com/reference/speech-to-text/listen-pre-recorded),
[AB uç noktası](https://developers.deepgram.com/reference/regional-endpoints),
[Liste fiyatı](https://deepgram.com/pricing).

`bash scripts/api-smoke.sh` hem CX-002 hem CX-003'ü gerçek yerel yığında test
eder. Test rastgele geçici sır üretir, Vault/pg_net zincirini tetikler ve
kullandığı nesneleri temizler. Mevcut dispatcher Vault kayıtları varsa test
onları silmeden durur. Yalnız atılabilir yerel ortamda çalıştırın.

Kaynaklar:
[Supabase zamanlanmış fonksiyonlar](https://supabase.com/docs/guides/functions/schedule-functions),
[pg_net başlıklarındaki sır riski](https://supabase.com/docs/guides/troubleshooting/database-roles-can-read-request-headers-queued-by-pg_net-ad6357).
