import XCTest
@testable import EditorDomain

final class CaptionEditingTests: XCTestCase {
    typealias F = Fixtures

    private func line(_ texts: [String], corrections: [String: String] = [:]) -> EditableCaptionLine {
        EditableCaptionLine(
            id: "l", captionTrackId: F.captionTrackId, range: TimeRange(start: F.s(0), end: F.s(1)),
            words: texts.enumerated().map { i, text in
                let id = "w\(i)"
                let correction = corrections[id]
                return .init(wordId: id, text: correction ?? text, original: text, correction: correction, confidence: nil)
            }
        )
    }

    func testDegismeyenMetinDuzeltmeUretmez() {
        XCTAssertEqual(CaptionLineEditor.corrections(for: line(["Merhaba", "dünya"]), newText: "  Merhaba   dünya "), [])
    }

    func testTekKelimeDegisir() {
        let edits = CaptionLineEditor.corrections(for: line(["Merhaba", "dünya", "nasılsın"]), newText: "Merhaba dunya nasılsın")
        XCTAssertEqual(edits, [WordCorrection(wordId: "w1", text: "dunya")])
    }

    func testFazlaSozcukSonKelimeyeEklenir() {
        let edits = CaptionLineEditor.corrections(for: line(["bugün", "çay", "içtik"]), newText: "bugün sıcak bir çay içtik")
        XCTAssertEqual(edits, [WordCorrection(wordId: "w0", text: "bugün sıcak bir")],
                       "araya kelime olmayan eklemeler önceki kelimeye gider")
    }

    func testEksikSozcukAradakiKelimeyiGizler() {
        let edits = CaptionLineEditor.corrections(for: line(["eee", "yani", "geldik"]), newText: "geldik")
        XCTAssertEqual(Set(edits.map(\.wordId)), ["w0", "w1"])
        XCTAssertTrue(edits.allSatisfy { $0.text == "" }, "silinen kelimeler gizlenir")
    }

    func testBosMetinSatiriGizler() {
        let edits = CaptionLineEditor.corrections(for: line(["a", "b"]), newText: "")
        XCTAssertEqual(edits, [WordCorrection(wordId: "w0", text: ""), WordCorrection(wordId: "w1", text: "")])
    }

    func testAIMetnineDonusDuzeltmeyiKaldirir() {
        let edited = line(["Merhaba", "dünya"], corrections: ["w1": "dunya"])
        XCTAssertEqual(edited.text, "Merhaba dunya")
        XCTAssertEqual(CaptionLineEditor.corrections(for: edited, newText: "Merhaba dünya"),
                       [WordCorrection(wordId: "w1", text: nil)])
        XCTAssertEqual(CaptionLineEditor.revert(edited), [WordCorrection(wordId: "w1", text: nil)])
    }

    func testFarkliSayidaDegisimSirayaDagitilir() {
        // Ortadaki iki kelime üç sözcükle değişir: ilki bir sözcük, sonuncusu kalanını alır.
        let edits = CaptionLineEditor.corrections(for: line(["bu", "x", "y", "son"]), newText: "bu bir iki üç son")
        XCTAssertEqual(edits, [WordCorrection(wordId: "w1", text: "bir"), WordCorrection(wordId: "w2", text: "iki üç")])
    }

    // MARK: - Proje ile

    func testDuzenlemeTekAdimdaUygulanirVeGeriAlinir() throws {
        let clip = Clip(clipId: F.clipA, mediaId: F.mediaId, sourceIn: F.s(0), sourceOut: F.s(10), timelineStart: F.s(0))
        let doc = F.project(clips: [clip], captionWords: [
            F.word("w1000", "eee", 1, 1.2), F.word("w1300", "bugün", 1.3, 1.6), F.word("w1700", "geldik", 1.7, 2.0),
        ])
        var history = EditHistory(doc)
        let lines = RenderPlan.editableLines(for: history.present)
        XCTAssertEqual(lines.map(\.text), ["eee bugün geldik"])

        let edits = CaptionLineEditor.corrections(for: lines[0], newText: "Bugün geldik.")
        try history.apply(.correctWords(captionTrackId: F.captionTrackId, corrections: edits))

        XCTAssertEqual(RenderPlan.captionCues(for: history.present).map(\.text), ["Bugün geldik."])
        let edited = RenderPlan.editableLines(for: history.present)
        XCTAssertEqual(edited.first?.words.count, 3, "gizli kelime listede kalır")
        XCTAssertTrue(edited.first?.isCorrected ?? false)

        history.undo()
        XCTAssertEqual(RenderPlan.captionCues(for: history.present).map(\.text), ["eee bugün geldik"], "tek geri al")
    }

    func testTumuGizlenenSatirGosterilmez() throws {
        let clip = Clip(clipId: F.clipA, mediaId: F.mediaId, sourceIn: F.s(0), sourceOut: F.s(10), timelineStart: F.s(0))
        var doc = F.project(clips: [clip], captionWords: [F.word("w1000", "eee", 1, 1.2)])
        doc = try doc.applying(.correctWords(captionTrackId: F.captionTrackId, corrections: [WordCorrection(wordId: "w1000", text: "")]))
        XCTAssertEqual(RenderPlan.captionCues(for: doc), [])
        XCTAssertEqual(RenderPlan.editableLines(for: doc).count, 1, "düzenleme listesinde geri getirilebilsin")
    }

    func testBilinmeyenKelimeReddedilir() {
        let doc = F.project(clips: [], captionWords: [F.word("w1000", "a", 1, 1.2)])
        XCTAssertThrowsError(try doc.applying(.correctWords(captionTrackId: F.captionTrackId,
                                                            corrections: [WordCorrection(wordId: "yok", text: "x")]))) {
            XCTAssertEqual($0 as? EditError, .wordNotFound)
        }
    }

    func testDusukGuvenliKelimelerIsaretlenir() {
        var l = line(["a", "b", "c"])
        l.words[1].confidence = 0.4
        l.words[2].confidence = 0.95
        XCTAssertEqual(l.uncertainWordIds(), ["w1"])
        l.words[1].correction = "B"
        XCTAssertEqual(l.uncertainWordIds(), [], "kullanıcı düzelttiyse işaretlenmez")
    }
}
