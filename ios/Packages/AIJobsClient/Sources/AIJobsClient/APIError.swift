import Foundation

/// Sunucunun `{"error":{"code","requestId"}}` gövdesindeki kodlar
/// (contracts/openapi.yaml → Error). Bilinmeyen kod `.unknown` olur.
public enum APIErrorCode: Equatable, Sendable {
    case notAuthenticated, invalidRequest, unsupportedMediaType, requestTooLarge, notFound
    case insufficientQuota, rateLimited, audioTooLong, audioTooLarge
    case aiJobsDisabled, dailyBudgetExceeded, priceNotConfigured
    case clientRequestIdReused, uploadExpired, jobNotCancelable, jobNotFound, profileNotFound
    case invalidDuration, invalidSeconds, uploadNotFound, uploadMetadataMismatch
    case storageUnavailable, internalError
    case unknown(String)

    private static let table: [String: APIErrorCode] = [
        "not_authenticated": .notAuthenticated, "invalid_request": .invalidRequest,
        "unsupported_media_type": .unsupportedMediaType, "request_too_large": .requestTooLarge,
        "not_found": .notFound, "insufficient_quota": .insufficientQuota, "rate_limited": .rateLimited,
        "audio_too_long": .audioTooLong, "audio_too_large": .audioTooLarge,
        "ai_jobs_disabled": .aiJobsDisabled, "daily_budget_exceeded": .dailyBudgetExceeded,
        "price_not_configured": .priceNotConfigured, "client_request_id_reused": .clientRequestIdReused,
        "upload_expired": .uploadExpired, "job_not_cancelable": .jobNotCancelable,
        "job_not_found": .jobNotFound, "profile_not_found": .profileNotFound,
        "invalid_duration": .invalidDuration, "invalid_seconds": .invalidSeconds,
        "upload_not_found": .uploadNotFound, "upload_metadata_mismatch": .uploadMetadataMismatch,
        "storage_unavailable": .storageUnavailable, "internal_error": .internalError,
    ]

    public init(rawValue: String) {
        self = Self.table[rawValue] ?? .unknown(rawValue)
    }
}

public enum APIError: Error, Equatable, Sendable {
    /// Sunucu sözleşmeye uygun hata gövdesi döndü.
    case server(status: Int, code: APIErrorCode, requestId: String?)
    /// Gövde sözleşmeye uymayan HTTP hatası (ör. ağ geçidinden gelen 502).
    case unexpectedStatus(Int)
    /// Başarılı yanıt sözleşmedeki biçimde değil.
    case invalidResponse
    /// İmzalı adrese yükleme başarısız.
    case uploadFailed(status: Int)
    /// Ağ hatası (bağlantı yok, zaman aşımı...). Açıklama yalnız günlük için.
    case transport(String)

    /// Aynı istek bir süre sonra tekrar denenebilir mi? Kota, süre gibi
    /// kullanıcının düzeltmesi gereken hatalar tekrar denenmez.
    public var isRetryable: Bool {
        switch self {
        case .transport: true
        case .unexpectedStatus(let status): status >= 500 || status == 429
        case .uploadFailed(let status): status >= 500 || status == 429
        case .server(let status, let code, _):
            switch code {
            case .rateLimited, .storageUnavailable, .internalError: true
            case .unknown: status >= 500
            default: false
            }
        case .invalidResponse: false
        }
    }

    /// Kullanıcıya gösterilecek kısa Türkçe açıklama. Ayrıntı ve requestId
    /// yalnız destek/günlük içindir.
    public var userMessage: String {
        switch self {
        case .server(_, let code, _):
            switch code {
            case .notAuthenticated: "Oturumun sona ermiş. Lütfen tekrar giriş yap."
            case .insufficientQuota: "AI dakikan yetersiz."
            case .rateLimited: "Kısa sürede çok fazla istek gönderildi. Biraz sonra tekrar dene."
            case .audioTooLong: "Video, otomatik altyazı için çok uzun."
            case .audioTooLarge: "Ses dosyası çok büyük."
            case .aiJobsDisabled, .dailyBudgetExceeded, .priceNotConfigured:
                "Otomatik altyazı şu an kullanılamıyor. Daha sonra tekrar dene."
            case .uploadExpired: "Yükleme süresi doldu. İşlemi yeniden başlat."
            case .jobNotCancelable: "İşlem başladığı için iptal edilemiyor."
            default: "Bir sorun oluştu. Tekrar dene."
            }
        case .transport: "İnternet bağlantısını kontrol et."
        default: "Bir sorun oluştu. Tekrar dene."
        }
    }
}
