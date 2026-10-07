import Foundation
import Observation
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

    /// Önizlemede o an gösterilecek altyazı satırı.
    var currentCaption: String? {
        let builder = CaptionLineBuilder()
        let time = playback.currentTime
        for track in document.captionTracks {
            let lines = builder.lines(from: document.timelineWords(for: track))
            if let line = lines.first(where: { $0.range.contains(time) }) { return line.text }
        }
        return nil
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
