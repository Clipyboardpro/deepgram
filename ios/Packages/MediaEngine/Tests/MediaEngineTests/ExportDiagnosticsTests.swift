import XCTest
import AVFoundation
import QuartzCore
import EditorDomain
@testable import MediaEngine

/// GEÇİCİ teşhis: Core Animation katmanının çıktıda nerede/ne zaman göründüğünü raporlar.
final class ExportDiagnosticsTests: XCTestCase {
    func testKatmanTeshisi() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("diag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try await TestVideo.make(in: dir, seconds: 3, brightness: 0)
        let media = MediaAsset(kind: .video, relativePath: "Media/x.mov", duration: MediaTime(seconds: 3), hasAudio: false)
        var doc = ProjectDocument(mediaAssets: [media], tracks: [Track(kind: .video)])
        doc.tracks[0].clips = [Clip(mediaId: media.mediaId, sourceIn: .zero, sourceOut: MediaTime(seconds: 3), timelineStart: .zero)]
        let built = try await CompositionBuilder(resolveURL: { _ in source }).build(doc)
        let size = CGSize(width: 1080, height: 1920)

        func tool(_ add: (CALayer) -> Void) -> AVVideoCompositionCoreAnimationTool {
            let parent = CALayer(); parent.frame = CGRect(origin: .zero, size: size)
            let video = CALayer(); video.frame = parent.frame
            parent.addSublayer(video); add(parent)
            return AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: video, in: parent)
        }
        let box = CGRect(x: 86, y: 346, width: 907, height: 170)
        let variants: [(String, AVVideoCompositionCoreAnimationTool)] = [
            ("A-beyaz-kutu", tool { p in let l = CALayer(); l.frame = box; l.backgroundColor = CGColor(gray: 1, alpha: 1); p.addSublayer(l) }),
            ("B-metin-animsiz", tool { p in
                let t = CATextLayer(); t.frame = box; t.string = "MERHABA"; t.fontSize = 65
                t.foregroundColor = CGColor(gray: 1, alpha: 1); t.alignmentMode = .center; p.addSublayer(t) }),
            ("C-captionTool", Exporter.captionTool(cues: [CaptionCue(text: "MERHABA", range: TimeRange(start: MediaTime(seconds: 1), end: MediaTime(seconds: 2)))],
                                                    renderSize: size, style: .standard)),
        ]
        var report: [String] = []
        for (name, animationTool) in variants {
            let vc = built.videoComposition!.mutableCopy() as! AVMutableVideoComposition
            vc.animationTool = animationTool
            let out = dir.appendingPathComponent("\(name).mp4")
            let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetHighestQuality)!
            session.outputURL = out; session.outputFileType = .mp4; session.videoComposition = vc
            await session.export()
            guard session.status == .completed else { report.append("\(name): durum \(session.status.rawValue) \(String(describing: session.error))"); continue }
            for t in [0.5, 1.5] {
                report.append("\(name) t=\(t): " + (try await brightRows(AVURLAsset(url: out), at: t)))
            }
        }
        print("TESHIS\n" + report.joined(separator: "\n"))
        XCTFail("TESHIS\n" + report.joined(separator: "\n"))
    }

    /// Parlak (>200) piksellerin üst-sol koordinatta satır/sütun aralığı.
    private func brightRows(_ asset: AVAsset, at seconds: Double) async throws -> String {
        let g = AVAssetImageGenerator(asset: asset)
        g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
        let (image, _) = try await g.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var minY = Int.max, maxY = -1, minX = Int.max, maxX = -1, peak = 0
        for y in 0..<h { for x in 0..<w { let v = Int(px[y * w + x]); peak = max(peak, v)
            if v > 200 { minY = min(minY, y); maxY = max(maxY, y); minX = min(minX, x); maxX = max(maxX, x) } } }
        return "\(w)x\(h) tepe=\(peak) parlak y=\(minY)...\(maxY) x=\(minX)...\(maxX)"
    }
}
