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
| K8 | 2026-10-07 | Ö1–Ö12 mimari iyileştirmelerinin tamamı onaylandı. Uygulanmamış maddeler ilgili geliştirme görevlerinde tamamlanacak. |

## Mimari iyileştirmelerinin durumu

Mimariye yapılan iyileştirmelerin karar ve uygulama durumu.

| # | Öneri | Durum |
|---|---|---|
| Ö1 | Satın alma ↔ kullanıcı bağı için StoreKit 2 `appAccountToken` | **onaylandı → K8; DB alanı uygulandı** |
| Ö2 | Birincil giriş Sign in with Apple; uygulama içi hesap silme + Apple token iptali | **onaylandı → K8** |
| Ö3 | Webhook güvenliği: her işe tahmin edilemez geri dönüş anahtarı | **onaylandı → K8; DB akışı uygulandı** |
| Ö4 | Testler için sunucu tarafında `FakeProvider` | **onaylandı → K8** |
| Ö5 | Dağıtım için Supabase Queues (pgmq) + `pg_cron` | **onaylandı → K8; DB katmanı uygulandı** |
| Ö6 | Deepgram'a kısa ömürlü imzalı okuma URL'si (ses Edge Function'dan geçmez) | **onaylandı → K8** |
| Ö7 | Cihaz sesi: mono, 16 kHz, düşük bit hızlı AAC | **onaylandı → K8** |
| Ö8 | Kota için tek SQL fonksiyon seti + eşzamanlılık testi | **onaylandı ve uygulandı → K3, K8** |
| Ö9 | `contracts/` altında OpenAPI + Transcript JSON şeması | **onaylandı → K8** |
| Ö10 | Tek `api` Edge Function (Hono yönlendiricisi) | **onaylandı → K8** |
| Ö11 | ElevenLabs Scribe'ı Türkçe karşılaştırmaya ekleme | **onaylandı → K8** |
| Ö12 | Ortamlar: yerel `supabase start`, staging, prod; tek repo düzeni | **onaylandı → K2, K8; yerel ortam ve repo düzeni uygulandı** |

## Açık sorular

- İlk ücretsiz AI kotası kaç saniye, kimlere, ne zaman verilir? (`grant_quota`
  fonksiyonu hazır; otomatik verme henüz yok.)
- Çözümleme sonucu (Transcript) kullanıcı alana kadar nerede tutulacak?
  (`jobs` tablosunda değil; ayrı tablo veya özel bucket — Ö9 ile birlikte karar.)
