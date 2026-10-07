# iOS Video Editörü — Uygulanabilir Mimari

Tarih: 4 Ekim 2026 · Durum: önerilen tasarım, henüz uygulanmadı veya cihazda doğrulanmadı.

## 1. Amaç ve temel karar

Konuşmalı videoyu hızlıca düzenleyip altyazılı sosyal medya videosuna dönüştüren bir iOS uygulaması. Zamanla çok kanallı zaman çizelgesi, geçişler, filtreler, marka şablonları ve bulut özellikleri eklenebilir.

İlk hedef: iOS; tek geliştirici; video işlemenin ağırlığı cihazda. İlk sürümde 1080p SDR ve kısa videolar. Minimum iOS sürümü ve en uzun video süresi, fiziksel eski cihaz testlerinden sonra kesinleştirilecek. İlk ürün sınırı önerisi: 5 dakika; doğrulanmış performans sınırı değildir.

Uygulama özelliklere göre bölünmüş tek uygulama olarak başlar. Ayrı mikroservisler, GPU sunucusu, hazır ücretli editör SDK'sı veya kapsamlı bağımlılık çatısı ilk aşamada gerekli değildir. Kritik servisler arayüzlerle ayrılır; ihtiyaç oluşunca ayrı Swift paketlerine çıkarılabilir.

## 2. Teknoloji seçimi

| Katman | Tercih | Gerekçe |
|---|---|---|
| Arayüz | SwiftUI; zaman çizelgesinde gerekirse dar UIKit köprüsü | iOS'a uygun deneyim; sürükleme performansını ölçerek karar verme |
| Video/ses | AVFoundation | İçe alma, kompozisyon, oynatma, ses çıkarma, dışa aktarma |
| Görüntü efektleri | Core Image; ihtiyaç halinde Metal | Basit efektlerle başlama, ağır özel işlemeyi sonradan ekleme |
| Proje saklama | Sürüm numaralı JSON + uygulama içi medya klasörü | Projeyi taşınabilir ve göç edilebilir tutma |
| Proje listesi | Yerel hafif indeks; gerekirse SwiftData | Asıl projenin tek kaynağı manifest; indeks yeniden kurulabilir |
| Satın alma | StoreKit 2 | Mevcut deneyimden yararlanma; ayrı abonelik hizmeti zorunlu değil |
| Sunucu | Supabase Auth, Postgres, Edge Functions | Kimlik, haklar, kota, iş kayıtları ve sağlayıcıya erişim |
| Kalıcı iş kuyruğu | Postgres iş tablosu + zamanlanmış dispatcher | Telefon veya bir HTTP isteği kapanınca iş kaybolmaz |
| İlk konuşma sağlayıcısı | Deepgram adaptörü | Türkçe doğruluk ve kelime zamanlama karşılaştırması sonrası onay |
| Cihaz içi alternatif | WhisperKit adaptörü, sonraki aşama | Model boyutu ve eski cihaz hızı test edilmeden varsayılan yapılmaz |
| Geçici ses depolama | Supabase Storage özel bucket | İlk aşamada ikinci depolama servisi eklememe |
| Hata takibi | Crashlytics + içerik içermeyen olaylar | Başarısız işlem ve çökme takibi |

Deepgram'da Türkçe için açık dil seçimi yapılır; çok dilli otomatik modun Türkçeyi kapsadığı varsayılmaz. Sağlayıcı seçimi sabit kodlanmaz. API anahtarı uygulamada bulunmaz.

## 3. Modüller ve sorumluluklar

| Modül | Sorumluluk | Çıkış/veri |
|---|---|---|
| AppShell | Açılış, gezinme, bağımlılıkların kurulması | Ekranlar ve oturum |
| ProjectLibrary | Proje oluşturma, açma, çoğaltma, silme | ProjectDocument |
| MediaImport | Photos/Files içe alma, medya doğrulama, yerel kopya | MediaAsset |
| EditorDomain | Track, Clip, Caption, Transform; düzenleme kuralları | Değişmez proje anlık görüntüsü |
| EditorUI | Zaman çizelgesi, araçlar, önizleme kontrolleri | Düzenleme komutları |
| MediaEngine | Oynatma, kompozisyon, proxy, efekt, dışa aktarma | RenderPlan, ExportResult |
| Captions | Kelime zamanları, altyazı gruplama, düzeltme, stil | Transcript, CaptionTrack |
| AIJobs | Ses çıkarma, yükleme, iş durumu, sonuç uyarlama | JobResult |
| Entitlements | Satın alma/geri yükleme, Pro erişimi | Yerel erişim + sunucu hakları |
| Templates | Sürüm numaralı stil ve marka tanımları | TemplateDefinition |
| Telemetry | Süre, hata kodu, kullanım ve maliyet olayları | İçeriksiz ölçümler |

EditorDomain, SwiftUI, Supabase ve Deepgram'a bağımlı olmaz. Ekranlar doğrudan sağlayıcı API'sini çağırmaz. Arayüz durumu ana iş parçacığında; ağır medya işleri ayrı yürütülür. İş akışları iptal edilebilir tasarlanır.

Temel arayüzler: ProjectRepository, MediaImporter, CompositionBuilder, ExportService, TranscriptionProvider, AIJobClient, EntitlementService. Başlangıçta yalnız kullanılan arayüzler yazılır; her sınıf için gereksiz soyutlama oluşturulmaz.

## 4. Proje ve düzenleme modeli

Önerilen proje paketi: Documents/Projects/{projectId}/ altında project.json, Media/ ve Captions/. Yeniden üretilebilir küçük resim ve proxy dosyaları Caches/ altında tutulur; proje yeniden açılırken eksik cache yeniden oluşturulur. İçe alınan kaynak, kullanıcı açıkça silene kadar proje içinde kalır. Geçici Photos/Files adreslerine kalıcı bağımlılık kurulmaz.

ProjectDocument alanları: schemaVersion, projectId, revision, canvas(width/height/fps/colorPolicy), mediaAssets, tracks, captionTracks, templateVersion, createdAt, updatedAt.

Clip alanları: clipId, mediaId, sourceIn, sourceOut, timelineStart, playbackRate, transform, volume, effects. Zamanlar Float saniye yerine CMTime'ın value/timescale temsiliyle saklanır. Transcript kelimeleri kaynak medya zamanına bağlı tutulur. Örneğin kaynakta 10–20 saniyelik parça kullanılır ve 2x hızla oynatılırsa altyazılar yeni zaman çizelgesine aynı dönüşümle taşınır. Bir dosyanın farklı parçaları kullanıldığında konuşma çözümleme tekrarlanmaz.

Kelime düzeltmesi, zamanları sessizce değiştirmez. Satır düzeyinde çeviride hedef kelimelerin kaynak kelimelerle bire bir zamanlanabileceği varsayılmaz; önce cümle düzeyinde altyazı sunulur. Kaynak metin ve kullanıcı düzeltmeleri ayrı tutulur; yeniden gelen AI sonucu kullanıcı düzenlemesini ezmez.

Düzenleme tahribatsızdır: kesme ve filtreleme kaynak videoyu değiştirmez. Undo/redo düzenleme komutlarından üretilir. Otomatik kayıt kısa gecikmeyle ve atomik dosya değiştirmeyle yapılır; proje şema göçleri eski örnek dosyalarla test edilir.

## 5. Önizleme ve dışa aktarma

ProjectDocument → doğrulama → RenderPlan → önizleme veya dışa aktarma.

RenderPlan ortak yerleşim, yazı ölçümü, dönüşüm, efekt ve zamanlama kurallarını içerir. Önizleme ve çıktı aynı kuralları kullanır. SwiftUI üst katmanında gösterilen altyazı doğrudan video çıktısı sayılmaz; metin gerçek video görüntüsüne işlenmelidir.

Basit ilk sürümde AVFoundation kompozisyonları ve metin/görüntü katmanları; kelime vurgusu, filtre ve karmaşık geçişlerde ayrı video compositor yolu değerlendirilir. Nihai render yöntemi küçük bir prototiple doğrulanır. Ses miksajı ayrı; kırpma, ses düzeyi ve zamanlama birlikte test edilir.

Önizlemede küçük resim/proxy üretilebilir; dışa aktarmada orijinaller kullanılır. iPhone yön bilgisi, değişken kare hızı, HEVC ve HDR girişler ele alınır. İlk sürüm çıktısı 1080p SDR olarak tanımlanır; HDR girişi için kontrollü renk dönüşümü veya açık destek sınırı gerekir.

ExportJob: queued → preparing → exporting → completed; ayrıca failed/canceled. Çıktı önce geçici dosyaya, başarıdan sonra kalıcı hedefe taşınır. Proje düzenlemesi sırasında dışa aktarma sabit revision üzerinde çalışır. Yeterli disk alanı, uygulamanın arka plana geçmesi, termal baskı ve bellek sorunları yönetilir. iOS'ta sınırsız arka plan render garantisi verilmez; yarıda kalan iş tekrar başlatılabilir olmalı. AVAssetExportSession'ın her efekt ve kodeki desteklediği varsayılmaz; gerçek cihaz uyumluluğu denetlenir.

## 6. AI iş akışı ve kota

1. Kullanıcı otomatik altyazıyı seçer; uygulama gönderilecek ses ve dil bilgisini açıklar.
2. Cihaz sadece gereken sesi çıkarır; süre ve dosya boyutu sınırları uygulanır.
3. POST /v1/transcription-jobs, istemci işlem kimliği ve medya özetiyle çağrılır.
4. Sunucu kimlik/hak kontrolünden sonra kotayı veritabanı işlemiyle atomik ayırır; aynı istek aynı iş kimliğini döndürür.
5. Sunucu özel bucket için kısa ömürlü yükleme izni üretir. İstemci dosyayı yükler, işi hazır olarak bildirir.
6. Dispatcher işi sahiplenir; güvenilir süre/format doğrulaması yapar, sağlayıcıya asenkron işlem verir. Gerekirse küçük worker kullanılır; uzun iş yalnız Edge Function waitUntil belleğine bırakılmaz.
7. Sağlayıcı sonucu webhook veya durum sorgulamasıyla alınır, doğrulanır ve uygulamanın Transcript biçimine çevrilir.
8. Kullanıcı GET /v1/jobs/{id} ile sonucu alır; uygulama kaynak kelime zamanlarını projeye ekler.
9. Kota kesinleştirilir; rezerve kalan tutar bırakılır. Geçici ses süresi dolunca silinir.

Sunucu tabloları: profiles, entitlements, jobs, quota_periods, quota_reservations, usage_ledger, purchase_events, provider_events. Tüm kullanıcı verisinde sahiplik kontrolü/RLS; yönetici anahtarları yalnız sunucuda.

Job durumları: awaiting_upload, queued, submitted, processing, succeeded, failed, canceled, unknown_provider_state. Provider maliyeti ve kullanıcıdan düşülen kota ayrı kayıtlar. İptal veya başarısız sonuç sağlayıcı faturasının sıfırlandığı anlamına gelmez.

İş sahiplenme için lease ve benzersiz işlem kimliği kullanılır. Aynı webhook tekrar gelse kota yeniden düşmez. Sağlayıcı isteği gönderilmişken bağlantı koparsa körlemesine yeniden gönderilmez; mümkünse providerRequestId ile uzlaştırılır. Sağlayıcı idempotency/durum kontrolü sunmuyorsa belirsiz işi otomatik yeniden üretmek yerine kayıt ve kontrollü kurtarma gerekir. Süresi dolan rezervasyonlar, yüklemeler ve sahipsiz işler düzenli temizlenir.

İstemciden gelen dakika bilgisi tek başına güvenilir sayılmaz. Tek seferlik ücretsiz kota, anonim hesabı silip açarak kolayca sıfırlanmamalı; hassas veri toplamadan hesap ve işlem oranı sınırları uygulanır. AI kullanımında hesap gerekir; normal yerel düzenleme hesapsız kullanılabilir.

## 7. Satın alma ve maliyet kontrolü

StoreKit 2, yerel Pro arayüz erişimini yönetir. Sunucu, doğrulanmış App Store işlemleri ve Server Notifications V2 ile AI dakika/kredi haklarını yönetir. İstemcinin isPro değeri AI hakkı oluşturmaz. Yenileme, iptal, iade, faturalama sorunu, yükseltme ve geri yükleme idempotent işlenir. Kota dönemi sunucuda açık tanımlanır; yıllık abonelikte aylık dakika yenilemesi ayrı kuraldır.

Önerilen ürün ayrımı: temel yerel editör ücretsiz; gelişmiş şablon/araçlar Pro; Pro'da sınırlı aylık AI dakika; ek dakika tüketilebilir IAP. Sonraki AI video üretimi ayrı kredi ürünü. Kesin fiyat ve kota kullanıcı başına maliyet ölçüldükten sonra belirlenir.

Maliyet formülü: çözümleme dakikası × sağlayıcı birim fiyatı + isteğe bağlı üretim maliyeti + sunucu + depolama/işlem + içerik lisansları. Mağaza kesintileri ve pazarlama ayrı. Provider fiyatları kodda sabit kalmaz; sürümlü fiyat tablosuyla tahmini maliyet kaydedilir ve gerçek faturayla uzlaştırılır. Harcama uyarıları, günlük AI bütçesi ve yeni pahalı işleri durdurabilen sunucu anahtarı bulunur. Önceden gönderilen işler maliyet oluşturmaya devam edebilir.

Çözümleme sonucu aynı kullanıcı içinde ses özeti, dil, model ve ayarlara göre cache edilir. Kullanıcılar arası içerik cache'i kurulmaz. Kullanıcı düzenlediğinde cache'e kaynak AI sonucu yazılır; özel düzeltmeleri başka projelere otomatik uygulanmaz.

## 8. Saklama ve gizlilik

Varsayılan: orijinal video ve proje cihazda. AI için yalnız ses aktarılır. Geçici bucket özel; kısa süreli imzalı URL; sonuç alındıktan sonra silme, güvenlik ağı olarak en geç 24 saatlik otomatik yaşam döngüsü önerilir. Sağlayıcının kendi veri saklama politikası ayrıca doğrulanır; kendi bucket silinince sağlayıcı kopyasının da silindiği iddia edilmez.

Sunucu kayıtlarında ses, altyazı ve imzalı URL tutulmaz. Hata kodu, süre, model sürümü, maliyet ve anonim iş kimliği yeterli. Hesap silme sunucu verileri ve işlerin temizlenmesini tetikler. Kullanıcının cihazındaki projeleri silme tercihi ayrı açıklanır. Bulut yedekleme sonradan açık tercih ile eklenir; ilk sürümde zorunlu değildir.

## 9. Geliştirme sırası ve kabul ölçütleri

| Aşama | Teslim | Geçiş ölçütü |
|---|---|---|
| 0 — Risk prototipi | İçe alma, yön düzeltme, metinli 1080p çıktı | Gerçek eski ve yeni iPhone'da çıktı doğru; süre/bellek ölçüldü |
| 1 — Yerel çekirdek | Proje, kesme/birleştirme, kaydet/aç, undo/redo | Uygulama yeniden açıldığında medya ve düzenleme korunuyor |
| 2 — Altyazı | Manuel metin, zamanlama, 3–5 stil, AI adaptörü | Türkçe örneklerde doğruluk ve zamanlama karşılaştırıldı |
| 3 — Ticari sürüm | StoreKit, sunucu hakları, kota, temizleme | Tekrarlanan işlem çift kota düşmüyor; satın alma/geri yükleme çalışıyor |
| 4 — Kapsamlı editör | Ses kanalı, geçiş, hız, filtre, marka şablonu | Önizleme/çıktı uyumu; uzun proje performansı |
| 5 — Bulut | Açık tercihli yedekleme ve eşitleme | Revision çatışması ve silme/geri yükleme davranışı tanımlandı |
| 6 — Pahalı AI | Çeviri, dublaj, video üretimi | Ayrı kredi; sağlayıcı başına bütçe ve yeniden deneme politikası |

Önemli testler: hız değişince altyazı zamanları; iki farklı kesitte aynı kaynak; önizleme ve çıktıdaki yazı konumu; yinelenen webhook ve satın alma; eşzamanlı kota; belirsiz provider timeout; disk dolması; bozuk medya; Photos erişim değişimi; proje şema göçü. Bütün kombinasyonlarda test yazmak yerine bu kayıp/maliyet üreten durumlara öncelik verilir.

## 10. Sonraki genişleme sınırları

Bulut render yalnız cihazların yetersiz kaldığı ölçülünce eklenir; API, ayrı worker/GPU kuyruğuna iş verir. Edge Functions video render motoru olarak kullanılmaz. Bulut eşitlemede proje revision ve değişmez medya kimlikleriyle çatışma yönetimi gerekir. Android'e geçişte domain JSON biçimi paylaşılır; iOS medya motoru doğrudan taşınabilir sayılmaz.

İlk uygulama öncesi açık kararlar: ürün adı, minimum iOS sürümü, hedef eski cihaz, ücretsiz kota, Pro fiyatı, dil kapsamı ve ticari müzik/şablon kataloğu. Bunlar mimariyi kurmaya engel değildir; yayın öncesinde netleşir.

## Resmî kaynaklar

- Apple AVFoundation: https://developer.apple.com/av-foundation/
- AVAssetExportSession: https://developer.apple.com/documentation/avfoundation/avassetexportsession
- App Store Server Notifications: https://developer.apple.com/documentation/appstoreservernotifications
- Supabase arka plan işleri ve süre sınırları: https://supabase.com/docs/guides/functions/background-tasks
- Deepgram kayıt çözümleme: https://developers.deepgram.com/docs/pre-recorded-audio
- Deepgram model/dil desteği: https://developers.deepgram.com/docs/models-languages-overview
- WhisperKit: https://github.com/argmaxinc/argmax-oss-swift

Bu belge tasarımdır; çalışan kod, doğrulanmış performans veya mağaza onayı değildir.
