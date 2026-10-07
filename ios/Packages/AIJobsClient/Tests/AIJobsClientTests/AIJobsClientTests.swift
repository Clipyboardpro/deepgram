import XCTest
@testable import AIJobsClient

final class AIJobsClientTests: XCTestCase {
    private func client(_ transport: MockTransport) -> AIJobsClient {
        AIJobsClient(baseURL: Samples.base, transport: transport, accessToken: { "jwt-123" })
    }

    private let request = CreateJobRequest(clientRequestId: "req-00000001", language: "tr", audioSha256: Samples.sha, audioBytes: 2048, durationSeconds: 61)

    func testIsOlusturmaIstegiSozlesmeyeUyar() async throws {
        let transport = MockTransport([(200, Samples.created())])
        let response = try await client(transport).createJob(request)

        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.url.absoluteString, "https://proje.supabase.co/functions/v1/api/v1/transcription-jobs")
        XCTAssertEqual(sent.headers["Authorization"], "Bearer jwt-123")
        XCTAssertEqual(sent.headers["Content-Type"], "application/json")
        XCTAssertEqual(Set(sent.json?.keys ?? [:].keys), ["clientRequestId", "language", "audioSha256", "audioBytes", "durationSeconds"],
                       "sunucu ek alanı reddeder; yalnız sözleşmedeki alanlar")
        XCTAssertEqual(sent.json?["durationSeconds"] as? Int, 61)

        XCTAssertEqual(response.job.id.uuidString.lowercased(), Samples.jobId)
        XCTAssertEqual(response.job.status, .awaitingUpload)
        XCTAssertEqual(response.upload?.method, "PUT")
        XCTAssertEqual(response.upload?.headers, ["Content-Type": "audio/mp4"])
    }

    func testMikroSaniyeliPostgresTarihiCozulur() async throws {
        let response = try await client(MockTransport([(200, Samples.created())])).createJob(request)
        let expected = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-07T12:42:01Z")).addingTimeInterval(0.123)
        XCTAssertEqual(response.job.createdAt.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
    }

    func testYuklemeGerekmiyorsaUploadNil() async throws {
        let response = try await client(MockTransport([(200, Samples.created(upload: false, status: "queued"))])).createJob(request)
        XCTAssertNil(response.upload)
        XCTAssertEqual(response.job.status, .queued)
    }

    func testIsIdsiKucukHarfleYolaEklenir() async throws {
        let transport = MockTransport([(200, #"{"job":\#(Samples.job("queued"))}"#)])
        _ = try await client(transport).markUploaded(jobId: try XCTUnwrap(UUID(uuidString: Samples.jobId)))
        XCTAssertEqual(transport.requests.first?.url.path, "/functions/v1/api/v1/transcription-jobs/\(Samples.jobId)/uploaded")
        XCTAssertNil(transport.requests.first?.body, "uploaded gövdesizdir")
    }

    func testSonucluIsTranscriptVerir() async throws {
        let transport = MockTransport([(200, Samples.jobWithResult("succeeded", result: true))])
        let response = try await client(transport).job(id: try XCTUnwrap(UUID(uuidString: Samples.jobId)))
        XCTAssertEqual(transport.requests.first?.method, "GET")
        XCTAssertEqual(response.result?.transcript.words.first?.display, "Merhaba,")
    }

    func testKotaEnBuyukDonemBakiyesi() async throws {
        let body = #"{"periods":[{"id":"\#(Samples.jobId)","source":"subscription","startsAt":"2026-10-01T00:00:00Z","endsAt":"2026-11-01T00:00:00Z","grantedSeconds":600,"usedSeconds":100,"reservedSeconds":60,"availableSeconds":440},{"id":"\#(Samples.jobId)","source":"topup","startsAt":"2026-10-01T00:00:00Z","endsAt":"2026-10-03T00:00:00Z","grantedSeconds":100,"usedSeconds":0,"reservedSeconds":0,"availableSeconds":100}]}"#
        let quota = try await client(MockTransport([(200, body)])).quota()
        XCTAssertEqual(quota.maxSecondsForSingleJob, 440, "rezervasyon dönemlere bölünmez: toplam değil en büyük")
    }

    // MARK: - Yükleme

    func testYuklemeImzaliAdreseOturumAnahtarsizGider() async throws {
        let transport = MockTransport([(200, "{}")])
        let upload = try JSONDecoder.api.decode(Upload.self, from: Data(Samples.upload.utf8))
        try await client(transport).upload(Data([1, 2, 3]), to: upload)

        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.method, "PUT")
        XCTAssertEqual(sent.url, upload.url)
        XCTAssertEqual(sent.headers["Content-Type"], "audio/mp4")
        XCTAssertNil(sent.headers["Authorization"], "imzalı adrese oturum anahtarı sızdırılmaz")
        XCTAssertEqual(sent.body, Data([1, 2, 3]))
    }

    func testYuklemeHatasi() async throws {
        let upload = try JSONDecoder.api.decode(Upload.self, from: Data(Samples.upload.utf8))
        do {
            try await client(MockTransport([(400, "{}")])).upload(Data(), to: upload)
            XCTFail("hata bekleniyordu")
        } catch {
            XCTAssertEqual(error as? APIError, .uploadFailed(status: 400))
        }
    }

    // MARK: - Hata eşleme

    func testSunucuHataKoduTipliHataOlur() async {
        do {
            _ = try await client(MockTransport([(402, Samples.error("insufficient_quota"))])).createJob(request)
            XCTFail("hata bekleniyordu")
        } catch let error as APIError {
            XCTAssertEqual(error, .server(status: 402, code: .insufficientQuota, requestId: "0b8e5c1a-1111-4222-8333-944455556666"))
            XCTAssertFalse(error.isRetryable)
            XCTAssertEqual(error.userMessage, "AI dakikan yetersiz.")
        } catch {
            XCTFail("beklenmeyen hata: \(error)")
        }
    }

    func testBilinmeyenKodVeSozlesmeDisiGovde() async {
        do {
            _ = try await client(MockTransport([(500, Samples.error("yeni_bir_kod"))])).quota()
        } catch let error as APIError {
            XCTAssertEqual(error, .server(status: 500, code: .unknown("yeni_bir_kod"), requestId: "0b8e5c1a-1111-4222-8333-944455556666"))
            XCTAssertTrue(error.isRetryable)
        } catch { XCTFail("\(error)") }

        do {
            _ = try await client(MockTransport([(502, "<html>Bad Gateway</html>")])).quota()
        } catch let error as APIError {
            XCTAssertEqual(error, .unexpectedStatus(502))
            XCTAssertTrue(error.isRetryable)
        } catch { XCTFail("\(error)") }
    }

    func testAgHatasiTransportOlur() async {
        do {
            _ = try await client(MockTransport([])).quota()
            XCTFail("hata bekleniyordu")
        } catch let error as APIError {
            guard case .transport = error else { return XCTFail("\(error)") }
            XCTAssertTrue(error.isRetryable)
        } catch { XCTFail("\(error)") }
    }

    func testBozukBasariliYanitInvalidResponse() async {
        do {
            _ = try await client(MockTransport([(200, #"{"beklenmeyen":true}"#)])).quota()
            XCTFail("hata bekleniyordu")
        } catch {
            XCTAssertEqual(error as? APIError, .invalidResponse)
        }
    }

    func testBilinmeyenIsDurumuCokertmez() async throws {
        let body = #"{"job":\#(Samples.job("yeni_durum")),"result":null}"#
        let response = try await client(MockTransport([(200, body)])).job(id: try XCTUnwrap(UUID(uuidString: Samples.jobId)))
        XCTAssertEqual(response.job.status, .other("yeni_durum"))
        XCTAssertFalse(response.job.status.isTerminal)
    }
}
