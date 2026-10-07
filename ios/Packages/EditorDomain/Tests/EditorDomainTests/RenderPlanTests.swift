import XCTest
@testable import EditorDomain

final class RenderPlanTests: XCTestCase {
    typealias F = Fixtures

    func testSatirlarZamanCizelgesindeSiraliVeCakismasiz() throws {
        let clip = Clip(clipId: F.clipA, mediaId: F.mediaId, sourceIn: F.s(0), sourceOut: F.s(10), timelineStart: F.s(0))
        var doc = F.project(clips: [clip], captionWords: [
            F.word("w1000", "Merhaba.", 1, 1.5),
            F.word("w1400", "Bugün", 1.4, 1.8),   // öncekiyle üst üste biniyor
            F.word("w5000", "sonra", 5, 5.5),
        ])
        doc.captionTracks[0].corrections["w5000"] = "Sonra"

        let cues = RenderPlan.captionCues(for: doc)
        XCTAssertEqual(cues.map(\.text), ["Merhaba.", "Bugün", "Sonra"], "cümle sonu böler; düzeltme uygulanır")
        for (a, b) in zip(cues, cues.dropFirst()) {
            XCTAssertLessThanOrEqual(a.range.end, b.range.start, "satırlar üst üste binmez")
        }
        XCTAssertEqual(cues[0].range.end, F.s(1.4))
    }

    func testAnlikSatir() {
        let cues = [CaptionCue(text: "a", range: TimeRange(start: F.s(1), end: F.s(2)))]
        XCTAssertEqual(RenderPlan.cue(at: F.s(1.5), in: cues)?.text, "a")
        XCTAssertNil(RenderPlan.cue(at: F.s(2), in: cues), "bitiş anı dahil değil")
        XCTAssertNil(RenderPlan.cue(at: F.s(0.5), in: cues))
    }

    func testOlculerKanvasaGoreli() {
        let style = CaptionStyle.standard
        XCTAssertEqual(style.fontSize(forCanvasHeight: 1920), 65.28, accuracy: 0.01)
        XCTAssertEqual(style.fontSize(forCanvasHeight: 480) * 4, style.fontSize(forCanvasHeight: 1920), accuracy: 0.001,
                       "önizleme ile çıktı aynı oranda")
        XCTAssertEqual(style.maxWidth(forCanvasWidth: 1080), 907.2, accuracy: 0.01)
    }
}
