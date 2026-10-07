import Foundation

/// Altyazının ekrandaki görünüş kuralları. Ölçüler kanvasa görelidir; böylece
/// telefondaki küçük önizleme ile 1080×1920 çıktı aynı oranda çizilir.
public struct CaptionStyle: Equatable, Sendable, Codable {
    /// Punto = oran × kanvas yüksekliği (1920'de ≈ 65 pt).
    public var fontSizeRatio: Double
    /// Satırın alt kenarı ile kanvasın altı arasındaki boşluk (yükseklik oranı).
    public var bottomMarginRatio: Double
    /// Satırın en fazla genişliği (kanvas genişliği oranı).
    public var maxWidthRatio: Double
    public var maxCharactersPerLine: Int

    public init(fontSizeRatio: Double = 0.034, bottomMarginRatio: Double = 0.18,
                maxWidthRatio: Double = 0.84, maxCharactersPerLine: Int = 32) {
        self.fontSizeRatio = fontSizeRatio
        self.bottomMarginRatio = bottomMarginRatio
        self.maxWidthRatio = maxWidthRatio
        self.maxCharactersPerLine = maxCharactersPerLine
    }

    public static let standard = CaptionStyle()

    public func fontSize(forCanvasHeight height: Double) -> Double { fontSizeRatio * height }
    public func bottomMargin(forCanvasHeight height: Double) -> Double { bottomMarginRatio * height }
    public func maxWidth(forCanvasWidth width: Double) -> Double { maxWidthRatio * width }
}

/// Belirli bir aralıkta ekranda duran tek altyazı satırı.
public struct CaptionCue: Equatable, Sendable {
    public var text: String
    public var range: TimeRange

    public init(text: String, range: TimeRange) {
        self.text = text
        self.range = range
    }
}

/// Projeden çizim planı. Önizleme (SwiftUI katmanı) ve dışa aktarma (videoya
/// işleme) aynı fonksiyonları kullanır; ikisinin ayrışması bu yüzden önlenir.
public enum RenderPlan {
    /// Tüm altyazı kanallarından, zaman çizelgesine yerleşmiş, çakışmayan satırlar.
    /// İki satır üst üste binerse öncekinin sonu sonrakinin başına çekilir.
    public static func captionCues(for document: ProjectDocument, style: CaptionStyle = .standard) -> [CaptionCue] {
        let builder = CaptionLineBuilder(maxCharacters: style.maxCharactersPerLine)
        var cues = document.captionTracks
            .flatMap { builder.lines(from: document.timelineWords(for: $0)) }
            .map { CaptionCue(text: $0.text, range: $0.range) }
            .sorted { $0.range.start < $1.range.start }

        for i in cues.indices.dropLast() where cues[i].range.end > cues[i + 1].range.start {
            cues[i].range.end = cues[i + 1].range.start
        }
        return cues.filter { !$0.range.isEmpty }
    }

    /// `time` anında gösterilecek satır.
    public static func cue(at time: MediaTime, in cues: [CaptionCue]) -> CaptionCue? {
        cues.first { $0.range.contains(time) }
    }
}
