import XCTest
@testable import EditorDomain

final class MediaTimeTests: XCTestCase {
    func testFarkliOlceklerdeAyniAnEsit() {
        XCTAssertEqual(MediaTime(value: 600, timescale: 600), MediaTime(value: 1, timescale: 1))
        XCTAssertEqual(MediaTime(value: 1001, timescale: 30000).hashValue, MediaTime(value: 1001, timescale: 30000).hashValue)
    }

    func testToplamaVeCikarmaOrtakOlcekte() {
        let a = MediaTime(value: 1, timescale: 30)   // 1/30 s
        let b = MediaTime(value: 1, timescale: 25)   // 1/25 s
        let sum = a + b
        XCTAssertEqual(sum.timescale, 150)
        XCTAssertEqual(sum.value, 11)                // 5/150 + 6/150
        XCTAssertEqual(b - a, MediaTime(value: 1, timescale: 150))
    }

    func testKarsilastirma() {
        XCTAssertLessThan(MediaTime(seconds: 1.5), MediaTime(value: 2, timescale: 1))
        XCTAssertGreaterThan(MediaTime(value: 30001, timescale: 30000), MediaTime(value: 1, timescale: 1))
    }

    func testSaniyedenYuvarlama() {
        XCTAssertEqual(MediaTime(seconds: 0.12).value, 72)          // 0.12 × 600
        XCTAssertEqual(MediaTime(seconds: 1 / 3.0).value, 200)
    }

    func testHizBolme() {
        XCTAssertEqual(MediaTime(seconds: 10).divided(by: 2), MediaTime(seconds: 5))
        XCTAssertEqual(MediaTime(seconds: 10).divided(by: 0.5), MediaTime(seconds: 20))
    }

    func testYariAcikAralik() {
        let range = TimeRange(start: MediaTime(seconds: 1), end: MediaTime(seconds: 2))
        XCTAssertTrue(range.contains(MediaTime(seconds: 1)))
        XCTAssertFalse(range.contains(MediaTime(seconds: 2)))
        XCTAssertFalse(range.overlaps(TimeRange(start: MediaTime(seconds: 2), end: MediaTime(seconds: 3))))
    }

    func testCodableValueTimescaleOlarakSaklanir() throws {
        let data = try JSONEncoder().encode(MediaTime(value: 1001, timescale: 30000))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Int])
        XCTAssertEqual(json, ["value": 1001, "timescale": 30000])
    }
}
