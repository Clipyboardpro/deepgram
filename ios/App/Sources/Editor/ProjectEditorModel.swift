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

    private let repository: ProjectRepository

    init(document: ProjectDocument, repository: ProjectRepository) {
        self.history = EditHistory(document)
        self.repository = repository
    }

    var document: ProjectDocument { history.present }
    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    func undo() {
        history.undo()
        persist()
    }

    func redo() {
        history.redo()
        persist()
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
        persist()
    }

    private func persist() {
        do {
            try repository.save(history.present)
        } catch {
            errorMessage = "Proje kaydedilemedi."
        }
    }
}
