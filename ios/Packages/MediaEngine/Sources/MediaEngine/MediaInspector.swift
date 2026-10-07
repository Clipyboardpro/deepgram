import AVFoundation
import EditorDomain

public enum MediaEngineError: Error, Equatable, Sendable {
    /// Dosya açılamadı ya da medya değil.
    case unreadable
    case noAudioTrack
    case emptyRange
    case exportFailed(String)
}

/// İçe alınan bir medyanın temel bilgileri.
public struct MediaProbe: Equatable, Sendable {
    public var duration: MediaTime
    public var hasVideo: Bool
    public var hasAudio: Bool
    /// Telefonun yön bilgisi (preferredTransform) uygulanmış görüntü boyutu.
    /// Dikey çekilen bir iPhone videosu 1920×1080 kaydedilir ama 1080×1920 görünür.
    public var displaySize: CGSize?
    public var nominalFrameRate: Float?

    public func mediaAsset(relativePath: String, mediaId: UUID = UUID()) -> MediaAsset {
        MediaAsset(mediaId: mediaId, kind: hasVideo ? .video : .audio, relativePath: relativePath,
                   duration: duration, hasAudio: hasAudio)
    }
}

public enum MediaInspector {
    public static func probe(_ url: URL) async throws -> MediaProbe {
        let asset = AVURLAsset(url: url)
        let duration: CMTime
        let videoTracks: [AVAssetTrack]
        let audioTracks: [AVAssetTrack]
        do {
            guard try await asset.load(.isReadable) else { throw MediaEngineError.unreadable }
            duration = try await asset.load(.duration)
            videoTracks = try await asset.loadTracks(withMediaType: .video)
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch let error as MediaEngineError {
            throw error
        } catch {
            throw MediaEngineError.unreadable
        }
        guard duration.isNumeric, duration.seconds > 0, !(videoTracks.isEmpty && audioTracks.isEmpty) else {
            throw MediaEngineError.unreadable
        }

        var displaySize: CGSize?
        var frameRate: Float?
        if let video = videoTracks.first {
            let (natural, transform, fps) = try await video.load(.naturalSize, .preferredTransform, .nominalFrameRate)
            let rect = CGRect(origin: .zero, size: natural).applying(transform)
            displaySize = CGSize(width: abs(rect.width).rounded(), height: abs(rect.height).rounded())
            frameRate = fps
        }

        return MediaProbe(
            duration: MediaTime(duration),
            hasVideo: !videoTracks.isEmpty,
            hasAudio: !audioTracks.isEmpty,
            displaySize: displaySize,
            nominalFrameRate: frameRate
        )
    }
}

extension MediaTime {
    /// CMTime'dan; geçersiz/sonsuz değerler sıfır olur.
    public init(_ time: CMTime) {
        guard time.isNumeric, time.timescale > 0 else {
            self = .zero
            return
        }
        self.init(value: time.value, timescale: time.timescale)
    }

    public var cmTime: CMTime { CMTime(value: value, timescale: timescale) }
}

extension TimeRange {
    public var cmTimeRange: CMTimeRange { CMTimeRange(start: start.cmTime, end: end.cmTime) }
}
