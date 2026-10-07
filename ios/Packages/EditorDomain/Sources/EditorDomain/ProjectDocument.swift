import Foundation

/// Bir projenin tamamı. `project.json` olarak saklanır; değer tipidir, her
/// düzenleme yeni bir anlık görüntü üretir.
public struct ProjectDocument: Equatable, Sendable, Codable {
    /// Bu kodun yazdığı şema sürümü. Değişirse `ProjectCodec`'e göç eklenir.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var projectId: UUID
    /// Her düzenlemede bir artar. Dışa aktarma sabit bir revision üzerinde çalışır.
    public var revision: Int
    /// Kullanıcının verdiği ad. Eski dosyalarda yoktur (opsiyonel; şema v1).
    public var title: String?
    public var canvas: Canvas
    public var mediaAssets: [MediaAsset]
    public var tracks: [Track]
    public var captionTracks: [CaptionTrack]
    public var templateVersion: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        projectId: UUID = UUID(),
        title: String? = nil,
        canvas: Canvas = .vertical1080p,
        mediaAssets: [MediaAsset] = [],
        tracks: [Track] = [],
        captionTracks: [CaptionTrack] = [],
        templateVersion: String? = nil,
        createdAt: Date = Date()
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.projectId = projectId
        self.revision = 0
        self.title = title
        self.canvas = canvas
        self.mediaAssets = mediaAssets
        self.tracks = tracks
        self.captionTracks = captionTracks
        self.templateVersion = templateVersion
        self.createdAt = ProjectTimestamp.normalize(createdAt)
        self.updatedAt = self.createdAt
    }

    public func asset(_ mediaId: UUID) -> MediaAsset? {
        mediaAssets.first { $0.mediaId == mediaId }
    }

    /// Klibi ve bulunduğu kanalın indeksini döner.
    public func locateClip(_ clipId: UUID) -> (trackIndex: Int, clipIndex: Int)? {
        for (t, track) in tracks.enumerated() {
            if let c = track.clips.firstIndex(where: { $0.clipId == clipId }) {
                return (t, c)
            }
        }
        return nil
    }

    /// Projenin zaman çizelgesi süresi (en geç biten klip).
    public var duration: MediaTime {
        tracks.flatMap(\.clips).map(\.timelineRange.end).max() ?? .zero
    }
}

public struct Canvas: Equatable, Sendable, Codable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var colorPolicy: ColorPolicy

    public init(width: Int, height: Int, fps: Int, colorPolicy: ColorPolicy = .sdr) {
        self.width = width
        self.height = height
        self.fps = fps
        self.colorPolicy = colorPolicy
    }

    /// İlk sürümün hedefi: 1080×1920, 30 fps, SDR.
    public static let vertical1080p = Canvas(width: 1080, height: 1920, fps: 30)

    public enum ColorPolicy: String, Sendable, Codable {
        case sdr
    }
}

public struct MediaAsset: Equatable, Sendable, Codable {
    public var mediaId: UUID
    public var kind: Kind
    /// Proje klasörüne göre yol (ör. `Media/abc.mov`). Geçici Photos/Files
    /// adreslerine kalıcı bağımlılık kurulmaz.
    public var relativePath: String
    public var duration: MediaTime
    public var hasAudio: Bool

    public init(mediaId: UUID = UUID(), kind: Kind, relativePath: String, duration: MediaTime, hasAudio: Bool) {
        self.mediaId = mediaId
        self.kind = kind
        self.relativePath = relativePath
        self.duration = duration
        self.hasAudio = hasAudio
    }

    public enum Kind: String, Sendable, Codable {
        case video, audio, image
    }
}

public struct Track: Equatable, Sendable, Codable {
    public var trackId: UUID
    public var kind: Kind
    /// `timelineStart`'a göre sıralı tutulur.
    public var clips: [Clip]

    public init(trackId: UUID = UUID(), kind: Kind, clips: [Clip] = []) {
        self.trackId = trackId
        self.kind = kind
        self.clips = clips.sorted { $0.timelineStart < $1.timelineStart }
    }

    public enum Kind: String, Sendable, Codable {
        case video, audio
    }
}

public struct Clip: Equatable, Sendable, Codable {
    public static let allowedRates: ClosedRange<Double> = 0.25...4

    public var clipId: UUID
    public var mediaId: UUID
    /// Kaynak medyada kullanılan aralık [sourceIn, sourceOut).
    public var sourceIn: MediaTime
    public var sourceOut: MediaTime
    public var timelineStart: MediaTime
    public var playbackRate: Double
    public var transform: Transform
    public var volume: Double

    public init(
        clipId: UUID = UUID(),
        mediaId: UUID,
        sourceIn: MediaTime,
        sourceOut: MediaTime,
        timelineStart: MediaTime,
        playbackRate: Double = 1,
        transform: Transform = .identity,
        volume: Double = 1
    ) {
        self.clipId = clipId
        self.mediaId = mediaId
        self.sourceIn = sourceIn
        self.sourceOut = sourceOut
        self.timelineStart = timelineStart
        self.playbackRate = playbackRate
        self.transform = transform
        self.volume = volume
    }

    public var sourceRange: TimeRange { TimeRange(start: sourceIn, end: sourceOut) }

    /// Zaman çizelgesindeki süre: kaynak süresi / hız.
    public var timelineDuration: MediaTime { (sourceOut - sourceIn).divided(by: playbackRate) }

    public var timelineRange: TimeRange {
        TimeRange(start: timelineStart, end: timelineStart + timelineDuration)
    }

    /// Kaynak medyadaki bir anın zaman çizelgesindeki karşılığı. Kaynak an
    /// bu klipte kullanılmıyorsa nil.
    public func timelineTime(forSource source: MediaTime) -> MediaTime? {
        guard sourceRange.contains(source) else { return nil }
        return timelineStart + (source - sourceIn).divided(by: playbackRate)
    }

    /// Zaman çizelgesindeki bir anın kaynak medyadaki karşılığı.
    public func sourceTime(forTimeline time: MediaTime) -> MediaTime? {
        guard timelineRange.contains(time) else { return nil }
        return sourceIn + (time - timelineStart).multiplied(by: playbackRate)
    }
}

/// Görüntü dönüşümü (kanvas üzerinde). Birimler kanvasa görelidir.
public struct Transform: Equatable, Sendable, Codable {
    public var scale: Double
    public var offsetX: Double
    public var offsetY: Double
    public var rotationDegrees: Double

    public init(scale: Double = 1, offsetX: Double = 0, offsetY: Double = 0, rotationDegrees: Double = 0) {
        self.scale = scale
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.rotationDegrees = rotationDegrees
    }

    public static let identity = Transform()
}
