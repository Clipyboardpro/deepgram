import Foundation

/// Info.plist'e xcconfig'ten gelen sunucu ayarları (Config/App.xcconfig).
struct AppConfig {
    let projectURL: URL
    let apiURL: URL
    let publishableKey: String

    /// Anahtar girilmemişse nil: uygulama çalışır, yalnız giriş/AI kapalı kalır.
    static func load(from bundle: Bundle = .main) -> AppConfig? {
        guard let ref = bundle.object(forInfoDictionaryKey: "SupabaseProjectRef") as? String,
              let key = bundle.object(forInfoDictionaryKey: "SupabasePublishableKey") as? String,
              !ref.isEmpty, !key.isEmpty, !ref.hasPrefix("$("), !key.hasPrefix("$("),
              let project = URL(string: "https://\(ref).supabase.co")
        else { return nil }
        return AppConfig(projectURL: project,
                         apiURL: project.appendingPathComponent("functions/v1/api"),
                         publishableKey: key)
    }
}
