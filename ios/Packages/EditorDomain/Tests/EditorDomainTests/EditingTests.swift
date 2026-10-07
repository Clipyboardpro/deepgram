import XCTest
@testable import EditorDomain

final class EditingTests: XCTestCase {
    typealias F = Fixtures

    private func baseClip() -> Clip {
        Clip(clipId: F.clipA, mediaId: F.mediaId, sourceIn: F.s(10), sourceOut: F.s(20), timelineStart: F.s(0))
    }

    func testBolmeIkiBitisikParcaUretirKaynakDegismez() throws {
        let doc = try F.project(clips: [baseClip()]).applying(.splitClip(clipId: F.clipA, at: F.s(4), newClipId: F.clipB))
        let clips = doc.tracks[0].clips
        XCTAssertEqual(clips.map(\.clipId), [F.clipA, F.clipB])
        XCTAssertEqual(clips[0].sourceRange, TimeRange(start: F.s(10), end: F.s(14)))
        XCTAssertEqual(clips[1].sourceRange, TimeRange(start: F.s(14), end: F.s(20)))
        XCTAssertEqual(clips[1].timelineStart, clips[0].timelineRange.end)
        XCTAssertEqual(doc.mediaAssets, F.project(clips: []).mediaAssets, "kaynak medya değişmez")
    }

    func testHizliKliptBolmeKaynakZamaniniDogruHesaplar() throws {
        var clip = baseClip()
        clip.playbackRate = 2   // zaman çizelgesinde 5 sn
        let doc = try F.project(clips: [clip]).applying(.splitClip(clipId: F.clipA, at: F.s(1), newClipId: F.clipB))
        XCTAssertEqual(doc.tracks[0].clips[0].sourceOut, F.s(12))
        XCTAssertEqual(doc.duration, F.s(5), "bölme toplam süreyi değiştirmez")
    }

    func testKlipDisindaBolmeReddedilir() {
        XCTAssertThrowsError(try F.project(clips: [baseClip()]).applying(.splitClip(clipId: F.clipA, at: F.s(10), newClipId: F.clipB))) {
            XCTAssertEqual($0 as? EditError, .splitOutsideClip)
        }
    }

    func testGecersizSonucUretenKomutProjeyiDegistirmez() {
        let doc = F.project(clips: [baseClip()])
        XCTAssertThrowsError(try doc.applying(.trimClip(clipId: F.clipA, sourceIn: F.s(50), sourceOut: F.s(70)))) {
            XCTAssertEqual($0 as? EditError, .invalidProject([.sourceOutOfBounds(clipId: F.clipA)]))
        }
        XCTAssertThrowsError(try doc.applying(.setRate(clipId: F.clipA, rate: 8)))
    }

    func testCakisanKliplerReddedilir() {
        let other = Clip(clipId: F.clipB, mediaId: F.mediaId, sourceIn: F.s(0), sourceOut: F.s(5), timelineStart: F.s(20))
        let doc = F.project(clips: [baseClip(), other])
        XCTAssertThrowsError(try doc.applying(.moveClip(clipId: F.clipB, timelineStart: F.s(8)))) {
            XCTAssertEqual($0 as? EditError, .invalidProject([.overlappingClips(trackId: F.trackId, first: F.clipA, second: F.clipB)]))
        }
    }

    func testGeriAlYineleRevisionIleriGider() throws {
        let clock: @Sendable () -> Date = { F.fixedDate }
        var history = EditHistory(F.project(clips: [baseClip()]), now: clock)
        let original = history.present

        try history.apply(.splitClip(clipId: F.clipA, at: F.s(4), newClipId: F.clipB))
        try history.apply(.removeClip(clipId: F.clipB))
        XCTAssertEqual(history.present.tracks[0].clips.count, 1)
        XCTAssertEqual(history.present.revision, 2)

        history.undo()
        XCTAssertEqual(history.present.tracks[0].clips.count, 2)
        history.undo()
        XCTAssertEqual(history.present.tracks[0].clips, original.tracks[0].clips)
        XCTAssertFalse(history.canUndo)
        XCTAssertEqual(history.present.revision, 4, "geri alma da yeni bir revision")

        history.redo()
        XCTAssertEqual(history.present.tracks[0].clips.count, 2)

        try history.apply(.moveClip(clipId: F.clipB, timelineStart: F.s(30)))
        XCTAssertFalse(history.canRedo, "yeni komut yinele yığınını temizler")
    }

    func testBasarisizKomutGecmiseYazilmaz() {
        var history = EditHistory(F.project(clips: [baseClip()]))
        XCTAssertThrowsError(try history.apply(.removeClip(clipId: F.clipB)))
        XCTAssertFalse(history.canUndo)
        XCTAssertEqual(history.present.revision, 0)
    }

    func testGecmisSiniriEskiAdimlariAtar() throws {
        var history = EditHistory(F.project(clips: [baseClip()]), limit: 2)
        for i in 1...3 {
            try history.apply(.moveClip(clipId: F.clipA, timelineStart: F.s(Double(i))))
        }
        history.undo()
        history.undo()
        history.undo()   // sınır 2: üçüncü geri alma etkisiz
        XCTAssertEqual(history.present.tracks[0].clips[0].timelineStart, F.s(1))
    }
}
