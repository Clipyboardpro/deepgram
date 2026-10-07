import Foundation

/// Sunucudan gelen çözümleme sonucu (sözleşme: Drive IS-BOLUMU §3,
/// `contracts/transcript.schema.json`). Zamanlar yüklenen ses dosyasının
/// başına göre saniyedir.
public struct Transcript: Equatable, Sendable, Codable {
    public static let supportedSchemaVersion = 1

    public var schemaVersion: Int
    public var provider: String
    public var model: String
    public var language: String
    public var durationSeconds: Double
    public var words: [Word]

    public struct Word: Equatable, Sendable, Codable {
        public var text: String
        public var display: String?
        public var start: Double
        public var end: Double
        public var confidence: Double?

        public init(text: String, display: String? = nil, start: Double, end: Double, confidence: Double? = nil) {
            self.text = text
            self.display = display
            self.start = start
            self.end = end
            self.confidence = confidence
        }
    }

    public enum DecodingError: Error, Equatable {
        case unsupportedSchemaVersion(Int)
    }

    /// JSON'dan çözer; bilinmeyen alanlar yok sayılır, daha yeni şema reddedilir.
    public static func decode(from data: Data) throws -> Transcript {
        let transcript = try JSONDecoder().decode(Transcript.self, from: data)
        guard transcript.schemaVersion <= supportedSchemaVersion else {
            throw DecodingError.unsupportedSchemaVersion(transcript.schemaVersion)
        }
        return transcript
    }
}

/// Bir medyaya bağlı altyazı kanalı. Kelimeler **kaynak medya zamanında**
/// tutulur; böylece klip kesilse, hızlansa ya da aynı kaynağın iki farklı
/// kesiti kullanılsa da çözümleme tekrarlanmaz.
///
/// AI'dan gelen metin (`words`) ile kullanıcı düzeltmeleri (`corrections`)
/// ayrı tutulur. Kelime düzeltmesi zamanları değiştirmez.
public struct CaptionTrack: Equatable, Sendable, Codable {
    public var captionTrackId: UUID
    public var mediaId: UUID
    public var language: String
    public var words: [SourceWord]
    /// Kelime kimliği → kullanıcının yazdığı metin.
    public var corrections: [String: String]
    public var styleId: String

    public init(captionTrackId: UUID = UUID(), mediaId: UUID, language: String, words: [SourceWord] = [], corrections: [String: String] = [:], styleId: String = "default") {
        self.captionTrackId = captionTrackId
        self.mediaId = mediaId
        self.language = language
        self.words = words
        self.corrections = corrections
        self.styleId = styleId
    }

    /// Kaynak zamanına bağlı kelime. Kimlik, kaynak başlangıç anından (ms)
    /// türetilir: aynı ses yeniden çözümlenince aynı yerdeki kelime aynı
    /// kimliği alır ve kullanıcı düzeltmesi korunur.
    public struct SourceWord: Equatable, Sendable, Codable {
        public var id: String
        public var text: String
        public var display: String
        public var sourceStart: MediaTime
        public var sourceEnd: MediaTime
        public var confidence: Double?

        public init(id: String, text: String, display: String, sourceStart: MediaTime, sourceEnd: MediaTime, confidence: Double? = nil) {
            self.id = id
            self.text = text
            self.display = display
            self.sourceStart = sourceStart
            self.sourceEnd = sourceEnd
            self.confidence = confidence
        }

        public var range: TimeRange { TimeRange(start: sourceStart, end: sourceEnd) }
    }

    /// Transcript'i kaynak zamanına çevirerek yeni bir kanal üretir.
    /// - Parameter audioSourceStart: Sunucuya gönderilen sesin kaynak medyada
    ///   başladığı an (ses medyanın tamamıysa sıfır).
    public static func make(from transcript: Transcript, mediaId: UUID, audioSourceStart: MediaTime = .zero) -> CaptionTrack {
        CaptionTrack(
            mediaId: mediaId,
            language: transcript.language,
            words: sourceWords(from: transcript, audioSourceStart: audioSourceStart)
        )
    }

    /// Yeni AI sonucunu uygular: kelimeler yenilenir, kimliği eşleşen
    /// kelimelerdeki kullanıcı düzeltmeleri korunur. Eşleşmeyen düzeltmeler
    /// döner (kullanıcıya gösterilebilir), sessizce kaybolmaz.
    @discardableResult
    public mutating func applyAIResult(_ transcript: Transcript, audioSourceStart: MediaTime = .zero) -> [String: String] {
        let newWords = Self.sourceWords(from: transcript, audioSourceStart: audioSourceStart)
        let newIds = Set(newWords.map(\.id))
        var kept: [String: String] = [:]
        var orphaned: [String: String] = [:]
        for (id, text) in corrections {
            if newIds.contains(id) { kept[id] = text } else { orphaned[id] = text }
        }
        words = newWords
        corrections = kept
        language = transcript.language
        return orphaned
    }

    /// Kullanıcının göreceği metin: varsa düzeltme, yoksa AI'nin görünen biçimi.
    public func displayText(for word: SourceWord) -> String {
        corrections[word.id] ?? word.display
    }

    static func sourceWords(from transcript: Transcript, audioSourceStart: MediaTime) -> [SourceWord] {
        let ts = MediaTime.defaultTimescale
        let words = transcript.words
            .filter { $0.end > $0.start }
            .map { w in
                let start = audioSourceStart + MediaTime(seconds: w.start, timescale: ts)
                let end = audioSourceStart + MediaTime(seconds: w.end, timescale: ts)
                return SourceWord(
                    id: "w\(Int64((start.seconds * 1000).rounded()))",
                    text: w.text,
                    display: w.display ?? w.text,
                    sourceStart: start,
                    sourceEnd: end,
                    confidence: w.confidence
                )
            }
            .sorted { $0.sourceStart < $1.sourceStart }

        // Aynı milisaniyede başlayan kelimeler sıra ekiyle ayrışır.
        var seen: [String: Int] = [:]
        return words.map { word in
            var word = word
            let count = seen[word.id, default: 0]
            seen[word.id] = count + 1
            if count > 0 { word.id += "-\(count + 1)" }
            return word
        }
    }
}
