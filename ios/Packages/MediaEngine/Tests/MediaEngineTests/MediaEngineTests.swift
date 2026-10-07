import XCTest
import AVFoundation
import CryptoKit
import AIJobsClient
import EditorDomain
@testable import MediaEngine

final class MediaEngineTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// 44.1 kHz stereo, 440 Hz sinüs: iPhone kaydına benzer bir kaynak.
    private func makeTone(seconds: Double, sampleRate: Double = 44_100) throws -> URL {
        let url = dir.appendingPathComponent("ton.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<2 {
            let samples = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) {
                samples[i] = Float(sin(2 * Double.pi * 440 * Double(i) / sampleRate) * 0.3)
            }
        }
        try file.write(from: buffer)
        return url
    }

    private func streamDescription(of url: URL) async throws -> AudioStreamBasicDescription {
        let track = try await XCTUnwrapAsync(try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first)
        let format = try await XCTUnwrapAsync(try await track.load(.formatDescriptions).first)
        return try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
    }

    // MARK: - İnceleme

    func testSesDosyasiIncelenir() async throws {
        let probe = try await MediaInspector.probe(try makeTone(seconds: 3))
        XCTAssertEqual(probe.duration.seconds, 3, accuracy: 0.05)
        XCTAssertTrue(probe.hasAudio)
        XCTAssertFalse(probe.hasVideo)
        XCTAssertNil(probe.displaySize)
        XCTAssertEqual(probe.mediaAsset(relativePath: "Media/a.caf").kind, .audio)
    }

    func testMedyaOlmayanDosyaReddedilir() async throws {
        let url = dir.appendingPathComponent("not.mov")
        try Data("video değil".utf8).write(to: url)
        do {
            _ = try await MediaInspector.probe(url)
            XCTFail("hata bekleniyordu")
        } catch {
            XCTAssertEqual(error as? MediaEngineError, .unreadable)
        }
    }

    // MARK: - Ses çıkarma

    func testSesMono16kHzAACOlarakCikarilir() async throws {
        let out = dir.appendingPathComponent("ses.m4a")
        let audio = try await AudioExtractor.extract(from: try makeTone(seconds: 3), to: out)

        let asbd = try await streamDescription(of: out)
        XCTAssertEqual(asbd.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(asbd.mSampleRate, 16_000)
        XCTAssertEqual(asbd.mChannelsPerFrame, 1)

        XCTAssertEqual(audio.durationSeconds, 3, accuracy: 0.1)
        XCTAssertLessThan(audio.byteCount, 30_000, "3 sn ~32 kbps ≈ 12 KB olmalı")
        let expected = SHA256.hash(data: try Data(contentsOf: out)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(audio.sha256Hex, expected)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".") }, [],
                       "geçici dosya kalmaz")
    }

    func testYalnizIstenenAralikCikarilir() async throws {
        let range = TimeRange(start: MediaTime(seconds: 1), end: MediaTime(seconds: 2.5))
        let audio = try await AudioExtractor.extract(from: try makeTone(seconds: 4), range: range,
                                                     to: dir.appendingPathComponent("kesit.m4a"))
        XCTAssertEqual(audio.durationSeconds, 1.5, accuracy: 0.1)
    }

    func testBosAralikReddedilir() async throws {
        let range = TimeRange(start: MediaTime(seconds: 2), end: MediaTime(seconds: 2))
        do {
            _ = try await AudioExtractor.extract(from: try makeTone(seconds: 3), range: range, to: dir.appendingPathComponent("x.m4a"))
            XCTFail("hata bekleniyordu")
        } catch {
            XCTAssertEqual(error as? MediaEngineError, .emptyRange)
        }
    }

    // MARK: - Altyazı servisi (sahte sunucu)

    func testAltyaziServisiSesiGonderirKomutDondurur() async throws {
        let server = FakeServer()
        let client = AIJobsClient(baseURL: URL(string: "https://proje.supabase.co/functions/v1/api")!,
                                  transport: server, accessToken: { "jwt" })
        let service = CaptioningService(
            workflow: TranscriptionWorkflow(client: client, sleep: { _ in }),
            workDirectory: dir.appendingPathComponent("work")
        )
        let mediaId = UUID()
        let range = TimeRange(start: MediaTime(seconds: 1), end: MediaTime(seconds: 3))

        let command = try await service.caption(mediaId: mediaId, source: try makeTone(seconds: 4),
                                                range: range, clientRequestId: "req-test-0001")

        guard case let .applyTranscript(id, transcript, start) = command else { return XCTFail("\(command)") }
        XCTAssertEqual(id, mediaId)
        XCTAssertEqual(start, MediaTime(seconds: 1), "kaynak ofseti korunur")
        XCTAssertEqual(transcript.words.first?.text, "merhaba")

        let created = try XCTUnwrap(server.createBody)
        // AAC kodlayıcı birkaç ms dolgu ekleyebilir; yukarı yuvarlama 2 ya da 3 verir.
        // Sunucu ölçülen ile bildirilenin küçüğünü ücretlendirdiği için fazla bildirim güvenli.
        XCTAssertTrue((2...3).contains(created["durationSeconds"] as? Int ?? 0), "\(created)")
        XCTAssertEqual(created["clientRequestId"] as? String, "req-test-0001")
        XCTAssertEqual((created["audioSha256"] as? String)?.count, 64)
        XCTAssertEqual(server.uploadedBytes, created["audioBytes"] as? Int, "bildirilen boyut yüklenenle aynı")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("work").path), [],
                       "gönderilen ses silinir")
    }
}

/// Sözleşmedeki yanıtları veren, gönderilenleri kaydeden sahte sunucu.
private final class FakeServer: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var createBody: [String: Any]?
    private(set) var uploadedBytes: Int?
    private let jobId = "6f1c2b0a-9d3e-4c5b-8a71-2e4f6a8b9c0d"

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = lock.withLock { () -> String in
            let path = request.url!.path
            let job = #"{"id":"\#(jobId)","status":"STATUS","createdAt":"2026-10-07T12:00:00Z","errorCode":null}"#
            switch (request.httpMethod ?? "GET", path) {
            case ("POST", let p) where p.hasSuffix("/v1/transcription-jobs"):
                createBody = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                let upload = #"{"url":"https://proje.supabase.co/storage/v1/object/upload/sign/x?token=t","method":"PUT","headers":{"Content-Type":"audio/mp4"},"expiresAt":"2026-10-07T13:00:00Z"}"#
                return #"{"job":\#(job.replacingOccurrences(of: "STATUS", with: "awaiting_upload")),"upload":\#(upload)}"#
            case ("PUT", _):
                uploadedBytes = request.httpBody?.count
                return "{}"
            case ("POST", let p) where p.hasSuffix("/uploaded"):
                return #"{"job":\#(job.replacingOccurrences(of: "STATUS", with: "queued"))}"#
            default:
                let transcript = #"{"schemaVersion":1,"provider":"fake","model":"fake-v1","language":"tr","durationSeconds":2,"words":[{"text":"merhaba","start":0.1,"end":0.5}]}"#
                return #"{"job":\#(job.replacingOccurrences(of: "STATUS", with: "succeeded")),"result":{"transcript":\#(transcript),"expiresAt":"2026-10-14T12:00:00Z"}}"#
            }
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// XCTUnwrap'ın async ifade alan karşılığı.
private func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let result = try await value()
    return try XCTUnwrap(result, file: file, line: line)
}
