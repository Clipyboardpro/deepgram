# Claude için oturum talimatları

## Her oturumun başında: İkinci Beyin (Google Drive)

1. Google Drive bağlantısıyla **Ikinci Beyin** klasöründeki
   `CLAUDE-CLOUD-START.md` dosyasını yeniden oku ve içindeki başlangıç sırasını
   uygula (klasör: https://drive.google.com/drive/folders/1DqGWEf6m8Ci9YSRdy1422cXTZYZ-A0aw).
2. Önce `CLAUDE-CLOUD-INDEX.md` ile kaynakların güncelliğini kontrol et; sonra
   `🔮 850-Companion/` altındaki Core.md, Kurallar.md, Last-Session.md,
   Threads.md ve Journal.md (son bölüm) dosyalarını başlangıç dosyasındaki
   sırayla oku.
3. Bilgisayardaki yerel yolları (`C:\Users\...`) kullanma; bulut için tek kaynak
   Drive aynasıdır.
4. Drive aracı bir dosyayı okuyamazsa bunu açıkça söyle; içeriği tahmin etme.
5. Drive aynası yerelden tek yönlü güncellenir; kullanıcı açıkça istemedikçe
   aynadaki dosyaları değiştirme.

## Sonra: proje devir belgeleri (Claude–Codex)

- Drive klasörü **"Video Editör · Proje"**
  (https://drive.google.com/drive/folders/1IIOF3hE3CAFANzLG3plXmO2jCb8FUsZ_).
- Önce `HANDOFF.md`'yi oku; durum koduna göre çalış (`CODEX_BEKLEMEDE` ise
  yerel değişikliği yapılmış varsayma). Diğerleri: PROJECT-BRIEF, ARCHITECTURE,
  DECISIONS, CODEX-TASKS, CLAUDE-NEXT, RESEARCH.
- Rol: Claude mimar/inceleyici/görev paketi yazar; Codex yerel repoda uygular;
  kararı Eymen verir. Codex'e model/düşünme seviyesi dayatma.
- Oturum sonunda HANDOFF veya CLAUDE-NEXT'i tarih ve güncelleyen tarafla güncel bırak.

## Proje

- Kullanıcıyla her zaman Türkçe konuş; her adım bitince kısa durum bildir.
- Commit kuralları ve katkı rehberi: `CONTRIBUTING.md`. Kararlar: `docs/KARARLAR.md`.
- Veritabanı testleri: `scripts/db-test.sh` (Docker gerekmez).
