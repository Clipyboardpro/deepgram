import Foundation

/// `project.json` okuma/yazma ve şema göçleri.
public enum ProjectCodec {
    public enum Error: Swift.Error, Equatable {
        /// Dosya bu uygulama sürümünden yeni bir sürümle yazılmış.
        case newerSchemaVersion(Int)
        case missingSchemaVersion
    }

    /// Eski şemayı bir sonrakine taşıyan adım: `from` sürümündeki JSON'u
    /// `from + 1` sürümüne çevirir. Şema değiştiğinde buraya eklenir ve eski
    /// örnek dosyalarla test edilir.
    struct Migration {
        let from: Int
        let migrate: (inout [String: Any]) throws -> Void
    }

    static let migrations: [Migration] = []

    public static func encode(_ document: ProjectDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ProjectTimestamp.format(date))
        }
        return try encoder.encode(document)
    }

    public static func decode(_ data: Data) throws -> ProjectDocument {
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var version = json["schemaVersion"] as? Int else {
            throw Error.missingSchemaVersion
        }
        guard version <= ProjectDocument.currentSchemaVersion else {
            throw Error.newerSchemaVersion(version)
        }
        while version < ProjectDocument.currentSchemaVersion {
            guard let step = migrations.first(where: { $0.from == version }) else { break }
            try step.migrate(&json)
            version += 1
            json["schemaVersion"] = version
        }
        let migrated = try JSONSerialization.data(withJSONObject: json)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = ProjectTimestamp.parse(raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Geçersiz tarih: \(raw)"))
            }
            return date
        }
        return try decoder.decode(ProjectDocument.self, from: migrated)
    }

    /// Atomik yazma: önce geçici dosyaya, sonra yer değiştirme. Yarım kalan
    /// yazma mevcut projeyi bozmaz.
    public static func write(_ document: ProjectDocument, to url: URL) throws {
        try encode(document).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> ProjectDocument {
        try decode(Data(contentsOf: url))
    }
}

/// Proje zaman damgaları milisaniye hassasiyetinde tutulur ve ISO 8601
/// (kesirli saniyeli) yazılır; böylece kaydet → aç birebir aynı değeri verir.
public enum ProjectTimestamp {
    /// Bir anı milisaniyeye yuvarlar. Projeye yazılan her tarih buradan geçer.
    public static func normalize(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: normalize(date))
    }

    static func parse(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return normalize(date) }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
