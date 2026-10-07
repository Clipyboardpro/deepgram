import Foundation
import AIJobsClient
import EditorDomain

/// Bir medyanın otomatik altyazısını üretir: sesi çıkar → sunucu akışı →
/// projeye uygulanacak komut. Proje değişikliği çağıran tarafta
/// `EditHistory.apply` ile yapılır; böylece geri alınabilir.
public struct CaptioningService: Sendable {
    private let workflow: TranscriptionWorkflow
    private let workDirectory: URL

    /// - Parameter workDirectory: Geçici ses dosyaları için (ör. Caches). Çıkarılan
    ///   ses gönderildikten sonra silinir.
    public init(workflow: TranscriptionWorkflow, workDirectory: URL) {
        self.workflow = workflow
        self.workDirectory = workDirectory
    }

    /// - Parameters:
    ///   - source: Medyanın proje içindeki dosyası.
    ///   - range: Kaynağın yalnız bu kısmı gönderilir (kaynak zamanı); nil ise tamamı.
    ///   - clientRequestId: İş başlamadan önce uygulamanın kalıcı sakladığı kimlik.
    ///     Uygulama kapanıp açılırsa aynı kimlikle tekrar çağrılır, sunucu aynı işi döndürür.
    public func caption(
        mediaId: UUID,
        source: URL,
        range: TimeRange? = nil,
        language: String = "tr",
        clientRequestId: String
    ) async throws -> EditCommand {
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let audioURL = workDirectory.appendingPathComponent("\(clientRequestId).m4a")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let audio = try await AudioExtractor.extract(from: source, range: range, to: audioURL)
        let payload = AudioPayload(
            data: try Data(contentsOf: audio.url),
            sha256Hex: audio.sha256Hex,
            durationSeconds: audio.durationSeconds,
            language: language
        )
        let transcript = try await workflow.run(payload, clientRequestId: clientRequestId)
        // Sunucu zamanları gönderilen sesin başına göredir; kaynak zamanına çevirmek
        // için sesin kaynakta başladığı an verilir.
        return .applyTranscript(mediaId: mediaId, transcript: transcript, audioSourceStart: range?.start ?? .zero)
    }
}
