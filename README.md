# Video Editör

Konuşmalı videoları hızlıca kesip Türkçe otomatik altyazılı sosyal medya
videosuna çeviren iOS uygulaması ve onun sunucu tarafı.

- Video işleme cihazda (AVFoundation), sunucu yalnızca kimlik, AI kotası,
  iş kuyruğu ve konuşma tanıma sağlayıcısına (Deepgram) erişimi yönetir.
- Mimari: [`docs/mimari.md`](docs/mimari.md)
- Alınan ve bekleyen kararlar: [`docs/KARARLAR.md`](docs/KARARLAR.md)
- Nasıl katkı verilir, commit kuralları: [`CONTRIBUTING.md`](CONTRIBUTING.md)

## Klasörler

| Klasör | İçerik |
|---|---|
| `backend/supabase/` | Supabase projesi: `migrations/` (SQL şema), `tests/database/` (pgTAP testleri), ileride `functions/` (Edge Functions) |
| `contracts/` | Uygulama ile sunucu arasındaki sözleşmeler (OpenAPI, Transcript JSON şeması) — henüz boş |
| `ios/` | Swift uygulaması — henüz boş |
| `docs/` | Mimari ve karar kayıtları |
| `scripts/` | Geliştirme ve test betikleri |

## Veritabanı testleri

İki yol var:

1. **Supabase CLI + Docker** (Mac/Windows'ta önerilen):
   ```sh
   cd backend
   supabase start
   supabase test db
   ```
2. **Docker olmadan, düz PostgreSQL 16 + pgTAP ile** (CI ve bulut oturumları):
   ```sh
   scripts/db-test.sh
   ```
   Betik geçici bir Postgres kümesi açar, Supabase'in `auth` şemasını taklit
   eden küçük bir katmanı (`scripts/sql/supabase_shim.sql`) yükler, tüm
   migration'ları uygular, pgTAP testlerini ve eşzamanlı kota testini koşar.
