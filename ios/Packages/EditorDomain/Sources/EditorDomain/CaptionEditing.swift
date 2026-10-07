import Foundation

/// Altyazı listesindeki bir satır: düzenleme ekranı satırı bütün olarak
/// gösterir, kullanıcı metni yeniden yazar; değişiklik kelime düzeltmelerine
/// çevrilir. Zamanlar AI'dan gelir ve değişmez.
public struct EditableCaptionLine: Equatable, Sendable, Identifiable {
    public struct Word: Equatable, Sendable {
        public var wordId: String
        /// Şu an görünen metin (düzeltme varsa o; gizliyse boş).
        public var text: String
        /// AI'nın verdiği metin.
        public var original: String
        /// Kullanıcı düzeltmesi; nil = yok, boş = gizli.
        public var correction: String?
        public var confidence: Double?

        public init(wordId: String, text: String, original: String, correction: String?, confidence: Double?) {
            self.wordId = wordId
            self.text = text
            self.original = original
            self.correction = correction
            self.confidence = confidence
        }
    }

    public var id: String
    public var captionTrackId: UUID
    public var range: TimeRange
    public var words: [Word]

    public var text: String { words.map(\.text).filter { !$0.isEmpty }.joined(separator: " ") }
    public var isCorrected: Bool { words.contains { $0.correction != nil } }

    /// AI'nın emin olmadığı, kullanıcının düzeltmediği kelimeler (kontrol önerilir).
    public func uncertainWordIds(threshold: Double = 0.6) -> Set<String> {
        Set(words.filter { $0.correction == nil && ($0.confidence ?? 1) < threshold }.map(\.wordId))
    }
}

extension RenderPlan {
    /// Düzenleme listesi: önizleme ve dışa aktarmayla aynı satır bölme kuralları;
    /// gizlenmiş kelimeler de satırda tutulur (geri alınabilsin diye).
    public static func editableLines(for document: ProjectDocument, style: CaptionStyle = .standard) -> [EditableCaptionLine] {
        let builder = CaptionLineBuilder(maxCharacters: style.maxCharactersPerLine)
        return document.captionTracks.flatMap { track in
            let source = Dictionary(track.words.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return builder.lines(from: document.timelineWords(for: track)).compactMap { line -> EditableCaptionLine? in
                guard let first = line.words.first else { return nil }
                return EditableCaptionLine(
                    id: "\(track.captionTrackId.uuidString)/\(first.clipId.uuidString)/\(first.wordId)",
                    captionTrackId: track.captionTrackId,
                    range: line.range,
                    words: line.words.map { word in
                        let original = source[word.wordId]
                        return .init(wordId: word.wordId, text: word.text, original: original?.display ?? word.text,
                                     correction: track.corrections[word.wordId], confidence: original?.confidence)
                    }
                )
            }
        }
        .sorted { $0.range.start < $1.range.start }
    }
}

/// Satırın yeni metnini kelime düzeltmelerine çevirir.
///
/// Yeni metin boşluklardan sözcüklere bölünür ve eski kelimelerle en uzun ortak
/// alt dizi üzerinden hizalanır: değişmeyen kelimeler dokunulmadan kalır.
/// Aradaki değişen kısımda sözcükler sırayla kelimelere dağıtılır; sözcük
/// fazlaysa sonuncuya eklenir, eksikse aradaki kelimeler gizlenir. AI metnine
/// dönen kelimenin düzeltmesi kaldırılır. Yalnız değişen kelimeler döner.
public enum CaptionLineEditor {
    public static func corrections(for line: EditableCaptionLine, newText: String) -> [WordCorrection] {
        let words = line.words
        guard !words.isEmpty else { return [] }
        let tokens = newText.split(whereSeparator: \.isWhitespace).map(String.init)
        var targets = words.map(\.text)

        // Eşleşen (kelime, sözcük) çiftleri; gizli kelime hiçbir sözcükle eşleşmez.
        let matches = lcs(words.map(\.text), tokens)
        var previousWord = -1, previousToken = -1
        for (w, t) in matches + [(words.count, tokens.count)] {
            let gapWords = Array((previousWord + 1)..<w)
            let gapTokens = Array(tokens[(previousToken + 1)..<t])
            if !gapWords.isEmpty {
                distribute(gapTokens, over: gapWords, into: &targets)
            } else if !gapTokens.isEmpty {
                // Araya kelime yoksa yeni sözcükler komşu kelimeye eklenir.
                let joined = gapTokens.joined(separator: " ")
                if previousWord >= 0 {
                    targets[previousWord] += " " + joined
                } else {
                    targets[w] = joined + " " + targets[w]
                }
            }
            previousWord = w
            previousToken = t
        }

        return words.indices.compactMap { i in
            let target = targets[i]
            let correction: String? = target == words[i].original ? nil : target
            return correction == words[i].correction ? nil : WordCorrection(wordId: words[i].wordId, text: correction)
        }
    }

    /// Satırdaki bütün düzeltmeleri kaldırır (AI metnine döner).
    public static func revert(_ line: EditableCaptionLine) -> [WordCorrection] {
        line.words.filter { $0.correction != nil }.map { WordCorrection(wordId: $0.wordId, text: nil) }
    }

    private static func distribute(_ tokens: [String], over indices: [Int], into targets: inout [String]) {
        let n = indices.count, m = tokens.count
        guard m > 0 else {
            for i in indices { targets[i] = "" }
            return
        }
        if m >= n {
            for k in 0..<(n - 1) { targets[indices[k]] = tokens[k] }
            targets[indices[n - 1]] = tokens[(n - 1)...].joined(separator: " ")
        } else {
            for k in 0..<(m - 1) { targets[indices[k]] = tokens[k] }
            for k in (m - 1)..<(n - 1) { targets[indices[k]] = "" }
            targets[indices[n - 1]] = tokens[m - 1]
        }
    }

    /// En uzun ortak alt dizinin indeks çiftleri (boş metin eşleşmez).
    private static func lcs(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = (!a[i].isEmpty && a[i] == b[j]) ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if !a[i].isEmpty, a[i] == b[j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }
}
