import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Supabase Auth oturumu. Erişim anahtarı kısa ömürlüdür; yenileme anahtarıyla
/// yenilenir. Anahtarlar yalnız güvenli depoda (Keychain) saklanır, günlüğe yazılmaz.
public struct AuthSession: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var userId: UUID
    public var email: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Date, userId: UUID, email: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.userId = userId
        self.email = email
    }
}

public enum SignUpResult: Equatable, Sendable {
    case signedIn(AuthSession)
    /// Projede e-posta onayı açık: kullanıcı e-postadaki bağlantıya tıklayıp
    /// sonra giriş yapmalı.
    case confirmationRequired(email: String)
}

public enum AuthError: Error, Equatable, Sendable {
    case invalidCredentials
    case emailNotConfirmed
    case userAlreadyExists
    case weakPassword
    case rateLimited
    /// Oturum yok ya da yenilenemedi (çıkış yapılmış, yenileme anahtarı geçersiz).
    case signedOut
    case server(status: Int, code: String?)
    case invalidResponse
    case transport(String)

    public var userMessage: String {
        switch self {
        case .invalidCredentials: "E-posta ya da şifre hatalı."
        case .emailNotConfirmed: "E-posta adresini onaylaman gerekiyor. Gelen kutunu kontrol et."
        case .userAlreadyExists: "Bu e-postayla bir hesap zaten var. Giriş yapmayı dene."
        case .weakPassword: "Şifre çok zayıf. En az 8 karakter kullan."
        case .rateLimited: "Çok fazla deneme yapıldı. Biraz sonra tekrar dene."
        case .signedOut: "Oturumun sona ermiş. Lütfen tekrar giriş yap."
        case .transport: "İnternet bağlantısını kontrol et."
        case .server, .invalidResponse: "Giriş yapılamadı. Tekrar dene."
        }
    }
}

/// Supabase Auth (GoTrue) REST istemcisi. Yalnız herkese açık (publishable/anon)
/// anahtarı kullanır; service_role anahtarı asla istemciye konmaz.
public struct SupabaseAuthClient: Sendable {
    public let projectURL: URL
    private let publishableKey: String
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date

    /// - Parameter projectURL: Proje kökü, ör. `https://<proje>.supabase.co`.
    public init(projectURL: URL, publishableKey: String, transport: HTTPTransport = URLSessionTransport(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.projectURL = projectURL
        self.publishableKey = publishableKey
        self.transport = transport
        self.now = now
    }

    public func signIn(email: String, password: String) async throws -> AuthSession {
        try await token(grantType: "password", body: ["email": email, "password": password])
    }

    /// Apple ile giriş: AuthenticationServices'ten gelen kimlik belirteci ve
    /// isteği başlatırken üretilen ham nonce (Apple'a SHA-256'sı verilir).
    public func signInWithApple(idToken: String, nonce: String) async throws -> AuthSession {
        try await token(grantType: "id_token", body: ["provider": "apple", "id_token": idToken, "nonce": nonce])
    }

    public func refresh(refreshToken: String) async throws -> AuthSession {
        do {
            return try await token(grantType: "refresh_token", body: ["refresh_token": refreshToken])
        } catch AuthError.invalidCredentials, AuthError.server(400, _), AuthError.server(401, _) {
            throw AuthError.signedOut
        }
    }

    public func signUp(email: String, password: String) async throws -> SignUpResult {
        let data = try await post("auth/v1/signup", query: nil, body: ["email": email, "password": password], accessToken: nil)
        if let session = try? decodeSession(data) {
            return .signedIn(session)
        }
        // Onay açıkken yanıt yalnız kullanıcı nesnesidir, oturum yoktur.
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { throw AuthError.invalidResponse }
        return .confirmationRequired(email: email)
    }

    /// Sunucudaki yenileme anahtarını geçersiz kılar. Hata yerel çıkışı engellemez.
    public func signOut(accessToken: String) async {
        _ = try? await post("auth/v1/logout", query: nil, body: [:], accessToken: accessToken)
    }

    // MARK: - İç

    private func token(grantType: String, body: [String: String]) async throws -> AuthSession {
        let data = try await post("auth/v1/token", query: "grant_type=\(grantType)", body: body, accessToken: nil)
        return try decodeSession(data)
    }

    private struct TokenResponse: Decodable {
        struct User: Decodable { var id: UUID; var email: String? }
        var access_token: String
        var refresh_token: String
        var expires_in: Double?
        var expires_at: Double?
        var user: User
    }

    func decodeSession(_ data: Data) throws -> AuthSession {
        guard let raw = try? JSONDecoder().decode(TokenResponse.self, from: data) else { throw AuthError.invalidResponse }
        let expiresAt: Date
        if let at = raw.expires_at {
            expiresAt = Date(timeIntervalSince1970: at)
        } else if let inSeconds = raw.expires_in {
            expiresAt = now().addingTimeInterval(inSeconds)
        } else {
            throw AuthError.invalidResponse
        }
        return AuthSession(accessToken: raw.access_token, refreshToken: raw.refresh_token,
                           expiresAt: expiresAt, userId: raw.user.id, email: raw.user.email)
    }

    private func post(_ path: String, query: String?, body: [String: String], accessToken: String?) async throws -> Data {
        var components = URLComponents(url: projectURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.query = query
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AuthError.transport(String(describing: error))
        }
        guard (200..<300).contains(response.statusCode) else {
            throw Self.error(status: response.statusCode, body: data)
        }
        return data
    }

    /// GoTrue hata gövdeleri iki biçimde gelir: yeni `{"code":400,"error_code":"...","msg":"..."}`
    /// ve eski `{"error":"invalid_grant","error_description":"..."}`.
    static func error(status: Int, body: Data) -> AuthError {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let code = json["error_code"] as? String ?? json["code"] as? String ?? json["error"] as? String
        let description = (json["error_description"] as? String ?? json["msg"] as? String ?? "").lowercased()

        switch code {
        case "invalid_credentials": return .invalidCredentials
        case "email_not_confirmed": return .emailNotConfirmed
        case "user_already_exists", "email_exists": return .userAlreadyExists
        case "weak_password": return .weakPassword
        case "over_request_rate_limit", "over_email_send_rate_limit": return .rateLimited
        case "refresh_token_not_found", "refresh_token_already_used", "session_not_found", "session_expired":
            return .signedOut
        case "invalid_grant":
            if description.contains("email not confirmed") { return .emailNotConfirmed }
            if description.contains("refresh token") { return .signedOut }
            return .invalidCredentials
        default:
            if status == 429 { return .rateLimited }
            return .server(status: status, code: code)
        }
    }
}

/// Oturumun kalıcı saklandığı yer. Uygulamada Keychain, testlerde bellek.
public protocol SessionStore: Sendable {
    func load() throws -> AuthSession?
    func save(_ session: AuthSession) throws
    func clear() throws
}

/// Geçerli oturumu tutar ve süresi dolmak üzere olan erişim anahtarını yeniler.
/// Aynı anda gelen yenileme istekleri tek bir ağ çağrısında birleşir (Supabase
/// yenileme anahtarını tek kullanımlık yapar; iki paralel yenileme oturumu düşürür).
public actor AuthSessionManager {
    private let client: SupabaseAuthClient
    private let store: SessionStore
    private let now: @Sendable () -> Date
    private let refreshMargin: TimeInterval
    private var session: AuthSession?
    private var refreshTask: Task<AuthSession, Error>?
    private var onChange: (@Sendable (AuthSession?) -> Void)?

    public init(client: SupabaseAuthClient, store: SessionStore, refreshMargin: TimeInterval = 60,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.store = store
        self.now = now
        self.refreshMargin = refreshMargin
        self.session = try? store.load()
    }

    /// Oturum değiştiğinde (giriş, yenileme, çıkış) çağrılır; arayüz durumu için.
    public func observe(_ handler: @escaping @Sendable (AuthSession?) -> Void) {
        onChange = handler
        handler(session)
    }

    public var current: AuthSession? { session }

    public func signIn(email: String, password: String) async throws {
        set(try await client.signIn(email: email, password: password))
    }

    public func signInWithApple(idToken: String, nonce: String) async throws {
        set(try await client.signInWithApple(idToken: idToken, nonce: nonce))
    }

    public func signUp(email: String, password: String) async throws -> SignUpResult {
        let result = try await client.signUp(email: email, password: password)
        if case let .signedIn(session) = result { set(session) }
        return result
    }

    public func signOut() async {
        let token = session?.accessToken
        refreshTask?.cancel()
        refreshTask = nil
        set(nil)
        if let token { await client.signOut(accessToken: token) }
    }

    /// API çağrıları için geçerli erişim anahtarı; gerekirse yeniler.
    public func validAccessToken() async throws -> String {
        guard let session else { throw AuthError.signedOut }
        if session.expiresAt.timeIntervalSince(now()) > refreshMargin {
            return session.accessToken
        }
        return try await refreshed(from: session).accessToken
    }

    /// Sunucu 401 döndüğünde süre dolmamış görünse bile yenilemeyi zorlar.
    public func forceRefresh() async throws -> String {
        guard let session else { throw AuthError.signedOut }
        return try await refreshed(from: session).accessToken
    }

    private func refreshed(from old: AuthSession) async throws -> AuthSession {
        if let refreshTask { return try await refreshTask.value }
        let task = Task { [client] in try await client.refresh(refreshToken: old.refreshToken) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let fresh = try await task.value
            // Bu arada çıkış yapıldıysa yenilenen oturum geri getirilmez.
            guard session?.refreshToken == old.refreshToken else { throw AuthError.signedOut }
            set(fresh)
            return fresh
        } catch AuthError.signedOut {
            if session?.refreshToken == old.refreshToken { set(nil) }
            throw AuthError.signedOut
        }
    }

    private func set(_ new: AuthSession?) {
        session = new
        if let new { try? store.save(new) } else { try? store.clear() }
        onChange?(new)
    }
}

/// Testler ve önizleme için bellek içi depo.
public final class InMemorySessionStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: AuthSession?

    public init(_ session: AuthSession? = nil) { value = session }

    public func load() throws -> AuthSession? { lock.withLock { value } }
    public func save(_ session: AuthSession) throws { lock.withLock { value = session } }
    public func clear() throws { lock.withLock { value = nil } }
}
