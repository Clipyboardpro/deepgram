import XCTest
@testable import EditorDomain

final class ProjectCodecTests: XCTestCase {
    typealias F = Fixtures

    func testKaydetAcAyniProjeyiVerir() throws {
        let clip = Clip(clipId: F.clipA, mediaId: F.mediaId, sourceIn: MediaTime(value: 1001, timescale: 30000),
                        sourceOut: F.s(20), timelineStart: F.s(0), playbackRate: 1.5)
        let doc = F.project(clips: [clip], captionWords: [F.word("w1000", "merhaba", 1, 1.5)])

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("project-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try ProjectCodec.write(doc, to: url)
        let reopened = try ProjectCodec.read(from: url)

        XCTAssertEqual(reopened, doc)
        XCTAssertEqual(reopened.tracks[0].clips[0].sourceIn.timescale, 30000, "zaman ölçeği korunur")
    }

    func testDahaYeniSemaReddedilir() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectCodec.encode(F.project(clips: []))) as? [String: Any])
        json["schemaVersion"] = ProjectDocument.currentSchemaVersion + 1
        XCTAssertThrowsError(try ProjectCodec.decode(JSONSerialization.data(withJSONObject: json))) {
            XCTAssertEqual($0 as? ProjectCodec.Error, .newerSchemaVersion(ProjectDocument.currentSchemaVersion + 1))
        }
    }

    func testSemaSurumuOlmayanDosyaReddedilir() {
        XCTAssertThrowsError(try ProjectCodec.decode(Data(#"{"projectId":"x"}"#.utf8))) {
            XCTAssertEqual($0 as? ProjectCodec.Error, .missingSchemaVersion)
        }
    }

    /// v1 örnek dosyası: şema değiştiğinde bu dosya silinmez, göçle açılabildiği
    /// test edilmeye devam eder.
    func testV1OrnekDosyasiAcilir() throws {
        let v1 = """
        {
          "schemaVersion": 1,
          "projectId": "00000000-0000-0000-0000-0000000000FF",
          "revision": 7,
          "canvas": {"width": 1080, "height": 1920, "fps": 30, "colorPolicy": "sdr"},
          "mediaAssets": [{"mediaId": "00000000-0000-0000-0000-00000000000A", "kind": "video",
                           "relativePath": "Media/a.mov", "duration": {"value": 36000, "timescale": 600}, "hasAudio": true}],
          "tracks": [],
          "captionTracks": [],
          "createdAt": "2026-10-07T12:00:00Z",
          "updatedAt": "2026-10-07T12:30:00Z"
        }
        """
        let doc = try ProjectCodec.decode(Data(v1.utf8))
        XCTAssertEqual(doc.revision, 7)
        XCTAssertEqual(doc.mediaAssets[0].duration, F.s(60))
        XCTAssertNil(doc.templateVersion)
    }
}
