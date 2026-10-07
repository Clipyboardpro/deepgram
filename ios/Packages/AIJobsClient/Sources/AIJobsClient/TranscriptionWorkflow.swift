import Foundation
import EditorDomain

/// Sunucuya gönderilecek ses. Uygulama sesi çıkarır (mono, 16 kHz AAC/M4A),
/// SHA-256'yı CryptoKit ile hesaplar ve buraya verir.
public struct AudioPayload: Sendable {
    public var data: Data
    public var sha256Hex: String
    public var durationSeconds: Double
    public var language: String

    public init(data: Data, sha256Hex: String, durationSeconds: Double, language: String = "tr") {
        self.data = data
        self.sha256Hex = sha256Hex.lowercased()
        self.durationSeconds = durationSeconds
        self.language = language
    }

    /// Sunucu tam saniye bekler; kesir yukarı yuvarlanır (en az 1).
    public var billableSeconds: Int { max(1, Int(durationSeconds.rounded(.up))) }
}

public enum WorkflowError: Error, Equatable, Sendable {
    /// İş başarısız bitti; `errorCode` sunucunun koyduğu kod.
    case jobFailed(errorCode: String?)
    case jobCanceled
    /// Sağlayıcıya gönderimin sonucu belirsiz; sunucu otomatik tekrar
    /// göndermez. Kullanıcıya "daha sonra tekrar dene" gösterilir.
    case providerStateUnknown
    /// İş başarılı ama sonuç saklama süresi dolmuş.
    case resultUnavailable
    /// Bekleme süresi aşıldı. İş sunucuda sürebilir; aynı clientRequestId
    /// ile tekrar çağrı aynı işe bağlanır.
    case timedOut(jobId: UUID)
}

/// Bekleme aralıkları: hızlı başlar, `max`'a kadar büyür.
public struct PollingPolicy: Sendable {
    public var initial: Duration
    public var max: Duration
    public var multiplier: Double
    public var timeout: Duration

    public init(initial: Duration = .seconds(1), max: Duration = .seconds(10), multiplier: Double = 1.6, timeout: Duration = .seconds(600)) {
        self.initial = initial
        self.max = max
        self.multiplier = multiplier
        self.timeout = timeout
    }

    func delay(attempt: Int) -> Duration {
        let seconds = initial.secondsDouble * pow(multiplier, Double(attempt))
        return .milliseconds(Int64(min(seconds, max.secondsDouble) * 1000))
    }
}

/// Uçtan uca otomatik altyazı: iş oluştur → yükle → bildir → bekle → sonuç.
///
/// Tekrar çağrılabilir: aynı `clientRequestId` ile çağrıldığında sunucu aynı
/// işi döndürür; yükleme gerekmiyorsa (`upload == nil`) atlanır. Uygulama
/// `clientRequestId`'yi iş başlamadan önce kalıcı saklamalıdır.
public struct TranscriptionWorkflow: Sendable {
    public typealias Sleeper = @Sendable (Duration) async throws -> Void

    private let client: AIJobsClient
    private let policy: PollingPolicy
    private let sleep: Sleeper
    private let progress: @Sendable (JobStatus) -> Void

    public init(
        client: AIJobsClient,
        policy: PollingPolicy = PollingPolicy(),
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) },
        progress: @escaping @Sendable (JobStatus) -> Void = { _ in }
    ) {
        self.client = client
        self.policy = policy
        self.sleep = sleep
        self.progress = progress
    }

    public func run(_ audio: AudioPayload, clientRequestId: String) async throws -> Transcript {
        let created = try await client.createJob(CreateJobRequest(
            clientRequestId: clientRequestId,
            language: audio.language,
            audioSha256: audio.sha256Hex,
            audioBytes: audio.data.count,
            durationSeconds: audio.billableSeconds
        ))
        let jobId = created.job.id
        progress(created.job.status)

        if let upload = created.upload {
            try await client.upload(audio.data, to: upload)
        }
        if created.job.status == .awaitingUpload {
            progress(try await client.markUploaded(jobId: jobId).status)
        }
        return try await waitForResult(jobId: jobId)
    }

    /// Daha önce başlatılmış bir işin sonucunu bekler (ör. uygulama yeniden açıldığında).
    public func waitForResult(jobId: UUID) async throws -> Transcript {
        var waited = Duration.zero
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let current = try await client.job(id: jobId)
            progress(current.job.status)

            switch current.job.status {
            case .succeeded:
                guard let result = current.result else { throw WorkflowError.resultUnavailable }
                return result.transcript
            case .failed:
                throw WorkflowError.jobFailed(errorCode: current.job.errorCode)
            case .canceled:
                throw WorkflowError.jobCanceled
            case .unknownProviderState:
                throw WorkflowError.providerStateUnknown
            default:
                break
            }

            let delay = policy.delay(attempt: attempt)
            guard waited + delay <= policy.timeout else { throw WorkflowError.timedOut(jobId: jobId) }
            try await sleep(delay)
            waited += delay
            attempt += 1
        }
    }
}

extension Duration {
    var secondsDouble: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
