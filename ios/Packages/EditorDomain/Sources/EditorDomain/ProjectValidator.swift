import Foundation

/// Proje modelinin tutarlılık kuralları. Düzenleme komutlarından sonra ve
/// diskten okunan projelerde çalıştırılır.
public enum ProjectValidator {
    public enum Issue: Equatable, Sendable {
        case missingMedia(clipId: UUID, mediaId: UUID)
        case emptySourceRange(clipId: UUID)
        case sourceOutOfBounds(clipId: UUID)
        case rateOutOfRange(clipId: UUID)
        case negativeTimelineStart(clipId: UUID)
        case overlappingClips(trackId: UUID, first: UUID, second: UUID)
        case captionMediaMissing(captionTrackId: UUID)
    }

    public static func validate(_ doc: ProjectDocument) -> [Issue] {
        var issues: [Issue] = []

        for track in doc.tracks {
            for clip in track.clips {
                guard let asset = doc.asset(clip.mediaId) else {
                    issues.append(.missingMedia(clipId: clip.clipId, mediaId: clip.mediaId))
                    continue
                }
                if clip.sourceRange.isEmpty {
                    issues.append(.emptySourceRange(clipId: clip.clipId))
                }
                if clip.sourceIn < .zero || clip.sourceOut > asset.duration {
                    issues.append(.sourceOutOfBounds(clipId: clip.clipId))
                }
                if !Clip.allowedRates.contains(clip.playbackRate) {
                    issues.append(.rateOutOfRange(clipId: clip.clipId))
                }
                if clip.timelineStart < .zero {
                    issues.append(.negativeTimelineStart(clipId: clip.clipId))
                }
            }

            let sorted = track.clips.sorted { $0.timelineStart < $1.timelineStart }
            for (a, b) in zip(sorted, sorted.dropFirst()) where a.timelineRange.overlaps(b.timelineRange) {
                issues.append(.overlappingClips(trackId: track.trackId, first: a.clipId, second: b.clipId))
            }
        }

        for captionTrack in doc.captionTracks where doc.asset(captionTrack.mediaId) == nil {
            issues.append(.captionMediaMissing(captionTrackId: captionTrack.captionTrackId))
        }
        return issues
    }
}
