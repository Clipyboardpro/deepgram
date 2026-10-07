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

    /// Her satır için bir görüntü katmanı; yalnız kendi aralığında görünür.
    ///
    /// `CATextLayer` dışa aktarmanın çevrimdışı çiziminde metni çizmiyor (macOS
    /// CI'da düz renkli katman çıktıya düşerken metin katmanı boş kaldı). Bu yüzden
    /// metin CoreText ile önceden bit eşleme çizilip katmanın içeriği yapılır.
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
        let height = fontSize * 2.6   // en fazla iki satır

        for cue in cues {
            let layer = CALayer()
            // Core Animation aracı alt-sol başlangıçlı koordinat kullanır: y alttan ölçülür.
            layer.frame = CGRect(x: (renderSize.width - maxWidth) / 2, y: bottom, width: maxWidth, height: height)
            layer.contents = renderCaption(cue.text, size: layer.frame.size, fontSize: fontSize)
            layer.contentsGravity = .resize
            layer.opacity = 0

            let show = CABasicAnimation(keyPath: "opacity")
            show.fromValue = 1
            show.toValue = 1
            show.beginTime = cue.range.start.seconds == 0 ? AVCoreAnimationBeginTimeAtZero : cue.range.start.seconds
            show.duration = cue.range.duration.seconds
            show.isRemovedOnCompletion = true
            show.fillMode = .removed
            layer.add(show, forKey: "görünür")
            parent.addSublayer(layer)
        }

        return AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: video, in: parent)
    }
}

/// Altyazı satırını şeffaf zeminli bit eşlemeye çizer: beyaz, kalın, ortalı,
/// gölgeli; metin kutunun üstünden başlar ve gerekirse sarılır.
func renderCaption(_ text: String, size: CGSize, fontSize: CGFloat) -> CGImage? {
    let width = Int(size.width.rounded(.up)), height = Int(size.height.rounded(.up))
    guard width > 0, height > 0,
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    var alignment = CTTextAlignment.center
    let paragraph = withUnsafeBytes(of: &alignment) { bytes in
        var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: bytes.count, value: bytes.baseAddress!)
        return CTParagraphStyleCreate(&setting, 1)
    }
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
    ]
    let framesetter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil)
    let textFrame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)

    context.setShadow(offset: .zero, blur: fontSize * 0.16, color: CGColor(gray: 0, alpha: 0.85))
    CTFrameDraw(textFrame, context)
    return context.makeImage()
}

/// `progress` ve `cancelExport` iş parçacığı güvenlidir; oturumu ilerleme
/// görevine ve iptal kapanışına taşımak için sarmalayıcı.
private final class SessionHandle: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}
