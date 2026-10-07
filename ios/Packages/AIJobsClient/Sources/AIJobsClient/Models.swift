import Foundation
import EditorDomain

// Sözleşme: contracts/openapi.yaml → components/schemas. Alan adları birebir.

public struct CreateJobRequest: Equatable, Sendable, Encodable {
    /// Kullanıcı başına idempotency anahtarı (8–128 karakter). Uygulama bunu
    /// iş başlamadan önce kalıcı olarak saklar; yeniden denemede aynısını yollar.
    public var clientRequestId: String
    public var language: String
    /// Yüklenecek ses dosyasının küçük harfli SHA-256 özeti (64 hex).
    public var audioSha256: String
    public var audioBytes: Int
    /// Yukarı yuvarlanmış tam saniye.
    public var durationSeconds: Int

    public init(clientRequestId: String, language: String, audioSha256: String, audioBytes: Int, durationSeconds: Int) {
        self.clientRequestId = clientRequestId
        self.language = language
        self.audioSha256 = audioSha256
        self.audioBytes = audioBytes
        self.durationSeconds = durationSeconds
    }
}

public enum JobStatus: Equatable, Sendable, Decodable {
    case awaitingUpload, queued, submitted, processing, succeeded, failed, canceled, unknownProviderState
    /// Sözleşmeye sonradan eklenen bir durum: uygulama çökmez, beklemeye devam eder.
    case other(String)

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "awaiting_upload": self = .awaitingUpload
        case "queued": self = .queued
        case "submitted": self = .submitted
        case "processing": self = .processing
        case "succeeded": self = .succeeded
        case "failed": self = .failed
        case "canceled": self = .canceled
        case "unknown_provider_state": self = .unknownProviderState
        default: self = .other(raw)
        }
    }

    /// Bu durumdan sonra iş kendiliğinden değişmez.
    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .canceled, .unknownProviderState: true
        default: false
        }
    }
}

public struct Job: Equatable, Sendable, Decodable {
    public var id: UUID
    public var status: JobStatus
    public var createdAt: Date
    public var errorCode: String?
}

public struct Upload: Equatable, Sendable, Decodable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var expiresAt: Date
}

public struct CreateJobResponse: Equatable, Sendable, Decodable {
    public var job: Job
    /// Yükleme gerekmiyorsa (iş zaten yüklenmiş/ilerlemiş) nil.
    public var upload: Upload?
}

public struct JobResult: Equatable, Sendable, Decodable {
    /// Zamanlar yüklenen sesin başına göre; kaynak medyaya çevirmek için
    /// `CaptionTrack.make(from:mediaId:audioSourceStart:)`.
    public var transcript: Transcript
    public var expiresAt: Date
}

public struct JobWithResult: Equatable, Sendable, Decodable {
    public var job: Job
    public var result: JobResult?
}

struct JobEnvelope: Decodable {
    var job: Job
}

public struct QuotaPeriod: Equatable, Sendable, Decodable {
    public var id: UUID
    public var source: String
    public var startsAt: Date
    public var endsAt: Date
    public var grantedSeconds: Int
    public var usedSeconds: Int
    public var reservedSeconds: Int
    public var availableSeconds: Int
}

public struct Quota: Equatable, Sendable, Decodable {
    public var periods: [QuotaPeriod]

    /// Tek bir işte kullanılabilecek en fazla saniye. Rezervasyon dönemlere
    /// bölünmediği için toplam değil, en büyük dönem bakiyesidir.
    public var maxSecondsForSingleJob: Int { periods.map(\.availableSeconds).max() ?? 0 }
}
