import XCTest
@testable import AIJobsClient

final class TranscriptionWorkflowTests: XCTestCase {
    /// Uykuyu gerçekten beklemeden kaydeder.
    final class SleepRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var delays: [Duration] = []
        func record(_ d: Duration) { lock.withLock { delays.append(d) } }
    }

    private let audio = AudioPayload(data: Data(repeating: 7, count: 2048), sha256Hex: String(repeating: "A", count: 64), durationSeconds: 60.2)

    private func workflow(_ transport: MockTransport, sleeper: SleepRecorder = SleepRecorder(), policy: PollingPolicy = PollingPolicy()) -> TranscriptionWorkflow {
        TranscriptionWorkflow(
            client: AIJobsClient(baseURL: Samples.base, transport: transport, accessToken: { "jwt" }),
            policy: policy,
            sleep: { sleeper.record($0) }
        )
    }

    func testUctanUcaAkis() async throws {
        let transport = MockTransport([
            (200, Samples.created()),                               // create
            (200, "{}"),                                            // PUT
            (200, #"{"job":\#(Samples.job("queued"))}"#),           // uploaded
            (200, Samples.jobWithResult("queued", result: false)),
            (200, Samples.jobWithResult("processing", result: false)),
            (200, Samples.jobWithResult("succeeded", result: true)),
        ])
        let sleeper = SleepRecorder()
        let transcript = try await workflow(transport, sleeper: sleeper).run(audio, clientRequestId: "req-00000001")

        XCTAssertEqual(transcript.words.map(\.text), ["merhaba"])
        XCTAssertEqual(transport.requests.map(\.method), ["POST", "PUT", "POST", "GET", "GET", "GET"])
        XCTAssertEqual(transport.requests[0].json?["durationSeconds"] as? Int, 61, "kesirli süre yukarı yuvarlanır")
        XCTAssertEqual(transport.requests[0].json?["audioSha256"] as? String, String(repeating: "a", count: 64), "özet küçük harfe çevrilir")
        XCTAssertEqual(transport.requests[0].json?["audioBytes"] as? Int, 2048)
        XCTAssertEqual(sleeper.delays, [.seconds(1), .milliseconds(1600)], "bekleme artarak büyür")
    }

    func testTekrarCagridaYuklemeAtlanir() async throws {
        // Önceki denemede yükleme ve bildirim yapılmış: sunucu upload=null, status=queued döner.
        let transport = MockTransport([
            (200, Samples.created(upload: false, status: "queued")),
            (200, Samples.jobWithResult("succeeded", result: true)),
        ])
        _ = try await workflow(transport).run(audio, clientRequestId: "req-00000001")
        XCTAssertEqual(transport.requests.map(\.method), ["POST", "GET"], "ne PUT ne uploaded tekrarlanır")
    }

    func testBasarisizIsKoduylaHataVerir() async {
        let transport = MockTransport([
            (200, Samples.created(upload: false, status: "submitted")),
            (200, Samples.jobWithResult("failed", result: false, errorCode: "provider_error")),
        ])
        do {
            _ = try await workflow(transport).run(audio, clientRequestId: "req-00000001")
            XCTFail("hata bekleniyordu")
        } catch {
            XCTAssertEqual(error as? WorkflowError, .jobFailed(errorCode: "provider_error"))
        }
    }

    func testBelirsizSaglayiciDurumuVeSuresiDolmusSonuc() async {
        do {
            _ = try await workflow(MockTransport([(200, Samples.jobWithResult("unknown_provider_state", result: false))]))
                .waitForResult(jobId: UUID(uuidString: Samples.jobId)!)
            XCTFail("hata bekleniyordu")
        } catch { XCTAssertEqual(error as? WorkflowError, .providerStateUnknown) }

        do {
            _ = try await workflow(MockTransport([(200, Samples.jobWithResult("succeeded", result: false))]))
                .waitForResult(jobId: UUID(uuidString: Samples.jobId)!)
            XCTFail("hata bekleniyordu")
        } catch { XCTAssertEqual(error as? WorkflowError, .resultUnavailable) }
    }

    func testZamanAsimiIsKimligiyleDoner() async {
        let jobId = UUID(uuidString: Samples.jobId)!
        let transport = MockTransport(Array(repeating: (200, Samples.jobWithResult("queued", result: false)), count: 10))
        let policy = PollingPolicy(initial: .seconds(2), max: .seconds(2), multiplier: 1, timeout: .seconds(5))
        let sleeper = SleepRecorder()
        do {
            _ = try await workflow(transport, sleeper: sleeper, policy: policy).waitForResult(jobId: jobId)
            XCTFail("hata bekleniyordu")
        } catch {
            XCTAssertEqual(error as? WorkflowError, .timedOut(jobId: jobId))
            XCTAssertEqual(sleeper.delays, [.seconds(2), .seconds(2)], "süre sınırı aşılmadan durur")
        }
    }

    func testKotaHatasiAkisiDurdurur() async {
        let transport = MockTransport([(402, Samples.error("insufficient_quota"))])
        do {
            _ = try await workflow(transport).run(audio, clientRequestId: "req-00000001")
            XCTFail("hata bekleniyordu")
        } catch {
            guard case .server(_, let code, _)? = error as? APIError else { return XCTFail("\(error)") }
            XCTAssertEqual(code, .insufficientQuota)
            XCTAssertEqual(transport.requests.count, 1, "yükleme denenmez")
        }
    }

    func testBeklemeAraligiUstSinirdaKalir() {
        let policy = PollingPolicy(initial: .seconds(1), max: .seconds(10), multiplier: 2)
        XCTAssertEqual(policy.delay(attempt: 0), .seconds(1))
        XCTAssertEqual(policy.delay(attempt: 3), .seconds(8))
        XCTAssertEqual(policy.delay(attempt: 10), .seconds(10))
    }
}
