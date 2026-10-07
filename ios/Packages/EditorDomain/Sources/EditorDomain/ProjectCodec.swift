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
        encoder.dateEncodingStrategy = .iso8601
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
        decoder.dateDecodingStrategy = .iso8601
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
