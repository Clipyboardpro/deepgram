import XCTest
import AVFoundation
import EditorDomain
@testable import MediaEngine

final class ExporterTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testAltyaziVideoyaDogruZamandaIslenir() async throws {
        // Siyah 3 sn video; 1–2 sn arasında bir altyazı satırı.
        let source = try await TestVideo.make(in: dir, seconds: 3, brightness: 0)
        let media = MediaAsset(kind: .video, relativePath: "Media/x.mov", duration: MediaTime(seconds: 3), hasAudio: false)
        var doc = ProjectDocument(mediaAssets: [media], tracks: [Track(kind: .video)])
        doc.tracks[0].clips = [Clip(mediaId: media.mediaId, sourceIn: .zero, sourceOut: MediaTime(seconds: 3), timelineStart: .zero)]
        doc.captionTracks = [CaptionTrack(mediaId: media.mediaId, language: "tr", words: [
            .init(id: "w1000", text: "MERHABA", display: "MERHABA", sourceStart: MediaTime(seconds: 1), sourceEnd: MediaTime(seconds: 2), confidence: nil),
        ])]

        let output = dir.appendingPathComponent("cikti.mp4")
        let progress = ProgressBox()
        let url = try await Exporter(builder: CompositionBuilder(resolveURL: { _ in source }))
            .export(doc, to: output, progress: { progress.record($0) })

        // Dosya, süre, boyut.
        XCTAssertEqual(url, output)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 3, accuracy: 0.1)
        let track = try await XCTUnwrapAsync(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 1080, height: 1920))
        XCTAssertEqual(progress.last, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".export-") }, [],
                       "geçici dosya kalmaz")

        // Altyazı bandı: üstten 1920 - (alt boşluk + kutu yüksekliği) ile 1920 - alt boşluk arası.
        let style = CaptionStyle.standard
        let bottom = style.bottomMargin(forCanvasHeight: 1920)
        let boxHeight = style.fontSize(forCanvasHeight: 1920) * 2.6
        let band = CGRect(x: 100, y: 1920 - bottom - boxHeight, width: 880, height: boxHeight)

        let during = try await brightest(in: band, of: asset, at: 1.5)
        let before = try await brightest(in: band, of: asset, at: 0.5)
        let after = try await brightest(in: band, of: asset, at: 2.5)
        XCTAssertGreaterThan(during, 200, "altyazı süresince bantta beyaz yazı var")
        XCTAssertLessThan(before, 40, "altyazıdan önce bant boş")
        XCTAssertLessThan(after, 40, "altyazıdan sonra bant boş")
    }

    func testBosProjeDisaAktarilamaz() async {
        do {
            _ = try await Exporter(builder: CompositionBuilder(resolveURL: { _ in URL(fileURLWithPath: "/yok") }))
                .export(ProjectDocument(tracks: [Track(kind: .video)]), to: dir.appendingPathComponent("x.mp4"))
            XCTFail("hata bekleniyordu")
        } catch {
            XCTAssertEqual(error as? ExportError, .emptyProject)
        }
    }

    // MARK: - Yardımcılar

    /// Karedeki bölgenin en parlak pikseli (0–255). Bölge üst-sol başlangıçlı.
    private func brightest(in rect: CGRect, of asset: AVAsset, at seconds: Double) async throws -> Int {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))

        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                              bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // CGContext belleği üst satırdan başlar; bölge üst-sol koordinatında.
        var maximum = 0
        for y in Int(rect.minY)..<min(Int(rect.maxY), height) {
            for x in Int(rect.minX)..<min(Int(rect.maxX), width) {
                maximum = max(maximum, Int(pixels[y * width + x]))
            }
        }
        return maximum
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var last: Double?
    func record(_ value: Double) { lock.withLock { last = value } }
}

private func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let result = try await value()
    return try XCTUnwrap(result, file: file, line: line)
}
