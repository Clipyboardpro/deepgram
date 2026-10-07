import XCTest
@testable import EditorDomain

final class RippleEditTests: XCTestCase {
    typealias F = Fixtures

    /// A: kaynak 0–10 → 0–10; B: kaynak 20–30 → 10–20; C: kaynak 40–45 → 22–27 (2 sn boşluk).
    private func project() -> ProjectDocument {
        F.project(clips: [
            Clip(clipId: F.clipA, mediaId: F.mediaId, sourceIn: F.s(0), sourceOut: F.s(10), timelineStart: F.s(0)),
            Clip(clipId: F.clipB, mediaId: F.mediaId, sourceIn: F.s(20), sourceOut: F.s(30), timelineStart: F.s(10)),
            Clip(clipId: clipC, mediaId: F.mediaId, sourceIn: F.s(40), sourceOut: F.s(45), timelineStart: F.s(22)),
        ])
    }
    private let clipC = UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!

    private func starts(_ doc: ProjectDocument) -> [Double] {
        doc.tracks[0].clips.map(\.timelineStart.seconds)
    }

    func testSonuKirpinincaSonrakilerKayar() throws {
        let doc = try project().applying(.rippleEdit(clipId: F.clipA, sourceIn: F.s(0), sourceOut: F.s(6), rate: 1))
        XCTAssertEqual(starts(doc), [0, 6, 18], "boşluk korunur")
        XCTAssertEqual(doc.duration.seconds, 23, accuracy: 0.001)
    }

    func testBasiKirpinincaKlipYerindeKalirSonrakilerKayar() throws {
        let doc = try project().applying(.rippleEdit(clipId: F.clipB, sourceIn: F.s(25), sourceOut: F.s(30), rate: 1))
        XCTAssertEqual(starts(doc), [0, 10, 17])
        XCTAssertEqual(doc.tracks[0].clips[1].sourceIn, F.s(25))
    }

    func testHizlandirmaVeYavaslatma() throws {
        let fast = try project().applying(.rippleEdit(clipId: F.clipA, sourceIn: F.s(0), sourceOut: F.s(10), rate: 2))
        XCTAssertEqual(starts(fast), [0, 5, 17])
        let slow = try project().applying(.rippleEdit(clipId: F.clipA, sourceIn: F.s(0), sourceOut: F.s(10), rate: 0.5))
        XCTAssertEqual(starts(slow), [0, 20, 32], "yavaşlayan klip sonrakilerle çakışmaz")
        XCTAssertEqual(ProjectValidator.validate(slow), [])
    }

    func testUzatmaKaynakSiniriniAsamaz() {
        XCTAssertThrowsError(try project().applying(.rippleEdit(clipId: F.clipA, sourceIn: F.s(0), sourceOut: F.s(61), rate: 1))) {
            guard case .invalidProject = $0 as? EditError else { return XCTFail("\($0)") }
        }
    }

    func testOncekiKliplereDokunulmaz() throws {
        let doc = try project().applying(.rippleEdit(clipId: clipC, sourceIn: F.s(40), sourceOut: F.s(41), rate: 1))
        XCTAssertEqual(starts(doc), [0, 10, 22])
    }

    func testTekAdimdaGeriAlinir() throws {
        var history = EditHistory(project())
        try history.apply(.rippleEdit(clipId: F.clipA, sourceIn: F.s(2), sourceOut: F.s(8), rate: 1.5))
        history.undo()
        XCTAssertEqual(history.present.tracks, project().tracks)
    }
}

final class ClipTrimmingTests: XCTestCase {
    typealias F = Fixtures
    private let clip = Clip(mediaId: Fixtures.mediaId, sourceIn: Fixtures.s(10), sourceOut: Fixtures.s(20), timelineStart: .zero, playbackRate: 2)

    func testBaslangicKenariHizlaOlceklenir() {
        // 2x hızda zaman çizelgesinde 1 sn = kaynakta 2 sn.
        let r = clip.trimming(.start, byTimeline: F.s(1), assetDuration: F.s(60))
        XCTAssertEqual(r.sourceIn.seconds, 12, accuracy: 0.001)
        XCTAssertEqual(r.sourceOut, F.s(20))
    }

    func testKaynakSinirlariAsilmaz() {
        XCTAssertEqual(clip.trimming(.start, byTimeline: F.s(-100), assetDuration: F.s(60)).sourceIn, .zero)
        XCTAssertEqual(clip.trimming(.end, byTimeline: F.s(100), assetDuration: F.s(60)).sourceOut, F.s(60))
    }

    func testEnKisaSureKorunur() {
        let start = clip.trimming(.start, byTimeline: F.s(100), assetDuration: F.s(60))
        XCTAssertEqual((start.sourceOut - start.sourceIn).seconds, 0.2, accuracy: 0.001, "0,1 sn zaman çizelgesi = 2x'te 0,2 sn kaynak")
        let end = clip.trimming(.end, byTimeline: F.s(-100), assetDuration: F.s(60))
        XCTAssertEqual((end.sourceOut - end.sourceIn).seconds, 0.2, accuracy: 0.001)
    }
}
