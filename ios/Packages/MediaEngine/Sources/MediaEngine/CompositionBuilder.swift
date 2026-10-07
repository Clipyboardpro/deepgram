import AVFoundation
import EditorDomain

/// Projeden üretilmiş oynatılabilir kompozisyon. Önizleme ve (ileride)
/// dışa aktarma aynı yapıyı kullanır; böylece ikisi aynı kurallarla çizilir.
public struct BuiltComposition: @unchecked Sendable {
    public let composition: AVComposition
    /// Görüntü yokken nil.
    public let videoComposition: AVVideoComposition?
    public let audioMix: AVAudioMix?
    /// Hangi proje revizyonundan üretildi (dışa aktarma sabit revizyonda çalışır).
    public let revision: Int

    public var duration: CMTime { composition.duration }

    public func makePlayerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        item.audioMix = audioMix
        return item
    }
}

public enum CompositionError: Error, Equatable, Sendable {
    case missingMedia(UUID)
    case unreadableMedia(UUID)
}

/// `ProjectDocument` → AVFoundation kompozisyonu.
///
/// Kurallar: ilk video kanalındaki klipler zaman çizelgesindeki yerlerine
/// konur; klip arasındaki boşluk siyah/sessizdir; hız `scaleTimeRange` ile
/// uygulanır; görüntü telefonun yön bilgisi düzeltilip kanvası dolduracak
/// biçimde (aspect fill) ortalanır; klibin `transform` ölçek/kaydırması
/// bunun üstüne eklenir.
public struct CompositionBuilder: Sendable {
    private let resolveURL: @Sendable (MediaAsset) -> URL

    /// - Parameter resolveURL: Medyanın diskteki yeri (ör. `ProjectRepository.url(forMedia:in:)`).
    public init(resolveURL: @escaping @Sendable (MediaAsset) -> URL) {
        self.resolveURL = resolveURL
    }

    public func build(_ document: ProjectDocument) async throws -> BuiltComposition {
        let composition = AVMutableComposition()
        let clips = document.tracks.first { $0.kind == .video }?.clips
            .sorted { $0.timelineStart < $1.timelineStart } ?? []

        guard !clips.isEmpty,
              let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
            return BuiltComposition(composition: composition, videoComposition: nil, audioMix: nil, revision: document.revision)
        }

        let renderSize = CGSize(width: document.canvas.width, height: document.canvas.height)
        var instructions: [AVMutableVideoCompositionInstruction] = []
        let audioParameters = AVMutableAudioMixInputParameters(track: audioTrack)
        var cursor = CMTime.zero

        for clip in clips {
            guard let media = document.asset(clip.mediaId) else { throw CompositionError.missingMedia(clip.mediaId) }
            let asset = AVURLAsset(url: resolveURL(media))
            let sourceVideo: AVAssetTrack
            let sourceAudio: AVAssetTrack?
            let natural: CGSize
            let preferred: CGAffineTransform
            do {
                guard let v = try await asset.loadTracks(withMediaType: .video).first else {
                    throw CompositionError.unreadableMedia(clip.mediaId)
                }
                sourceVideo = v
                sourceAudio = try await asset.loadTracks(withMediaType: .audio).first
                (natural, preferred) = try await v.load(.naturalSize, .preferredTransform)
            } catch let error as CompositionError {
                throw error
            } catch {
                throw CompositionError.unreadableMedia(clip.mediaId)
            }

            // Önceki klipten sonra boşluk varsa siyah/sessiz aralık.
            let start = clip.timelineStart.cmTime
            if start > cursor {
                let gap = CMTimeRange(start: cursor, end: start)
                videoTrack.insertEmptyTimeRange(gap)
                audioTrack.insertEmptyTimeRange(gap)
                instructions.append(Self.instruction(for: gap, layers: []))
                cursor = start
            }

            let sourceRange = clip.sourceRange.cmTimeRange
            do {
                try videoTrack.insertTimeRange(sourceRange, of: sourceVideo, at: cursor)
                if let sourceAudio {
                    try audioTrack.insertTimeRange(sourceRange, of: sourceAudio, at: cursor)
                } else {
                    audioTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: sourceRange.duration))
                }
            } catch {
                throw CompositionError.unreadableMedia(clip.mediaId)
            }

            let target = clip.timelineDuration.cmTime
            if clip.playbackRate != 1 {
                let inserted = CMTimeRange(start: cursor, duration: sourceRange.duration)
                videoTrack.scaleTimeRange(inserted, toDuration: target)
                audioTrack.scaleTimeRange(inserted, toDuration: target)
            }
            let placed = CMTimeRange(start: cursor, duration: target)

            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            layer.setTransform(
                FillTransform.make(natural: natural, preferred: preferred, canvas: renderSize, clip: clip.transform),
                at: placed.start
            )
            instructions.append(Self.instruction(for: placed, layers: [layer]))
            audioParameters.setVolume(Float(clip.volume), at: placed.start)

            cursor = placed.end
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, document.canvas.fps)))
        videoComposition.instructions = instructions

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [audioParameters]

        return BuiltComposition(composition: composition, videoComposition: videoComposition, audioMix: audioMix, revision: document.revision)
    }

    private static func instruction(for range: CMTimeRange, layers: [AVVideoCompositionLayerInstruction]) -> AVMutableVideoCompositionInstruction {
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = range
        instruction.layerInstructions = layers
        instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
        return instruction
    }
}

/// Kaynak görüntüyü kanvasa yerleştiren dönüşüm. Ayrı tutuldu çünkü önizleme
/// ve dışa aktarmanın aynı hesabı kullanması gerekir ve tek başına test edilebilir.
public enum FillTransform {
    public static func make(natural: CGSize, preferred: CGAffineTransform, canvas: CGSize, clip: Transform) -> CGAffineTransform {
        // 1) Telefonun yön bilgisini uygula ve sonucu (0,0)'a taşı.
        let oriented = CGRect(origin: .zero, size: natural).applying(preferred)
        var t = preferred.concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
        let size = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        guard size.width > 0, size.height > 0 else { return t }

        // 2) Kanvası dolduracak ölçek (aspect fill) × klibin kendi ölçeği.
        let scale = max(canvas.width / size.width, canvas.height / size.height) * CGFloat(clip.scale)
        t = t.concatenating(CGAffineTransform(scaleX: scale, y: scale))

        // 3) Ortala; klibin kaydırması kanvas boyutuna göreli.
        let dx = (canvas.width - size.width * scale) / 2 + CGFloat(clip.offsetX) * canvas.width
        let dy = (canvas.height - size.height * scale) / 2 + CGFloat(clip.offsetY) * canvas.height
        return t.concatenating(CGAffineTransform(translationX: dx, y: dy))
    }
}
