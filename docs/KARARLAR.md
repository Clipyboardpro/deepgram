# Kararlar

Mimariden ([`mimari.md`](mimari.md)) sonra alınan kararlar ve henüz onay
bekleyen öneriler. Karar değişirse satır silinmez; yeni satırla güncellenir.

## Alınan kararlar

| # | Tarih | Karar |
|---|---|---|
| K1 | 2026-10-07 | Önce backend (Supabase) yazılıyor; iOS uygulaması sonra. Hedef platform önce iOS, macOS daha sonra. |
| K2 | 2026-10-07 | Repo tek parça: `backend/supabase`, `contracts/`, `ios/`, `docs/`, `scripts/`. |
| K3 | 2026-10-07 | Kota **tamsayı saniye** olarak tutulur. Rezervasyon, kesinleştirme, bırakma ve süre dolumu Postgres fonksiyonlarıyla, kullanıcı başına kilitle atomik yapılır. `usage_ledger` yalnız ekleme alır (güncelleme ve doğrudan silme engelli). |
| K4 | 2026-10-07 | Bir rezervasyon tek bir kota döneminden düşer: aktif dönemler içinden yeterli bakiyesi olan, en erken biteni seçilir. Birden çok döneme bölünmüş rezervasyon ilk sürümde yok. |
| K5 | 2026-10-07 | Süresi dolup `expired` olan bir rezervasyon yine de kesinleştirilebilir: sağlayıcı maliyeti oluştuysa kullanım kaydedilir. Kesinleştirilen süre rezerve edilen süreyi aşamaz. |
| K6 | 2026-10-07 | Durum alanları Postgres `enum` yerine `text + check` ile tutulur; yeni durum eklemek tek satırlık migration olur. |
| K7 | 2026-10-07 | Tüm yazma işlemleri sunucu tarafında (`service_role`) yapılır. İstemci yalnız kendi satırlarını okuyabilir (RLS). |

## Onay bekleyen öneriler

Mimariye yapılan iyileştirme önerileri. Onaylananlar yukarıya taşınır.

| # | Öneri | Durum |
|---|---|---|
| Ö1 | Satın alma ↔ kullanıcı bağı için StoreKit 2 `appAccountToken` | bekliyor |
| Ö2 | Birincil giriş Sign in with Apple; uygulama içi hesap silme + Apple token iptali | bekliyor |
| Ö3 | Webhook güvenliği: her işe tahmin edilemez geri dönüş anahtarı | bekliyor |
| Ö4 | Testler için sunucu tarafında `FakeProvider` | bekliyor |
| Ö5 | Dağıtım için Supabase Queues (pgmq) + `pg_cron` | bekliyor |
| Ö6 | Deepgram'a kısa ömürlü imzalı okuma URL'si (ses Edge Function'dan geçmez) | bekliyor |
| Ö7 | Cihaz sesi: mono, 16 kHz, düşük bit hızlı AAC | bekliyor |
| Ö8 | Kota için tek SQL fonksiyon seti + eşzamanlılık testi | **uygulandı → K3** |
| Ö9 | `contracts/` altında OpenAPI + Transcript JSON şeması | bekliyor |
| Ö10 | Tek `api` Edge Function (Hono yönlendiricisi) | bekliyor |
| Ö11 | ElevenLabs Scribe'ı Türkçe karşılaştırmaya ekleme | bekliyor |
| Ö12 | Ortamlar: yerel `supabase start`, staging, prod; tek repo düzeni | **repo düzeni uygulandı → K2**, ortamlar bekliyor |

## Açık sorular

- İlk ücretsiz AI kotası kaç saniye, kimlere, ne zaman verilir? (`grant_quota`
  fonksiyonu hazır; otomatik verme henüz yok.)
- Çözümleme sonucu (Transcript) kullanıcı alana kadar nerede tutulacak?
  (`jobs` tablosunda değil; ayrı tablo veya özel bucket — Ö9 ile birlikte karar.)
