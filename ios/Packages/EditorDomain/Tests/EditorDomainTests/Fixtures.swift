import Foundation
@testable import EditorDomain

/// Testlerde tekrar kullanılan sabit kimlikler ve küçük proje kurucuları.
enum Fixtures {
    static let mediaId = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    static let trackId = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    static let clipA = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
    static let clipB = UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!
    static let captionTrackId = UUID(uuidString: "00000000-0000-0000-0000-00000000000D")!
    static let fixedDate = Date(timeIntervalSince1970: 1_791_000_000)

    static func s(_ seconds: Double) -> MediaTime { MediaTime(seconds: seconds) }

    static func asset(duration: Double = 60) -> MediaAsset {
        MediaAsset(mediaId: mediaId, kind: .video, relativePath: "Media/kaynak.mov", duration: s(duration), hasAudio: true)
    }

    /// 60 sn'lik tek kaynak, tek video kanalı, verilen klipler.
    static func project(clips: [Clip], captionWords: [CaptionTrack.SourceWord] = []) -> ProjectDocument {
        ProjectDocument(
            projectId: UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!,
            mediaAssets: [asset()],
            tracks: [Track(trackId: trackId, kind: .video, clips: clips)],
            captionTracks: [CaptionTrack(captionTrackId: captionTrackId, mediaId: mediaId, language: "tr", words: captionWords)],
            createdAt: fixedDate
        )
    }

    static func word(_ id: String, _ text: String, _ start: Double, _ end: Double) -> CaptionTrack.SourceWord {
        CaptionTrack.SourceWord(id: id, text: text, display: text, sourceStart: s(start), sourceEnd: s(end), confidence: nil)
    }

    static let transcriptJSON = """
    {
      "schemaVersion": 1,
      "provider": "deepgram",
      "model": "nova-3",
      "language": "tr",
      "durationSeconds": 3.2,
      "unknownField": {"ignored": true},
      "words": [
        { "text": "merhaba", "display": "Merhaba,", "start": 0.12, "end": 0.48, "confidence": 0.98 },
        { "text": "nasılsın", "start": 0.60, "end": 1.10 },
        { "text": "bozuk", "start": 2.0, "end": 2.0 }
      ]
    }
    """.data(using: .utf8)!
}
