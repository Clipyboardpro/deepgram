import XCTest
import AVFoundation
import EditorDomain
@testable import MediaEngine

final class CompositionBuilderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("comp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Yerleşim hesabı

    func testDikeyIPhoneVideosuKanvasiTamDoldurur() {
        // iPhone dikey kaydı: 1920×1080 saklanır, 90° döndürülerek gösterilir.
        let preferred = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        let t = FillTransform.make(natural: CGSize(width: 1920, height: 1080), preferred: preferred,
                                   canvas: CGSize(width: 1080, height: 1920), clip: .identity)
        let placed = CGRect(x: 0, y: 0, width: 1920, height: 1080).applying(t)
        XCTAssertEqual(placed.minX, 0, accuracy: 0.5)
        XCTAssertEqual(placed.minY, 0, accuracy: 0.5)
        XCTAssertEqual(placed.width, 1080, accuracy: 0.5)
        XCTAssertEqual(placed.height, 1920, accuracy: 0.5)
    }

    func testYatayVideoDikeyKanvastaOrtalanipDoldurur() {
        let canvas = CGSize(width: 1080, height: 1920)
        let t = FillTransform.make(natural: CGSize(width: 1920, height: 1080), preferred: .identity, canvas: canvas, clip: .identity)
        let placed = CGRect(x: 0, y: 0, width: 1920, height: 1080).applying(t)
        XCTAssertEqual(placed.height, 1920, accuracy: 0.5, "yükseklik kanvası doldurur")
        XCTAssertEqual(placed.midX, canvas.width / 2, accuracy: 0.5, "yatayda ortalı")
        XCTAssertEqual(placed.midY, canvas.height / 2, accuracy: 0.5)
    }

    func testKlipOlcekVeKaydirmasiUygulanir() {
        let canvas = CGSize(width: 1080, height: 1920)
        let clip = Transform(scale: 2, offsetX: 0.1, offsetY: 0)
        let t = FillTransform.make(natural: CGSize(width: 1080, height: 1920), preferred: .identity, canvas: canvas, clip: clip)
        let placed = CGRect(x: 0, y: 0, width: 1080, height: 1920).applying(t)
        XCTAssertEqual(placed.width, 2160, accuracy: 0.5)
        XCTAssertEqual(placed.midX, canvas.width / 2 + 108, accuracy: 0.5)
    }

    // MARK: - Kompozisyon

    func testHizliKlipVeKesitlerDogruSureyiVerir() async throws {
        let (doc, mediaURL) = try await project(clips: { media in [
            Clip(mediaId: media, sourceIn: .s(0), sourceOut: .s(2), timelineStart: .s(0)),
            Clip(mediaId: media, sourceIn: .s(1), sourceOut: .s(3), timelineStart: .s(2), playbackRate: 2),
        ] })
        let built = try await CompositionBuilder(resolveURL: { _ in mediaURL }).build(doc)

        XCTAssertEqual(built.duration.seconds, 3, accuracy: 0.05, "2 sn + (2 sn / 2x)")
        XCTAssertEqual(built.duration.seconds, doc.duration.seconds, accuracy: 0.05, "model ile kompozisyon aynı süre")
        let video = try XCTUnwrap(built.videoComposition)
        XCTAssertEqual(video.renderSize, CGSize(width: 1080, height: 1920))
        try assertContiguous(video.instructions, covering: built.duration)

        // Gerçekten kare üretilebiliyor mu? (hızlandırılmış ikinci klipten)
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = video
        let (image, _) = try await generator.image(at: CMTime(seconds: 2.5, preferredTimescale: 600))
        XCTAssertEqual(image.width, 1080)
        XCTAssertEqual(image.height, 1920)
    }

    func testKlipArasiBoslukSiyahAralikOlur() async throws {
        let (doc, mediaURL) = try await project(clips: { media in [
            Clip(mediaId: media, sourceIn: .s(0), sourceOut: .s(2), timelineStart: .s(1)),
        ] })
        let built = try await CompositionBuilder(resolveURL: { _ in mediaURL }).build(doc)
        XCTAssertEqual(built.duration.seconds, 3, accuracy: 0.05)
        let instructions = try XCTUnwrap(built.videoComposition?.instructions)
        XCTAssertEqual(instructions.first?.timeRange.duration.seconds ?? -1, 1, accuracy: 0.01)
        XCTAssertEqual((instructions.first as? AVVideoCompositionInstruction)?.layerInstructions.count, 0, "boşlukta katman yok")
        try assertContiguous(instructions, covering: built.duration)
    }

    func testBosProjeGoruntusuz() async throws {
        let built = try await CompositionBuilder(resolveURL: { _ in URL(fileURLWithPath: "/yok") }).build(ProjectDocument(tracks: [Track(kind: .video)]))
        XCTAssertNil(built.videoComposition)
        XCTAssertEqual(built.duration, .zero)
    }

    func testEksikMedyaHatasi() async throws {
        let missing = UUID()
        var doc = ProjectDocument(tracks: [Track(kind: .video)])
        doc.tracks[0].clips = [Clip(mediaId: missing, sourceIn: .s(0), sourceOut: .s(1), timelineStart: .s(0))]
        do {
            _ = try await CompositionBuilder(resolveURL: { _ in URL(fileURLWithPath: "/yok") }).build(doc)
            XCTFail("hata bekleniyordu")
        } catch {
            XCTAssertEqual(error as? CompositionError, .missingMedia(missing))
        }
    }

    // MARK: - Yardımcılar

    private func project(clips: (UUID) -> [Clip]) async throws -> (ProjectDocument, URL) {
        let url = try await TestVideo.make(in: dir, seconds: 3)
        let media = MediaAsset(kind: .video, relativePath: "Media/test.mov", duration: .s(3), hasAudio: false)
        var doc = ProjectDocument(mediaAssets: [media], tracks: [Track(kind: .video)])
        doc.tracks[0].clips = clips(media.mediaId)
        XCTAssertEqual(ProjectValidator.validate(doc), [])
        return (doc, url)
    }

    private func assertContiguous(_ instructions: [AVVideoCompositionInstructionProtocol], covering duration: CMTime,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        var cursor = CMTime.zero
        for instruction in instructions {
            XCTAssertEqual(instruction.timeRange.start.seconds, cursor.seconds, accuracy: 0.001, "aralıklar bitişik", file: file, line: line)
            cursor = instruction.timeRange.end
        }
        XCTAssertEqual(cursor.seconds, duration.seconds, accuracy: 0.001, "talimatlar tüm süreyi kapsar", file: file, line: line)
    }
}

private extension MediaTime {
    static func s(_ seconds: Double) -> MediaTime { MediaTime(seconds: seconds) }
}

/// Test için küçük H.264 video üretir (düz renk kareler, ses yok).
enum TestVideo {
    static func make(in dir: URL, seconds: Int, size: CGSize = CGSize(width: 320, height: 180), fps: Int32 = 30) async throws -> URL {
        let url = dir.appendingPathComponent("test-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? MediaEngineError.exportFailed("test video") }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<(Int(fps) * seconds) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            guard let buffer else { throw MediaEngineError.exportFailed("pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!
            memset(base, Int32(frame * 4 % 255), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? MediaEngineError.exportFailed("test video") }
        return url
    }
}
