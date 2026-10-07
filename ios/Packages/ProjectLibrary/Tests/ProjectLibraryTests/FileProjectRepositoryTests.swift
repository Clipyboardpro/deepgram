import XCTest
import EditorDomain
@testable import ProjectLibrary

final class FileProjectRepositoryTests: XCTestCase {
    private var root: URL!
    private var repo: FileProjectRepository!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("plib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repo = FileProjectRepository(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testBosKlasordeListeBos() throws {
        XCTAssertEqual(try repo.list(), ProjectListing(projects: [], unreadable: []))
    }

    func testOlusturVeAc() throws {
        let created = try repo.create(title: "  Çay videosu  ")
        XCTAssertEqual(created.title, "Çay videosu", "baştaki/sondaki boşluk atılır")
        XCTAssertEqual(created.tracks.map(\.kind), [.video, .audio])

        let dir = root.appendingPathComponent("Projects/\(created.projectId.uuidString)")
        for sub in ["project.json", "Media", "Captions"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(sub).path), sub)
        }
        XCTAssertEqual(try repo.load(created.projectId), created)
    }

    func testBosAdAdsizProjeOlarakListelenir() throws {
        _ = try repo.create(title: "   ")
        XCTAssertEqual(try repo.list().projects.first?.title, FileProjectRepository.untitled)
    }

    func testListeEnSonGuncellenenOnce() throws {
        var clock = Date(timeIntervalSince1970: 1_000)
        let box = ClockBox()
        repo = FileProjectRepository(root: root, now: { box.now })
        box.now = clock
        let older = try repo.create(title: "eski")
        clock.addTimeInterval(60); box.now = clock
        let newer = try repo.create(title: "yeni")
        XCTAssertEqual(try repo.list().projects.map(\.id), [newer.projectId, older.projectId])
    }

    func testKaydetVeYenidenAcildigindaDuzenlemeKorunur() throws {
        let created = try repo.create(title: "kesme")
        var history = EditHistory(created)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("kaynak-\(UUID()).mov")
        try Data([0, 1, 2]).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let relative = try repo.importMedia(from: source, into: created.projectId)
        XCTAssertTrue(relative.hasPrefix("Media/") && relative.hasSuffix(".mov"))
        XCTAssertEqual(try Data(contentsOf: repo.url(forMedia: relative, in: created.projectId)), Data([0, 1, 2]))

        var doc = history.present
        let asset = MediaAsset(kind: .video, relativePath: relative, duration: MediaTime(seconds: 30), hasAudio: true)
        doc.mediaAssets.append(asset)
        history = EditHistory(doc)
        try history.apply(.insertClip(trackId: doc.tracks[0].trackId,
                                      clip: Clip(mediaId: asset.mediaId, sourceIn: .zero, sourceOut: MediaTime(seconds: 10), timelineStart: .zero)))
        try repo.save(history.present)

        let reopened = try repo.load(created.projectId)
        XCTAssertEqual(reopened, history.present)
        XCTAssertEqual(try repo.list().projects.first?.clipCount, 1)
        XCTAssertEqual(try repo.list().projects.first?.duration, MediaTime(seconds: 10))
    }

    func testEskiRevisionYeniyiEzemez() throws {
        let created = try repo.create(title: nil)
        var newer = created
        newer.revision = 5
        try repo.save(newer)
        XCTAssertThrowsError(try repo.save(created)) {
            XCTAssertEqual($0 as? ProjectRepositoryError, .staleRevision(stored: 5, attempted: 0))
        }
        XCTAssertEqual(try repo.load(created.projectId).revision, 5)
    }

    func testCogaltMedyayiKopyalarKaynagiDegistirmez() throws {
        let created = try repo.create(title: "asıl")
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("k-\(UUID()).m4a")
        try Data([9]).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let relative = try repo.importMedia(from: source, into: created.projectId)

        let copy = try repo.duplicate(created.projectId, title: nil)
        XCTAssertNotEqual(copy.projectId, created.projectId)
        XCTAssertEqual(copy.title, "asıl (kopya)")
        XCTAssertEqual(copy.revision, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.url(forMedia: relative, in: copy.projectId).path))

        try repo.delete(copy.projectId)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.url(forMedia: relative, in: created.projectId).path),
                      "kopyayı silmek asıl projenin medyasına dokunmaz")
        XCTAssertEqual(try repo.list().projects.map(\.id), [created.projectId])
    }

    func testBozukProjeListeyiEngellemezAyriBildirilir() throws {
        let good = try repo.create(title: "sağlam")
        let bad = try repo.create(title: "bozuk")
        try Data("{bozuk".utf8).write(to: root.appendingPathComponent("Projects/\(bad.projectId.uuidString)/project.json"))
        try Data().write(to: root.appendingPathComponent("Projects/.DS_Store"))

        let listing = try repo.list()
        XCTAssertEqual(listing.projects.map(\.id), [good.projectId])
        XCTAssertEqual(listing.unreadable, [bad.projectId])
        XCTAssertThrowsError(try repo.load(bad.projectId)) {
            XCTAssertEqual($0 as? ProjectRepositoryError, .unreadableProject(bad.projectId))
        }
    }

    func testOlmayanProje() {
        let id = UUID()
        XCTAssertThrowsError(try repo.load(id)) { XCTAssertEqual($0 as? ProjectRepositoryError, .projectNotFound(id)) }
        XCTAssertThrowsError(try repo.delete(id)) { XCTAssertEqual($0 as? ProjectRepositoryError, .projectNotFound(id)) }
    }
}

private final class ClockBox: @unchecked Sendable {
    var now = Date()
}
