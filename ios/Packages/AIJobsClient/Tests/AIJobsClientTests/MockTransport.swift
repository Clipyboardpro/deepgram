import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AIJobsClient

/// Gönderilen istekleri kaydeden ve sırayla hazır yanıt veren sahte taşıyıcı.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    struct Recorded {
        var method: String
        var url: URL
        var headers: [String: String]
        var body: Data?
        var json: [String: Any]? { body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
    }

    private let lock = NSLock()
    private var responses: [(Int, String)]
    private(set) var requests: [Recorded] = []

    init(_ responses: [(status: Int, body: String)]) {
        self.responses = responses.map { ($0.status, $0.body) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try lock.withLock {
            requests.append(Recorded(
                method: request.httpMethod ?? "GET",
                url: request.url!,
                headers: request.allHTTPHeaderFields ?? [:],
                body: request.httpBody
            ))
            guard !responses.isEmpty else { throw URLError(.notConnectedToInternet) }
            let (status, body) = responses.removeFirst()
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }
}

/// Sözleşmedeki biçimde örnek yanıtlar.
enum Samples {
    static let base = URL(string: "https://proje.supabase.co/functions/v1/api")!
    static let jobId = "6f1c2b0a-9d3e-4c5b-8a71-2e4f6a8b9c0d"
    static let sha = String(repeating: "a", count: 64)

    static func job(_ status: String, errorCode: String? = nil) -> String {
        let code = errorCode.map { "\"\($0)\"" } ?? "null"
        return #"{"id":"\#(jobId)","status":"\#(status)","createdAt":"2026-10-07T12:42:01.123456+00:00","errorCode":\#(code)}"#
    }

    static let upload = #"{"url":"https://proje.supabase.co/storage/v1/object/upload/sign/transcription-audio/u/\#(jobId).m4a?token=abc","method":"PUT","headers":{"Content-Type":"audio/mp4"},"expiresAt":"2026-10-07T13:12:01+00:00"}"#

    static func created(upload: Bool = true, status: String = "awaiting_upload") -> String {
        #"{"job":\#(job(status)),"upload":\#(upload ? Self.upload : "null")}"#
    }

    static let transcript = #"{"schemaVersion":1,"provider":"deepgram","model":"nova-3","language":"tr","durationSeconds":1.2,"words":[{"text":"merhaba","display":"Merhaba,","start":0.12,"end":0.48,"confidence":0.98}]}"#

    static func jobWithResult(_ status: String, result: Bool, errorCode: String? = nil) -> String {
        let r = result ? #"{"transcript":\#(transcript),"expiresAt":"2026-10-14T12:42:01Z"}"# : "null"
        return #"{"job":\#(job(status, errorCode: errorCode)),"result":\#(r)}"#
    }

    static func error(_ code: String) -> String {
        #"{"error":{"code":"\#(code)","requestId":"0b8e5c1a-1111-4222-8333-944455556666"}}"#
    }
}
