import Foundation
import Observation
import EditorDomain
import ProjectLibrary

/// Proje listesi ekranının durumu. Disk işlemleri `ProjectRepository`'de;
/// burada yalnız ekranın gösterdiği hâl ve kullanıcıya dönük hata metni var.
@MainActor
@Observable
final class ProjectLibraryModel {
    private(set) var projects: [ProjectSummary] = []
    /// Okunamayan proje sayısı (bozuk dosya). Liste yine gösterilir.
    private(set) var unreadableCount = 0
    var errorMessage: String?

    private let repository: ProjectRepository

    init(repository: ProjectRepository) {
        self.repository = repository
    }

    func reload() {
        perform("Projeler yüklenemedi.") {
            let listing = try repository.list()
            projects = listing.projects
            unreadableCount = listing.unreadable.count
        }
    }

    @discardableResult
    func create(title: String?) -> UUID? {
        var id: UUID?
        perform("Proje oluşturulamadı.") {
            id = try repository.create(title: title).projectId
            reload()
        }
        return id
    }

    func duplicate(_ id: UUID) {
        perform("Proje çoğaltılamadı.") {
            _ = try repository.duplicate(id, title: nil)
            reload()
        }
    }

    func delete(_ id: UUID) {
        perform("Proje silinemedi.") {
            try repository.delete(id)
            reload()
        }
    }

    /// Düzenleyici için projeyi açar.
    func makeEditor(_ id: UUID) -> ProjectEditorModel? {
        var editor: ProjectEditorModel?
        perform("Proje açılamadı.") {
            editor = ProjectEditorModel(document: try repository.load(id), repository: repository)
        }
        return editor
    }

    private func perform(_ message: String, _ work: () throws -> Void) {
        do {
            try work()
        } catch {
            errorMessage = message
        }
    }
}
