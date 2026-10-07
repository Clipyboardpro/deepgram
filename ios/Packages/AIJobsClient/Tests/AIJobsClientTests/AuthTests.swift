import XCTest
@testable import AIJobsClient

final class AuthTests: XCTestCase {
    private let project = URL(string: "https://proje.supabase.co")!
    private let userId = "11111111-2222-4333-8444-555555555555"
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func client(_ transport: MockTransport, now: Date? = nil) -> SupabaseAuthClient {
        let fixed = now ?? start
        return SupabaseAuthClient(projectURL: project, publishableKey: "pk-test", transport: transport, now: { fixed })
    }

    private func tokenBody(access: String = "acc-1", refresh: String = "ref-1", expiresIn: Int = 3600, expiresAt: Int? = nil) -> String {
        let at = expiresAt.map { #","expires_at":\#($0)"# } ?? ""
        return #"{"access_token":"\#(access)","token_type":"bearer","expires_in":\#(expiresIn)\#(at),"refresh_token":"\#(refresh)","user":{"id":"\#(userId)","email":"eymen@example.com"}}"#
    }

    // MARK: - SupabaseAuthClient

    func testSifreyleGirisIstegiVeOturum() async throws {
        let transport = MockTransport([(200, tokenBody(expiresAt: 1_800_003_600))])
        let session = try await client(transport).signIn(email: "eymen@example.com", password: "gizli-sifre")

        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.url.absoluteString, "https://proje.supabase.co/auth/v1/token?grant_type=password")
        XCTAssertEqual(sent.header("apikey"), "pk-test")
        XCTAssertNil(sent.header("Authorization"), "girişte oturum anahtarı yok")
        XCTAssertEqual(sent.json?["email"] as? String, "eymen@example.com")

        XCTAssertEqual(session.accessToken, "acc-1")
        XCTAssertEqual(session.refreshToken, "ref-1")
        XCTAssertEqual(session.userId.uuidString.lowercased(), userId)
        XCTAssertEqual(session.expiresAt, Date(timeIntervalSince1970: 1_800_003_600), "expires_at varsa o kullanılır")
    }

    func testExpiresAtYoksaExpiresInKullanilir() async throws {
        let session = try await client(MockTransport([(200, tokenBody(expiresIn: 600))])).signIn(email: "a@b.c", password: "x")
        XCTAssertEqual(session.expiresAt, start.addingTimeInterval(600))
    }

    func testAppleIleGirisIdTokenGonderir() async throws {
        let transport = MockTransport([(200, tokenBody())])
        _ = try await client(transport).signInWithApple(idToken: "apple-jwt", nonce: "ham-nonce")
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.url.query, "grant_type=id_token")
        XCTAssertEqual(sent.json?["provider"] as? String, "apple")
        XCTAssertEqual(sent.json?["id_token"] as? String, "apple-jwt")
        XCTAssertEqual(sent.json?["nonce"] as? String, "ham-nonce")
    }

    func testKayitOnayGerekiyorsaOturumYok() async throws {
        let userOnly = #"{"id":"\#(userId)","email":"yeni@example.com","confirmation_sent_at":"2026-10-07T12:00:00Z"}"#
        let result = try await client(MockTransport([(200, userOnly)])).signUp(email: "yeni@example.com", password: "uzun-sifre-1")
        XCTAssertEqual(result, .confirmationRequired(email: "yeni@example.com"))
    }

    func testKayitOnaySizsaDogrudanOturum() async throws {
        let result = try await client(MockTransport([(200, tokenBody())])).signUp(email: "yeni@example.com", password: "uzun-sifre-1")
        guard case let .signedIn(session) = result else { return XCTFail("oturum bekleniyordu") }
        XCTAssertEqual(session.accessToken, "acc-1")
    }

    func testHataKodlariEslenir() {
        func map(_ status: Int, _ body: String) -> AuthError { SupabaseAuthClient.error(status: status, body: Data(body.utf8)) }
        XCTAssertEqual(map(400, #"{"code":400,"error_code":"invalid_credentials","msg":"Invalid login credentials"}"#), .invalidCredentials)
        XCTAssertEqual(map(400, #"{"error":"invalid_grant","error_description":"Invalid login credentials"}"#), .invalidCredentials)
        XCTAssertEqual(map(400, #"{"error":"invalid_grant","error_description":"Email not confirmed"}"#), .emailNotConfirmed)
        XCTAssertEqual(map(400, #"{"error_code":"email_not_confirmed"}"#), .emailNotConfirmed)
        XCTAssertEqual(map(422, #"{"code":422,"error_code":"user_already_exists","msg":"User already registered"}"#), .userAlreadyExists)
        XCTAssertEqual(map(422, #"{"error_code":"weak_password"}"#), .weakPassword)
        XCTAssertEqual(map(429, #"{"error_code":"over_request_rate_limit"}"#), .rateLimited)
        XCTAssertEqual(map(429, "<html>"), .rateLimited)
        XCTAssertEqual(map(400, #"{"error_code":"refresh_token_not_found"}"#), .signedOut)
        XCTAssertEqual(map(500, "oops"), .server(status: 500, code: nil))
    }

    func testAgHatasiTransportOlur() async {
        do {
            _ = try await client(MockTransport([])).signIn(email: "a@b.c", password: "x")
            XCTFail("hata bekleniyordu")
        } catch let error as AuthError {
            guard case .transport = error else { return XCTFail("\(error)") }
            XCTAssertEqual(error.userMessage, "İnternet bağlantısını kontrol et.")
        } catch {
            XCTFail("\(error)")
        }
    }

    // MARK: - AuthSessionManager

    private func session(expiresIn seconds: TimeInterval, refresh: String = "ref-1") -> AuthSession {
        AuthSession(accessToken: "acc-eski", refreshToken: refresh, expiresAt: start.addingTimeInterval(seconds),
                    userId: UUID(uuidString: userId)!, email: "eymen@example.com")
    }

    func testGecerliAnahtarYenilenmez() async throws {
        let transport = MockTransport([])
        let manager = AuthSessionManager(client: client(transport), store: InMemorySessionStore(session(expiresIn: 600)),
                                         now: { [start] in start })
        let token = try await manager.validAccessToken()
        XCTAssertEqual(token, "acc-eski")
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testSuresiDolmakUzereyseYenilenirVeSaklanir() async throws {
        let transport = MockTransport([(200, tokenBody(access: "acc-yeni", refresh: "ref-2"))])
        let store = InMemorySessionStore(session(expiresIn: 30))
        let manager = AuthSessionManager(client: client(transport), store: store, now: { [start] in start })

        let token = try await manager.validAccessToken()
        XCTAssertEqual(token, "acc-yeni")
        XCTAssertEqual(transport.requests.first?.url.query, "grant_type=refresh_token")
        XCTAssertEqual(transport.requests.first?.json?["refresh_token"] as? String, "ref-1")
        XCTAssertEqual(try store.load()?.refreshToken, "ref-2", "yeni yenileme anahtarı kalıcı")
    }

    func testEszamanliYenilemelerTekIstegeBirlesir() async throws {
        let transport = MockTransport([(200, tokenBody(access: "acc-yeni", refresh: "ref-2"))])
        let manager = AuthSessionManager(client: client(transport), store: InMemorySessionStore(session(expiresIn: 0)),
                                         now: { [start] in start })
        async let a = manager.validAccessToken()
        async let b = manager.validAccessToken()
        async let c = manager.forceRefresh()
        let tokens = try await [a, b, c]
        XCTAssertEqual(tokens, ["acc-yeni", "acc-yeni", "acc-yeni"])
        XCTAssertEqual(transport.requests.count, 1, "yenileme anahtarı tek kullanımlık; tek istek")
    }

    func testYenilemeReddedilirseOturumKapanir() async throws {
        let transport = MockTransport([(400, #"{"error_code":"refresh_token_already_used"}"#)])
        let store = InMemorySessionStore(session(expiresIn: 0))
        let manager = AuthSessionManager(client: client(transport), store: store, now: { [start] in start })
        do {
            _ = try await manager.validAccessToken()
            XCTFail("hata bekleniyordu")
        } catch {
            XCTAssertEqual(error as? AuthError, .signedOut)
        }
        let current = await manager.current
        XCTAssertNil(current)
        XCTAssertNil(try store.load())
    }

    func testAgHatasindaOturumKorunur() async throws {
        let store = InMemorySessionStore(session(expiresIn: 0))
        let manager = AuthSessionManager(client: client(MockTransport([])), store: store, now: { [start] in start })
        do {
            _ = try await manager.validAccessToken()
            XCTFail("hata bekleniyordu")
        } catch {
            guard case .transport = error as? AuthError else { return XCTFail("\(error)") }
        }
        XCTAssertNotNil(try store.load(), "geçici ağ hatası kullanıcıyı çıkış yaptırmaz")
    }

    func testCikisYerelOturumuSilerVeSunucuyaBildirir() async throws {
        let transport = MockTransport([(204, "")])
        let store = InMemorySessionStore(session(expiresIn: 600))
        let manager = AuthSessionManager(client: client(transport), store: store, now: { [start] in start })
        await manager.signOut()
        XCTAssertNil(try store.load())
        XCTAssertEqual(transport.requests.first?.url.path, "/auth/v1/logout")
        XCTAssertEqual(transport.requests.first?.header("Authorization"), "Bearer acc-eski")
        do {
            _ = try await manager.validAccessToken()
            XCTFail("hata bekleniyordu")
        } catch {
            XCTAssertEqual(error as? AuthError, .signedOut)
        }
    }

    func testOturumDegisikligiBildirilir() async throws {
        let transport = MockTransport([(200, tokenBody())])
        let manager = AuthSessionManager(client: client(transport), store: InMemorySessionStore(), now: { [start] in start })
        let seen = Box()
        await manager.observe { seen.append($0?.email) }
        try await manager.signIn(email: "eymen@example.com", password: "x")
        await manager.signOut()
        XCTAssertEqual(seen.values, [nil, "eymen@example.com", nil])
    }

    // MARK: - API istemcisiyle birlikte

    func test401deBirKezYenileyipTekrarDener() async throws {
        let transport = MockTransport([
            (401, Samples.error("not_authenticated")),
            (200, #"{"periods":[]}"#),
        ])
        let api = AIJobsClient(baseURL: Samples.base, transport: transport,
                               accessToken: { "eski" }, refreshAccessToken: { "yeni" })
        _ = try await api.quota()
        XCTAssertEqual(transport.requests.map { $0.header("Authorization") }, ["Bearer eski", "Bearer yeni"])
    }

    func testIkinci401HataOlarakDoner() async throws {
        let transport = MockTransport([
            (401, Samples.error("not_authenticated")),
            (401, Samples.error("not_authenticated")),
        ])
        let api = AIJobsClient(baseURL: Samples.base, transport: transport,
                               accessToken: { "eski" }, refreshAccessToken: { "yeni" })
        do {
            _ = try await api.quota()
            XCTFail("hata bekleniyordu")
        } catch {
            XCTAssertEqual(error as? APIError, .server(status: 401, code: .notAuthenticated, requestId: "0b8e5c1a-1111-4222-8333-944455556666"))
        }
        XCTAssertEqual(transport.requests.count, 2, "sonsuz döngü yok")
    }

    func testUcretsizKotaIstegi() async throws {
        let transport = MockTransport([(200, #"{"granted":true}"#), (200, #"{"granted":false}"#)])
        let api = AIJobsClient(baseURL: Samples.base, transport: transport, accessToken: { "jwt" })
        let first = try await api.claimFreeQuota()
        let second = try await api.claimFreeQuota()
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertEqual(transport.requests.first?.method, "POST")
        XCTAssertEqual(transport.requests.first?.url.path, "/functions/v1/api/v1/quota/free-claim")
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String?] = []
    var values: [String?] { lock.withLock { storage } }
    func append(_ value: String?) { lock.withLock { storage.append(value) } }
}
