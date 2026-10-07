import XCTest
@testable import EditorDomain

/// Sunucu sözleşmesiyle çapraz kontrol: `contracts/examples/transcript-v1.json`
/// (backend tarafının yazdığı örnek) Swift çözücüsüyle okunabilmeli. Örnek
/// değişip istemciyi bozarsa bu test yakalar.
final class ContractTests: XCTestCase {
    private var exampleURL: URL {
        // .../ios/Packages/EditorDomain/Tests/EditorDomainTests/ContractTests.swift → repo kökü
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/examples/transcript-v1.json")
    }

    func testSunucuOrnekTranscriptiCozulur() throws {
        guard FileManager.default.fileExists(atPath: exampleURL.path) else {
            throw XCTSkip("contracts/examples/transcript-v1.json bu dalda yok")
        }
        let transcript = try Transcript.decode(from: Data(contentsOf: exampleURL))
        XCTAssertEqual(transcript.schemaVersion, 1)
        XCTAssertFalse(transcript.words.isEmpty)

        let track = CaptionTrack.make(from: transcript, mediaId: Fixtures.mediaId)
        XCTAssertEqual(track.words.count, transcript.words.filter { $0.end > $0.start }.count)
    }
}
