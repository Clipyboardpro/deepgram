# Katkı rehberi

Projede birden fazla kişi (ve AI asistanları) çalışıyor. Geçmişin okunabilir
kalması için aşağıdaki kurallara uyuyoruz.

## Commit mesajları

[Conventional Commits](https://www.conventionalcommits.org/tr/) biçimi,
açıklamalar Türkçe:

```
<tür>(<kapsam>): <kısa özet, emir kipinde, en fazla ~70 karakter>

<Neden bu değişiklik yapıldı, neyi çözüyor? Gerekirse ayrıntı.>
```

| Tür | Ne zaman |
|---|---|
| `feat` | Yeni özellik / yeni tablo / yeni uç nokta |
| `fix` | Hata düzeltme |
| `test` | Yalnızca test ekleme/düzeltme |
| `docs` | Yalnızca belge |
| `refactor` | Davranışı değiştirmeyen kod düzenleme |
| `chore` | Araç, yapılandırma, bağımlılık |

Kapsamlar: `db`, `api`, `functions`, `contracts`, `ios`, `docs`, `scripts`.

Örnekler:

```
feat(db): kota rezervasyon fonksiyonlarını ekle
fix(db): süresi dolan rezervasyonun kesinleşmesine izin ver
docs: kota kurallarını KARARLAR.md'ye yaz
```

Kurallar:

- Bir commit tek bir mantıksal değişiklik içerir. "Çeşitli düzeltmeler" yok.
- Özet satırı *ne* yaptığını, gövde *neden* yaptığını anlatır.
- Testler geçmeden `main`'e commit atılmaz.
- Gizli anahtar (API key, service role key, `.env`) asla commitlenmez.

## Dallar

- `main` her zaman çalışır durumdadır.
- Her iş kendi dalında yapılır (`feat/kota`, `fix/webhook-tekrar` gibi) ve
  pull request ile birleştirilir.

## Veritabanı değişiklikleri

- Şema yalnızca `backend/supabase/migrations/` altındaki yeni dosyalarla
  değişir. **Uygulanmış bir migration dosyası sonradan düzenlenmez**; düzeltme
  için yeni migration yazılır.
- Dosya adı: `YYYYMMDDHHMMSS_kisa_aciklama.sql`.
- Her yeni tablo için RLS açılır ve politikası aynı PR'da yazılır.
- Davranış değiştiren her SQL değişikliği için `backend/supabase/tests/database/`
  altında pgTAP testi eklenir.
