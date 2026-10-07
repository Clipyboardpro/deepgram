import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP isteğini gönderen katman. Uygulamada `URLSessionTransport`, testlerde sahtesi.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        return (data, http)
    }
}

/// /v1 API istemcisi. Her çağrıda erişim anahtarı `accessToken`'dan alınır
/// (Supabase oturumu uygulamada yenilenir; burada saklanmaz).
public struct AIJobsClient: Sendable {
    public let baseURL: URL
    private let transport: HTTPTransport
    private let accessToken: @Sendable () async throws -> String
    private let refreshAccessToken: (@Sendable () async throws -> String)?

    /// - Parameters:
    ///   - baseURL: Edge Function kökü, ör. `https://<proje>.supabase.co/functions/v1/api`.
    ///     `/v1/...` yolları bu köke eklenir.
    ///   - refreshAccessToken: Sunucu 401 döndürürse bir kez çağrılır ve istek yeni
    ///     anahtarla tekrarlanır (ör. cihaz saati kaymışken süresi dolmuş anahtar).
    public init(baseURL: URL, transport: HTTPTransport = URLSessionTransport(),
                accessToken: @escaping @Sendable () async throws -> String,
                refreshAccessToken: (@Sendable () async throws -> String)? = nil) {
        self.baseURL = baseURL
        self.transport = transport
        self.accessToken = accessToken
        self.refreshAccessToken = refreshAccessToken
    }

    public func createJob(_ request: CreateJobRequest) async throws -> CreateJobResponse {
        try await call("POST", "v1/transcription-jobs", body: request)
    }

    public func markUploaded(jobId: UUID) async throws -> Job {
        try await (call("POST", "v1/transcription-jobs/\(jobId.apiString)/uploaded") as JobEnvelope).job
    }

    public func cancel(jobId: UUID) async throws -> Job {
        try await (call("POST", "v1/transcription-jobs/\(jobId.apiString)/cancel") as JobEnvelope).job
    }

    public func job(id: UUID) async throws -> JobWithResult {
        try await call("GET", "v1/jobs/\(id.apiString)")
    }

    public func quota() async throws -> Quota {
        try await call("GET", "v1/quota")
    }

    /// Hesabın ücretsiz kotasını ister. İdempotenttir: hak daha önce verildiyse
    /// `false` döner. Miktarı sunucu belirler (CX-007).
    public func claimFreeQuota() async throws -> Bool {
        struct Response: Decodable { var granted: Bool }
        return try await (call("POST", "v1/quota/free-claim") as Response).granted
    }

    /// Sesi sunucunun verdiği imzalı adrese yükler. İmzalı adres kendi
    /// yetkisini taşıdığı için oturum anahtarı gönderilmez.
    public func upload(_ data: Data, to upload: Upload) async throws {
        var request = URLRequest(url: upload.url)
        request.httpMethod = upload.method
        for (name, value) in upload.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = data
        let (_, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.uploadFailed(status: response.statusCode)
        }
    }

    // MARK: - İç

    private struct Empty: Encodable {}

    private func call<Response: Decodable>(_ method: String, _ path: String) async throws -> Response {
        try await call(method, path, body: Optional<Empty>.none)
    }

    private func call<Response: Decodable, Body: Encodable>(_ method: String, _ path: String, body: Body?) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        var (data, response) = try await send(request)
        if response.statusCode == 401, let refreshAccessToken {
            request.setValue("Bearer \(try await refreshAccessToken())", forHTTPHeaderField: "Authorization")
            (data, response) = try await send(request)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw Self.error(status: response.statusCode, body: data)
        }
        do {
            return try JSONDecoder.api.decode(Response.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch let error as APIError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw APIError.transport(String(describing: error))
        }
    }

    static func error(status: Int, body: Data) -> APIError {
        struct Envelope: Decodable {
            struct Inner: Decodable { var code: String; var requestId: String? }
            var error: Inner
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: body) else {
            return .unexpectedStatus(status)
        }
        return .server(status: status, code: APIErrorCode(rawValue: envelope.error.code), requestId: envelope.error.requestId)
    }
}

extension UUID {
    /// Sunucu küçük harfli UUID kullanır; Swift'in `uuidString`'i büyük harflidir.
    var apiString: String { uuidString.lowercased() }
}

extension JSONDecoder {
    /// Sunucu tarihleri ISO 8601; Postgres'ten gelenler mikro saniye ve
    /// `+00:00` biçiminde olabilir.
    static var api: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = APIDate.parse(raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Geçersiz tarih: \(raw)"))
            }
            return date
        }
        return decoder
    }
}

enum APIDate {
    static func parse(_ raw: String) -> Date? {
        // Kesirli saniyeyi milisaniyeye indir: ISO8601DateFormatter en fazla 3 hane bekler.
        var text = raw
        if let dot = text.firstIndex(of: "."),
           let end = text[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) ?? Optional(text.endIndex) {
            let digits = text[text.index(after: dot)..<end]
            let millis = String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            text.replaceSubrange(dot..<end, with: "." + millis)
        }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
