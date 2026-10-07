import Foundation
import Observation
import AIJobsClient
import EditorDomain
import MediaEngine
import ProjectLibrary

/// Açık bir projenin düzenleme durumu. Her başarılı komut geçmişe girer ve
/// proje diske kaydedilir (atomik; eski revision yeniyi ezmez).
@MainActor
@Observable
final class ProjectEditorModel {
    private(set) var history: EditHistory
    private(set) var isImporting = false
    var errorMessage: String?
    var selectedClipId: UUID?
    let playback: PlaybackController

    private let repository: ProjectRepository
    private let builder: CompositionBuilder

    init(document: ProjectDocument, repository: ProjectRepository) {
        self.history = EditHistory(document)
        self.repository = repository
        self.playback = PlaybackController()
        let projectId = document.projectId
        self.builder = CompositionBuilder { [repository] asset in
            repository.url(forMedia: asset.relativePath, in: projectId)
        }
    }

    /// Önizlemeyi güncel projeyle yeniden kurar.
    func refreshPreview() async {
        let document = history.present
        do {
            playback.load(try await builder.build(document))
        } catch {
            errorMessage = "Önizleme hazırlanamadı."
        }
    }

    /// Seçili klibi oynatma imlecinden ikiye böler.
    func splitAtPlayhead() {
        guard let clipId = clipUnderPlayhead() else { return }
        let newId = UUID()
        do {
            try apply(.splitClip(clipId: clipId, at: playback.currentTime, newClipId: newId))
            selectedClipId = newId
        } catch {
            errorMessage = "Bu noktada bölünemiyor."
        }
    }

    func deleteSelectedClip() {
        guard let clipId = selectedClipId else { return }
        do {
            try apply(.removeClip(clipId: clipId))
            selectedClipId = nil
        } catch {
            errorMessage = "Klip silinemedi."
        }
    }

    // MARK: - Kırpma ve hız

    static let speedOptions: [Double] = [0.25, 0.5, 1, 1.5, 2, 3, 4]

    var selectedClip: Clip? {
        guard let id = selectedClipId else { return nil }
        return document.tracks.flatMap(\.clips).first { $0.clipId == id }
    }

    /// Seçili klibin kenarının sürüklemeyle varacağı kaynak aralığı (önizleme için).
    func trimPreview(_ clip: Clip, edge: ClipEdge, timelineSeconds: Double) -> (sourceIn: MediaTime, sourceOut: MediaTime) {
        let assetDuration = document.asset(clip.mediaId)?.duration ?? clip.sourceOut
        return clip.trimming(edge, byTimeline: MediaTime(seconds: timelineSeconds), assetDuration: assetDuration)
    }

    /// Kenar sürüklemesini uygular; sonraki klipler kayar (tek geri al adımı).
    func commitTrim(_ clip: Clip, edge: ClipEdge, timelineSeconds: Double) {
        let range = trimPreview(clip, edge: edge, timelineSeconds: timelineSeconds)
        guard range.sourceIn != clip.sourceIn || range.sourceOut != clip.sourceOut else { return }
        do {
            try apply(.rippleEdit(clipId: clip.clipId, sourceIn: range.sourceIn, sourceOut: range.sourceOut, rate: clip.playbackRate))
        } catch {
            errorMessage = "Klip kırpılamadı."
        }
    }

    /// Seçili klibin hızını değiştirir; sonraki klipler kayar.
    func setSpeed(_ rate: Double) {
        guard let clip = selectedClip, clip.playbackRate != rate else { return }
        do {
            try apply(.rippleEdit(clipId: clip.clipId, sourceIn: clip.sourceIn, sourceOut: clip.sourceOut, rate: rate))
        } catch {
            errorMessage = "Hız değiştirilemedi."
        }
    }

    /// İmlecin üzerindeki klip (seçili değilse).
    func clipUnderPlayhead() -> UUID? {
        let clips = document.tracks.first { $0.kind == .video }?.clips ?? []
        if let selected = selectedClipId,
           let clip = clips.first(where: { $0.clipId == selected }),
           clip.timelineRange.contains(playback.currentTime) {
            return selected
        }
        return clips.first { $0.timelineRange.contains(playback.currentTime) }?.clipId
    }

    /// Önizlemede o an gösterilecek altyazı satırı (dışa aktarmayla aynı kurallar).
    var currentCaption: String? {
        RenderPlan.cue(at: playback.currentTime, in: RenderPlan.captionCues(for: document))?.text
    }

    // MARK: - Dışa aktarma

    enum ExportState: Equatable {
        case idle
        case exporting(progress: Double)
        case finished(URL)
    }

    private(set) var exportState: ExportState = .idle
    @ObservationIgnored private var exportTask: Task<Void, Never>?

    /// Projenin şu anki hâlini 1080p MP4 olarak dışa aktarır (altyazılar videoya işlenir).
    func startExport() {
        guard exportTask == nil else { return }
        let document = history.present
        let name = (document.title ?? "Video").replacingOccurrences(of: "/", with: "-")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
        let destination = folder.appendingPathComponent("\(name).mp4")
        exportState = .exporting(progress: 0)
        playback.player.pause()

        exportTask = Task { [builder] in
            defer { exportTask = nil }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = try await Exporter(builder: builder).export(document, to: destination) { value in
                    Task { @MainActor [weak self] in
                        if case .exporting = self?.exportState { self?.exportState = .exporting(progress: value) }
                    }
                }
                exportState = .finished(url)
            } catch ExportError.canceled {
                exportState = .idle
            } catch {
                exportState = .idle
                errorMessage = "Video dışa aktarılamadı."
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    func dismissExport() {
        if case let .finished(url) = exportState { try? FileManager.default.removeItem(at: url) }
        exportState = .idle
    }

    // MARK: - Altyazı düzenleme

    /// Düzenleme listesi (önizleme ve dışa aktarmayla aynı satırlar).
    var captionLines: [EditableCaptionLine] { RenderPlan.editableLines(for: document) }

    /// Satırın metnini kullanıcının yazdığıyla değiştirir (tek geri al adımı).
    func editCaption(_ line: EditableCaptionLine, newText: String) {
        applyCorrections(CaptionLineEditor.corrections(for: line, newText: newText), in: line)
    }

    /// Satırdaki düzeltmeleri kaldırır, AI metnine döner.
    func revertCaption(_ line: EditableCaptionLine) {
        applyCorrections(CaptionLineEditor.revert(line), in: line)
    }

    private func applyCorrections(_ corrections: [WordCorrection], in line: EditableCaptionLine) {
        guard !corrections.isEmpty else { return }
        do {
            try apply(.correctWords(captionTrackId: line.captionTrackId, corrections: corrections))
        } catch {
            errorMessage = "Altyazı değiştirilemedi."
        }
    }

    // MARK: - Otomatik altyazı

    enum CaptionState: Equatable {
        case idle
        case working(String)
    }

    private(set) var captionState: CaptionState = .idle
    /// Oturum yok/düştü: arayüz giriş ekranını açar.
    var needsSignIn = false
    @ObservationIgnored private var captionTask: Task<Void, Never>?

    /// Altyazısı henüz olmayan, sesli ve zaman çizelgesinde kullanılan medyalar;
    /// her biri için yalnız kliplerin kullandığı kaynak aralığı gönderilir.
    var captionTargets: [(asset: MediaAsset, range: TimeRange)] {
        let clips = document.tracks.flatMap(\.clips)
        return document.mediaAssets.compactMap { asset in
            guard asset.hasAudio, !document.captionTracks.contains(where: { $0.mediaId == asset.mediaId }) else { return nil }
            let used = clips.filter { $0.mediaId == asset.mediaId }
            guard let start = used.map(\.sourceIn).min(), let end = used.map(\.sourceOut).max(), start < end else { return nil }
            return (asset, TimeRange(start: start, end: end))
        }
    }

    func startCaptioning(api: AIJobsClient) {
        guard captionTask == nil else { return }
        let targets = captionTargets
        guard !targets.isEmpty else { return }
        let projectId = document.projectId
        let work = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Captioning", isDirectory: true)
        captionState = .working("Ses hazırlanıyor…")
        playback.player.pause()

        captionTask = Task { [repository] in
            defer {
                captionTask = nil
                captionState = .idle
            }
            for (index, target) in targets.enumerated() {
                let prefix = targets.count > 1 ? "(\(index + 1)/\(targets.count)) " : ""
                let workflow = TranscriptionWorkflow(client: api, progress: { status in
                    Task { @MainActor [weak self] in
                        guard case .working = self?.captionState else { return }
                        self?.captionState = .working(prefix + Self.statusText(status))
                    }
                })
                let requestKey = Self.requestKey(projectId: projectId, mediaId: target.asset.mediaId, range: target.range)
                do {
                    let command = try await CaptioningService(workflow: workflow, workDirectory: work).caption(
                        mediaId: target.asset.mediaId,
                        source: repository.url(forMedia: target.asset.relativePath, in: projectId),
                        range: target.range,
                        clientRequestId: Self.clientRequestId(for: requestKey)
                    )
                    try apply(command)
                    UserDefaults.standard.removeObject(forKey: requestKey)
                } catch is CancellationError {
                    return
                } catch {
                    handleCaptionError(error, requestKey: requestKey)
                    return
                }
            }
        }
    }

    func cancelCaptioning() {
        captionTask?.cancel()
    }

    private func handleCaptionError(_ error: Error, requestKey: String) {
        if let error = error as? AuthError {
            if error == .signedOut { needsSignIn = true } else { errorMessage = error.userMessage }
        } else if let error = error as? APIError {
            if case .server(401, _, _) = error { needsSignIn = true } else { errorMessage = error.userMessage }
        } else if let error = error as? WorkflowError {
            switch error {
            case .timedOut:
                // İş sunucuda sürüyor olabilir; aynı istek kimliğiyle tekrar denenince ona bağlanır.
                errorMessage = "Altyazı beklenenden uzun sürdü. Biraz sonra tekrar dene."
            case .providerStateUnknown:
                errorMessage = "Altyazı servisinden yanıt alınamadı. Daha sonra tekrar dene."
            case .jobFailed, .jobCanceled, .resultUnavailable:
                // Biten iş tekrar denenmez; yeni denemede yeni istek kimliği kullanılır.
                UserDefaults.standard.removeObject(forKey: requestKey)
                errorMessage = "Altyazı oluşturulamadı."
            }
        } else if error is MediaEngineError {
            errorMessage = "Videonun sesi okunamadı."
        } else {
            errorMessage = "Altyazı oluşturulamadı."
        }
    }

    /// Aynı medya ve aralık için iş başlamadan önce kalıcı saklanan istek kimliği:
    /// uygulama yarıda kapanırsa tekrar denemede sunucu aynı işi döndürür.
    private static func requestKey(projectId: UUID, mediaId: UUID, range: TimeRange) -> String {
        "caption-request.\(projectId.uuidString).\(mediaId.uuidString).\(range.start.value)/\(range.start.timescale)-\(range.end.value)/\(range.end.timescale)"
    }

    private static func clientRequestId(for key: String) -> String {
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    private static func statusText(_ status: JobStatus) -> String {
        switch status {
        case .awaitingUpload: "Ses yükleniyor…"
        case .queued, .submitted: "Altyazı çıkarılıyor…"
        default: "Altyazı hazırlanıyor…"
        }
    }

    var document: ProjectDocument { history.present }
    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    func undo() {
        history.undo()
        changed()
    }

    func redo() {
        history.redo()
        changed()
    }

    /// Seçilen videoyu projeye kopyalar, inceler ve zaman çizelgesinin sonuna ekler.
    /// - Parameter pickedFile: Fotoğraflar'dan gelen geçici kopya; işlem sonunda silinir.
    func importVideo(from pickedFile: URL) async {
        isImporting = true
        defer {
            isImporting = false
            try? FileManager.default.removeItem(at: pickedFile)
        }
        let projectId = document.projectId
        var copiedPath: String?
        do {
            let relativePath = try repository.importMedia(from: pickedFile, into: projectId)
            copiedPath = relativePath
            let probe = try await MediaInspector.probe(repository.url(forMedia: relativePath, in: projectId))
            let asset = probe.mediaAsset(relativePath: relativePath)
            try apply(.addMediaAsset(asset))
            copiedPath = nil   // artık projeye kayıtlı; silinmez

            guard let track = document.tracks.first(where: { $0.kind == .video }) else { return }
            let clip = Clip(mediaId: asset.mediaId, sourceIn: .zero, sourceOut: asset.duration,
                            timelineStart: document.duration)
            try apply(.insertClip(trackId: track.trackId, clip: clip))
        } catch {
            // Projeye kaydedilemeyen kopya Media/ altında sahipsiz kalmasın.
            if let copiedPath {
                try? FileManager.default.removeItem(at: repository.url(forMedia: copiedPath, in: projectId))
            }
            errorMessage = (error as? MediaEngineError) == .unreadable
                ? "Bu dosya açılamadı. Desteklenen bir video seç."
                : "Video eklenemedi."
        }
    }

    private func apply(_ command: EditCommand) throws {
        try history.apply(command)
        changed()
    }

    private func changed() {
        persist()
        Task { await refreshPreview() }
    }

    private func persist() {
        do {
            try repository.save(history.present)
        } catch {
            errorMessage = "Proje kaydedilemedi."
        }
    }
}
