import XCTest
@testable import EditorDomain

final class CaptionTests: XCTestCase {
    typealias F = Fixtures

    // MARK: - Transcript sözleşmesi

    func testTranscriptCozulurBilinmeyenAlanYokSayilir() throws {
        let t = try Transcript.decode(from: F.transcriptJSON)
        XCTAssertEqual(t.language, "tr")
        XCTAssertEqual(t.words.count, 3)
        XCTAssertEqual(t.words[0].display, "Merhaba,")
        XCTAssertNil(t.words[1].display)
        XCTAssertNil(t.words[1].confidence)
    }

    func testDahaYeniTranscriptSemasiReddedilir() {
        let json = #"{"schemaVersion":2,"provider":"x","model":"y","language":"tr","durationSeconds":1,"words":[]}"#
        XCTAssertThrowsError(try Transcript.decode(from: Data(json.utf8))) { error in
            XCTAssertEqual(error as? Transcript.DecodingError, .unsupportedSchemaVersion(2))
        }
    }

    func testKelimelerKaynakZamaninaCevrilirSifirSureliAtilir() throws {
        let t = try Transcript.decode(from: F.transcriptJSON)
        // Ses kaynak medyanın 10. saniyesinden itibaren çıkarılmış.
        let track = CaptionTrack.make(from: t, mediaId: F.mediaId, audioSourceStart: F.s(10))
        XCTAssertEqual(track.words.map(\.id), ["w10120", "w10600"])
        XCTAssertEqual(track.words[0].sourceStart, F.s(10.12))
        XCTAssertEqual(track.words[0].display, "Merhaba,")
        XCTAssertEqual(track.words[1].display, "nasılsın", "display yoksa text kullanılır")
    }

    func testAyniAndaBaslayanKelimelerAyriKimlikAlir() {
        let t = Transcript(schemaVersion: 1, provider: "p", model: "m", language: "tr", durationSeconds: 1, words: [
            .init(text: "a", start: 0.5, end: 0.6), .init(text: "b", start: 0.5, end: 0.7),
        ])
        XCTAssertEqual(CaptionTrack.make(from: t, mediaId: F.mediaId).words.map(\.id), ["w500", "w500-2"])
    }

    // MARK: - Kullanıcı düzeltmesi korunur

    func testYenidenGelenAISonucuKullaniciDuzeltmesiniEzmez() throws {
        var track = CaptionTrack.make(from: try Transcript.decode(from: F.transcriptJSON), mediaId: F.mediaId)
        track.corrections["w120"] = "Selam,"
        track.corrections["w600"] = "naber"

        // Yeni sonuçta ilk kelime aynı yerde, ikinci kelime farklı zamanda.
        let rerun = Transcript(schemaVersion: 1, provider: "deepgram", model: "nova-3", language: "tr", durationSeconds: 3, words: [
            .init(text: "merhaba", start: 0.12, end: 0.50),
            .init(text: "nasılsın", start: 0.65, end: 1.10),
        ])
        let orphaned = track.applyAIResult(rerun)

        XCTAssertEqual(track.displayText(for: track.words[0]), "Selam,", "aynı yerdeki kelimenin düzeltmesi korunur")
        XCTAssertEqual(track.displayText(for: track.words[1]), "nasılsın")
        XCTAssertEqual(orphaned, ["w600": "naber"], "eşleşmeyen düzeltme sessizce kaybolmaz")
    }

    // MARK: - Zaman çizelgesine yerleşim

    func testHizDegisinceAltyaziZamanlariDonusur() {
        // Kaynakta 10–20 sn, 2x hızla, zaman çizelgesinde 5. saniyeden itibaren.
        let clip = Clip(clipId: F.clipA, mediaId: F.mediaId, sourceIn: F.s(10), sourceOut: F.s(20), timelineStart: F.s(5), playbackRate: 2)
        let doc = F.project(clips: [clip], captionWords: [F.word("w12000", "merhaba", 12, 13)])

        let words = doc.timelineWords(for: doc.captionTracks[0])
        XCTAssertEqual(words.map(\.range), [TimeRange(start: F.s(6), end: F.s(6.5))])  // 5 + (12−10)/2, 5 + (13−10)/2
    }

    func testAyniKaynaginIkiKesitiCozumlemeTekrarlanmadanKullanilir() {
        let first = Clip(clipId: F.clipA, mediaId: F.mediaId, sourceIn: F.s(0), sourceOut: F.s(5), timelineStart: F.s(0))
        let second = Clip(clipId: F.clipB, mediaId: F.mediaId, sourceIn: F.s(2), sourceOut: F.s(4), timelineStart: F.s(5))
        let doc = F.project(clips: [first, second], captionWords: [F.word("w3000", "tekrar", 3, 3.5)])

        let words = doc.timelineWords(for: doc.captionTracks[0])
        XCTAssertEqual(words.map(\.clipId), [F.clipA, F.clipB])
        XCTAssertEqual(words.map(\.range.start), [F.s(3), F.s(6)])
    }

    func testKlipDisindakiKelimeGosterilmezTasanKelimeKirpilir() {
        let clip = Clip(clipId: F.clipA, mediaId: F.mediaId, sourceIn: F.s(10), sourceOut: F.s(12), timelineStart: F.s(0))
        let doc = F.project(clips: [clip], captionWords: [
            F.word("w9500", "önce", 9.5, 10.2),     // başlangıcı klipte değil
            F.word("w11800", "taşan", 11.8, 12.5),  // sonu klip dışına taşıyor
        ])
        let words = doc.timelineWords(for: doc.captionTracks[0])
        XCTAssertEqual(words.map(\.text), ["taşan"])
        XCTAssertEqual(words.first?.range.end, F.s(2))
    }

    func testDuzeltilmisMetinZamanCizelgesindeGorunur() throws {
        let clip = Clip(clipId: F.clipA, mediaId: F.mediaId, sourceIn: F.s(0), sourceOut: F.s(5), timelineStart: F.s(0))
        var doc = F.project(clips: [clip], captionWords: [F.word("w1000", "merhba", 1, 1.5)])
        doc = try doc.applying(.correctWord(captionTrackId: F.captionTrackId, wordId: "w1000", text: "merhaba"))
        XCTAssertEqual(doc.timelineWords(for: doc.captionTracks[0]).first?.text, "merhaba")
        XCTAssertEqual(doc.captionTracks[0].words[0].sourceStart, F.s(1), "düzeltme zamanı değiştirmez")
    }

    // MARK: - Satır gruplama

    func testSatirlarCumleSonuSessizlikVeUzunluktaBolunur() {
        func w(_ text: String, _ start: Double, _ end: Double) -> TimelineWord {
            TimelineWord(wordId: text, clipId: F.clipA, text: text, range: TimeRange(start: F.s(start), end: F.s(end)))
        }
        let words = [
            w("Merhaba", 0.0, 0.4), w("arkadaşlar.", 0.5, 1.0),  // cümle sonu
            w("Bugün", 1.1, 1.4), w("çay", 1.5, 1.7),
            w("konuşacağız", 2.8, 3.4),                            // 1.1 sn sessizlik
        ]
        let lines = CaptionLineBuilder().lines(from: words)
        XCTAssertEqual(lines.map(\.text), ["Merhaba arkadaşlar.", "Bugün çay", "konuşacağız"])
        XCTAssertEqual(lines[1].range, TimeRange(start: F.s(1.1), end: F.s(1.7)))

        let narrow = CaptionLineBuilder(maxCharacters: 10).lines(from: Array(words.prefix(2)))
        XCTAssertEqual(narrow.count, 2, "karakter sınırı aşılınca bölünür")
    }
}
