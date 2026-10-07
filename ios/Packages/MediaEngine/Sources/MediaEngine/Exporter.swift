import AVFoundation
import CoreText
import QuartzCore
import EditorDomain

public enum ExportError: Error, Equatable, Sendable {
    case emptyProject
    case sessionUnavailable
    case failed(String)
    case canceled
}

/// Projeyi 1080p SDR MP4 olarak dışa aktarır; altyazılar görüntüye işlenir.
///
/// - Kompozisyon `CompositionBuilder`'dan gelir (önizlemeyle aynı).
/// - Altyazı satırları `RenderPlan.captionCues`'tan gelir (önizlemeyle aynı kurallar).
/// - Çıktı önce geçici dosyaya yazılır, başarıdan sonra hedefe taşınır.
/// - Dışa aktarma çağrıldığı andaki revizyon üzerinde çalışır; sonraki
///   düzenlemeler bu çıktıyı etkilemez.
public struct Exporter: Sendable {
    private let builder: CompositionBuilder

    public init(builder: CompositionBuilder) {
        self.builder = builder
    }

    public func export(
        _ document: ProjectDocument,
        to destination: URL,
        style: CaptionStyle = .standard,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let built = try await builder.build(document)
        guard let base = built.videoComposition, built.duration > .zero else { throw ExportError.emptyProject }

        let videoComposition = base.mutableCopy() as! AVMutableVideoComposition
        let cues = RenderPlan.captionCues(for: document, style: style)
        if !cues.isEmpty {
            videoComposition.animationTool = Self.captionTool(cues: cues, renderSize: videoComposition.renderSize, style: style)
        }

        guard let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.sessionUnavailable
        }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".export-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }

        session.outputURL = temporary
        session.outputFileType = .mp4
        session.videoComposition = videoComposition
        session.audioMix = built.audioMix
        session.shouldOptimizeForNetworkUse = true

        let handle = SessionHandle(session)
        let watcher = progress.map { report in
            Task {
                while !Task.isCancelled {
                    report(Double(handle.session.progress))
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
        }
        defer { watcher?.cancel() }

        await withTaskCancellationHandler {
            await session.export()
        } onCancel: {
            handle.session.cancelExport()
        }

        switch session.status {
        case .completed:
            break
        case .cancelled:
            throw ExportError.canceled
        default:
            throw ExportError.failed(session.error?.localizedDescription ?? "bilinmiyor")
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: temporary, to: destination)
        progress?(1)
        return destination
    }

    // MARK: - Altyazı katmanı

    /// Her satır için bir metin katmanı; yalnız kendi aralığında görünür.
    static func captionTool(cues: [CaptionCue], renderSize: CGSize, style: CaptionStyle) -> AVVideoCompositionCoreAnimationTool {
        let frame = CGRect(origin: .zero, size: renderSize)
        let parent = CALayer()
        parent.frame = frame
        let video = CALayer()
        video.frame = frame
        parent.addSublayer(video)

        let fontSize = CGFloat(style.fontSize(forCanvasHeight: renderSize.height))
        let maxWidth = CGFloat(style.maxWidth(forCanvasWidth: renderSize.width))
        let bottom = CGFloat(style.bottomMargin(forCanvasHeight: renderSize.height))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)

        for cue in cues {
            let text = CATextLayer()
            text.string = NSAttributedString(string: cue.text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            ])
            text.alignmentMode = .center
            text.isWrapped = true
            text.contentsScale = 1
            // Core Animation aracı alt-sol başlangıçlı koordinat kullanır: y alttan ölçülür.
            let height = fontSize * 2.6   // en fazla iki satır
            text.frame = CGRect(x: (renderSize.width - maxWidth) / 2, y: bottom, width: maxWidth, height: height)
            text.shadowColor = CGColor(gray: 0, alpha: 1)
            text.shadowOpacity = 0.85
            text.shadowRadius = fontSize * 0.08
            text.shadowOffset = .zero
            text.opacity = 0

            let show = CABasicAnimation(keyPath: "opacity")
            show.fromValue = 1
            show.toValue = 1
            show.beginTime = cue.range.start.seconds == 0 ? AVCoreAnimationBeginTimeAtZero : cue.range.start.seconds
            show.duration = cue.range.duration.seconds
            show.isRemovedOnCompletion = true
            show.fillMode = .removed
            text.add(show, forKey: "görünür")
            parent.addSublayer(text)
        }

        return AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: video, in: parent)
    }
}

/// `progress` ve `cancelExport` iş parçacığı güvenlidir; oturumu ilerleme
/// görevine ve iptal kapanışına taşımak için sarmalayıcı.
private final class SessionHandle: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}
