import Foundation

/// Zaman çizelgesine yerleşmiş bir kelime.
public struct TimelineWord: Equatable, Sendable {
    public var wordId: String
    public var clipId: UUID
    public var text: String
    public var range: TimeRange
}

/// Ekranda bir seferde gösterilen altyazı satırı.
public struct CaptionLine: Equatable, Sendable {
    public var words: [TimelineWord]
    public var range: TimeRange
    public var text: String { words.map(\.text).joined(separator: " ") }
}

extension ProjectDocument {
    /// Bir altyazı kanalının kelimelerini, o medyayı kullanan her klibin
    /// kesme ve hız dönüşümünden geçirerek zaman çizelgesine yerleştirir.
    /// Aynı kaynak iki kesitte kullanılıyorsa kelime iki kez görünür. Klip
    /// sınırına taşan kelimenin sonu klip sonuna kırpılır; başlangıcı klipte
    /// olmayan kelime o klipte gösterilmez.
    public func timelineWords(for captionTrack: CaptionTrack) -> [TimelineWord] {
        let clips = tracks
            .filter { $0.kind == .video || $0.kind == .audio }
            .flatMap(\.clips)
            .filter { $0.mediaId == captionTrack.mediaId }

        var result: [TimelineWord] = []
        for clip in clips {
            for word in captionTrack.words {
                guard let start = clip.timelineTime(forSource: word.sourceStart) else { continue }
                let clippedSourceEnd = min(word.sourceEnd, clip.sourceOut)
                let end = clip.timelineStart + (clippedSourceEnd - clip.sourceIn).divided(by: clip.playbackRate)
                guard end > start else { continue }
                result.append(TimelineWord(
                    wordId: word.id,
                    clipId: clip.clipId,
                    text: captionTrack.displayText(for: word),
                    range: TimeRange(start: start, end: end)
                ))
            }
        }
        return result.sorted { $0.range.start < $1.range.start }
    }
}

/// Kelimeleri okunabilir satırlara böler.
public struct CaptionLineBuilder: Sendable {
    public var maxCharacters: Int
    public var maxDuration: MediaTime
    /// Kelimeler arası bu süreden uzun sessizlikte yeni satır başlar.
    public var maxGap: MediaTime

    public init(maxCharacters: Int = 32, maxDuration: MediaTime = MediaTime(seconds: 3), maxGap: MediaTime = MediaTime(seconds: 0.6)) {
        self.maxCharacters = maxCharacters
        self.maxDuration = maxDuration
        self.maxGap = maxGap
    }

    public func lines(from words: [TimelineWord]) -> [CaptionLine] {
        var lines: [CaptionLine] = []
        var current: [TimelineWord] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            lines.append(CaptionLine(words: current, range: TimeRange(start: first.range.start, end: last.range.end)))
            current = []
        }

        for word in words {
            if let first = current.first, let last = current.last {
                let length = (current.map(\.text) + [word.text]).joined(separator: " ").count
                let breaks =
                    length > maxCharacters
                    || word.range.end - first.range.start > maxDuration
                    || word.range.start - last.range.end > maxGap
                    || last.clipId != word.clipId
                    || Self.endsSentence(last.text)
                if breaks { flush() }
            }
            current.append(word)
        }
        flush()
        return lines
    }

    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".!?…".contains(last)
    }
}
