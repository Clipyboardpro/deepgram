import SwiftUI

/// Giriş / kayıt formu. Sign in with Apple, Apple hesabı ve paket kimliği
/// kararlaştırılınca (K3) buraya eklenecek.
struct SignInView: View {
    @Environment(AccountModel.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var isSignUp = false
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("", selection: $isSignUp) {
                        Text("Giriş yap").tag(false)
                        Text("Hesap oluştur").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField("E-posta", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Şifre", text: $password)
                        .textContentType(isSignUp ? .newPassword : .password)
                } footer: {
                    Text("Otomatik altyazı için hesap gerekir. Projelerin yalnız bu cihazda kalır.")
                }
                if let message = account.message {
                    Section { Text(message).foregroundStyle(.secondary) }
                }
                Section {
                    Button {
                        Task {
                            let ok = isSignUp
                                ? await account.signUp(email: email, password: password)
                                : await account.signIn(email: email, password: password)
                            if ok { dismiss() }
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if account.isWorking { ProgressView() } else { Text(isSignUp ? "Hesap oluştur" : "Giriş yap").bold() }
                            Spacer()
                        }
                    }
                    .disabled(account.isWorking || !isValid)
                }
            }
            .navigationTitle(isSignUp ? "Hesap oluştur" : "Giriş yap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Kapat") { dismiss() } }
            }
            .onChange(of: isSignUp) { account.message = nil }
        }
    }

    private var isValid: Bool {
        email.contains("@") && password.count >= (isSignUp ? 8 : 1)
    }
}

/// Hesap bilgisi: e-posta, kalan AI süresi, çıkış.
struct AccountView: View {
    @Environment(AccountModel.self) private var account
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                switch account.state {
                case .unavailable:
                    Section {
                        Text("Sunucu ayarı eksik: otomatik altyazı bu derlemede kapalı.")
                            .foregroundStyle(.secondary)
                    }
                case .signedOut:
                    Section { Text("Oturum kapalı.").foregroundStyle(.secondary) }
                case let .signedIn(email):
                    Section("Hesap") {
                        LabeledContent("E-posta", value: email ?? "—")
                    }
                    Section("AI süresi") {
                        if let seconds = account.availableSeconds {
                            LabeledContent("Kalan", value: QuotaText.format(seconds))
                        } else {
                            LabeledContent("Kalan", value: "—")
                        }
                    }
                    Section {
                        Button("Çıkış yap", role: .destructive) {
                            Task { await account.signOut() }
                        }
                    }
                }
            }
            .navigationTitle("Hesap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Bitti") { dismiss() } }
            }
            .task { await account.refreshQuota() }
        }
    }
}

enum QuotaText {
    /// 754 → "12 dk 34 sn"
    static func format(_ seconds: Int) -> String {
        let minutes = seconds / 60, rest = seconds % 60
        if minutes == 0 { return "\(rest) sn" }
        return rest == 0 ? "\(minutes) dk" : "\(minutes) dk \(rest) sn"
    }
}
