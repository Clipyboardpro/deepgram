import Foundation
import EditorDomain

/// Proje listesinde gösterilen özet. Asıl kaynak `project.json`; liste her
/// açılışta diskten yeniden kurulur, ayrı bir indeks bozulup senkron dışı kalamaz.
public struct ProjectSummary: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var updatedAt: Date
    public var duration: MediaTime
    public var clipCount: Int
}

public enum ProjectRepositoryError: Error, Equatable {
    case projectNotFound(UUID)
    /// Diskteki proje bu kaydedilmek istenen sürümden daha yeni: başka bir
    /// yerden (ör. ikinci pencere) kaydedilmiş. Üzerine yazılmaz.
    case staleRevision(stored: Int, attempted: Int)
    case unreadableProject(UUID)
}

/// Projelerin kalıcı saklandığı yer.
public protocol ProjectRepository: Sendable {
    func list() throws -> ProjectListing
    func create(title: String?) throws -> ProjectDocument
    func load(_ id: UUID) throws -> ProjectDocument
    func save(_ document: ProjectDocument) throws
    func duplicate(_ id: UUID, title: String?) throws -> ProjectDocument
    func delete(_ id: UUID) throws
    /// Bir dosyayı projenin `Media/` klasörüne kopyalar; proje içindeki göreli yolu döner.
    func importMedia(from source: URL, into id: UUID) throws -> String
    func url(forMedia relativePath: String, in id: UUID) -> URL
}

/// `list()` sonucu: okunabilen projeler ve okunamayanlar ayrı. Bozuk bir
/// proje listeyi göstermeyi engellemez ama sessizce de kaybolmaz.
public struct ProjectListing: Equatable, Sendable {
    public var projects: [ProjectSummary]
    public var unreadable: [UUID]
}

/// Dosya tabanlı depo. Yerleşim:
///
///     <root>/Projects/<projectId>/project.json
///     <root>/Projects/<projectId>/Media/…
///     <root>/Projects/<projectId>/Captions/…
///
/// `root` uygulamada `Documents`; küçük resim ve proxy gibi yeniden
/// üretilebilir dosyalar burada değil, `Caches` altında tutulur.
public struct FileProjectRepository: ProjectRepository {
    public static let untitled = "Adsız proje"

    private let projectsDirectory: URL
    private let now: @Sendable () -> Date

    public init(root: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.projectsDirectory = root.appendingPathComponent("Projects", isDirectory: true)
        self.now = now
    }

    public func list() throws -> ProjectListing {
        let fm = FileManager.default
        guard fm.fileExists(atPath: projectsDirectory.path) else {
            return ProjectListing(projects: [], unreadable: [])
        }
        var projects: [ProjectSummary] = []
        var unreadable: [UUID] = []
        for name in try fm.contentsOfDirectory(atPath: projectsDirectory.path) {
            guard let id = UUID(uuidString: name) else { continue }   // .DS_Store vb.
            do {
                let doc = try load(id)
                projects.append(ProjectSummary(
                    id: doc.projectId,
                    title: doc.title ?? Self.untitled,
                    updatedAt: doc.updatedAt,
                    duration: doc.duration,
                    clipCount: doc.tracks.reduce(0) { $0 + $1.clips.count }
                ))
            } catch {
                unreadable.append(id)
            }
        }
        projects.sort { ($0.updatedAt, $0.id.uuidString) > ($1.updatedAt, $1.id.uuidString) }
        unreadable.sort { $0.uuidString < $1.uuidString }
        return ProjectListing(projects: projects, unreadable: unreadable)
    }

    public func create(title: String?) throws -> ProjectDocument {
        let document = ProjectDocument(
            title: Self.cleanTitle(title),
            tracks: [Track(kind: .video), Track(kind: .audio)],
            createdAt: now()
        )
        try prepareDirectories(for: document.projectId)
        try ProjectCodec.write(document, to: documentURL(document.projectId))
        return document
    }

    public func load(_ id: UUID) throws -> ProjectDocument {
        let url = documentURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProjectRepositoryError.projectNotFound(id)
        }
        do {
            return try ProjectCodec.read(from: url)
        } catch {
            throw ProjectRepositoryError.unreadableProject(id)
        }
    }

    /// Atomik kaydeder. Diskte daha yeni bir revision varsa reddeder.
    public func save(_ document: ProjectDocument) throws {
        let url = documentURL(document.projectId)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProjectRepositoryError.projectNotFound(document.projectId)
        }
        if let stored = try? ProjectCodec.read(from: url), stored.revision > document.revision {
            throw ProjectRepositoryError.staleRevision(stored: stored.revision, attempted: document.revision)
        }
        try ProjectCodec.write(document, to: url)
    }

    public func duplicate(_ id: UUID, title: String?) throws -> ProjectDocument {
        let source = try load(id)
        var copy = source
        copy.projectId = UUID()
        copy.title = Self.cleanTitle(title) ?? source.title.map { "\($0) (kopya)" }
        copy.revision = 0
        copy.createdAt = now()
        copy.updatedAt = copy.createdAt

        // Klasörü bütün olarak kopyala (medya dahil), sonra proje dosyasını yaz.
        let fm = FileManager.default
        let target = directory(copy.projectId)
        try fm.copyItem(at: directory(id), to: target)
        do {
            try ProjectCodec.write(copy, to: documentURL(copy.projectId))
        } catch {
            try? fm.removeItem(at: target)
            throw error
        }
        return copy
    }

    public func delete(_ id: UUID) throws {
        let dir = directory(id)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw ProjectRepositoryError.projectNotFound(id)
        }
        try FileManager.default.removeItem(at: dir)
    }

    public func importMedia(from source: URL, into id: UUID) throws -> String {
        guard FileManager.default.fileExists(atPath: documentURL(id).path) else {
            throw ProjectRepositoryError.projectNotFound(id)
        }
        let ext = source.pathExtension.isEmpty ? "" : ".\(source.pathExtension.lowercased())"
        let relativePath = "Media/\(UUID().uuidString.lowercased())\(ext)"
        try FileManager.default.copyItem(at: source, to: directory(id).appendingPathComponent(relativePath))
        return relativePath
    }

    public func url(forMedia relativePath: String, in id: UUID) -> URL {
        directory(id).appendingPathComponent(relativePath)
    }

    // MARK: - İç

    private func directory(_ id: UUID) -> URL {
        projectsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func documentURL(_ id: UUID) -> URL {
        directory(id).appendingPathComponent("project.json")
    }

    private func prepareDirectories(for id: UUID) throws {
        let fm = FileManager.default
        for sub in ["Media", "Captions"] {
            try fm.createDirectory(at: directory(id).appendingPathComponent(sub, isDirectory: true), withIntermediateDirectories: true)
        }
    }

    static func cleanTitle(_ title: String?) -> String? {
        guard let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(80))
    }
}
