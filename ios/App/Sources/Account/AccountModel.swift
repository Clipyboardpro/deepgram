import Foundation
import Observation
import AIJobsClient

/// Oturum ve AI kotası. Düzenleme yerel çalışır; giriş yalnız otomatik altyazı
/// gibi sunucu işleri için gerekir.
@MainActor
@Observable
final class AccountModel {
    enum State: Equatable {
        /// Sunucu ayarı (publishable anahtar) girilmemiş; AI özellikleri kapalı.
        case unavailable
        case signedOut
        case signedIn(email: String?)
    }

    private(set) var state: State
    /// En büyük dönem bakiyesi (tek işte kullanılabilecek saniye); nil = bilinmiyor.
    private(set) var availableSeconds: Int?
    private(set) var isWorking = false
    var message: String?

    private let manager: AuthSessionManager?
    let api: AIJobsClient?

    init(config: AppConfig?, store: SessionStore = KeychainSessionStore()) {
        guard let config else {
            state = .unavailable
            manager = nil
            api = nil
            return
        }
        let manager = AuthSessionManager(
            client: SupabaseAuthClient(projectURL: config.projectURL, publishableKey: config.publishableKey),
            store: store
        )
        self.manager = manager
        self.api = AIJobsClient(
            baseURL: config.apiURL,
            accessToken: { try await manager.validAccessToken() },
            refreshAccessToken: { try await manager.forceRefresh() }
        )
        state = .signedOut
        Task {
            await manager.observe { [weak self] session in
                Task { @MainActor in self?.sessionChanged(session) }
            }
        }
    }

    var isSignedIn: Bool {
        if case .signedIn = state { true } else { false }
    }

    func signIn(email: String, password: String) async -> Bool {
        await perform { try await $0.signIn(email: email, password: password) }
    }

    /// Kayıt; e-posta onayı gerekiyorsa kullanıcıya bildirilir ve false döner.
    func signUp(email: String, password: String) async -> Bool {
        await perform { manager in
            if case let .confirmationRequired(email) = try await manager.signUp(email: email, password: password) {
                throw Notice("\(email) adresine bir onay bağlantısı gönderildi. Onayladıktan sonra giriş yap.")
            }
        }
    }

    func signOut() async {
        await manager?.signOut()
    }

    /// Kotayı sunucudan okur. Giriş sonrası ücretsiz hakkı da bir kez ister.
    func refreshQuota(claimFree: Bool = false) async {
        guard let api, isSignedIn else { return }
        if claimFree {
            // Uç (CX-007) henüz yoksa ya da kullanıcı uygun değilse sessiz geçilir.
            _ = try? await api.claimFreeQuota()
        }
        availableSeconds = (try? await api.quota())?.maxSecondsForSingleJob
    }

    // MARK: - İç

    private struct Notice: Error { let text: String; init(_ text: String) { self.text = text } }

    private func perform(_ action: (AuthSessionManager) async throws -> Void) async -> Bool {
        guard let manager else { return false }
        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            try await action(manager)
            return true
        } catch let notice as Notice {
            message = notice.text
        } catch let error as AuthError {
            message = error.userMessage
        } catch {
            message = "Giriş yapılamadı. Tekrar dene."
        }
        return false
    }

    private func sessionChanged(_ session: AuthSession?) {
        let wasSignedIn = isSignedIn
        state = session.map { .signedIn(email: $0.email) } ?? .signedOut
        if session == nil {
            availableSeconds = nil
        } else if !wasSignedIn {
            Task { await refreshQuota(claimFree: true) }
        }
    }
}
