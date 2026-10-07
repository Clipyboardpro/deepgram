import AVFoundation
import CryptoKit
import EditorDomain

/// Sunucuya gönderilmeye hazır ses dosyası.
public struct ExtractedAudio: Equatable, Sendable {
    public var url: URL
    /// Saniye (ölçülen, çıktı dosyasından).
    public var durationSeconds: Double
    public var byteCount: Int
    public var sha256Hex: String
}

/// Videodan yalnız gereken sesi çıkarır: mono, 16 kHz, düşük bit hızlı AAC
/// (M4A). 5 dakikalık ses yaklaşık 1–2 MB tutar; yükleme ve depolama ucuz kalır.
public enum AudioExtractor {
    public static let sampleRate: Double = 16_000
    public static let bitRate = 32_000

    /// - Parameters:
    ///   - range: Kaynağın yalnız bu kısmı (kaynak zamanı). nil ise tamamı.
    ///   - destination: Çıktı yolu (.m4a). Varsa üzerine yazılır; yarım dosya bırakılmaz.
    public static func extract(from source: URL, range: TimeRange? = nil, to destination: URL) async throws -> ExtractedAudio {
        if let range, range.isEmpty { throw MediaEngineError.emptyRange }

        let asset = AVURLAsset(url: source)
        let track: AVAssetTrack
        do {
            guard let first = try await asset.loadTracks(withMediaType: .audio).first else {
                throw MediaEngineError.noAudioTrack
            }
            track = first
        } catch let error as MediaEngineError {
            throw error
        } catch {
            throw MediaEngineError.unreadable
        }

        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: temporary) }

        try await transcode(asset: asset, track: track, range: range, to: temporary)

        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: temporary, to: destination)

        let data = try Data(contentsOf: destination)
        let duration = try await AVURLAsset(url: destination).load(.duration).seconds
        return ExtractedAudio(
            url: destination,
            durationSeconds: duration,
            byteCount: data.count,
            sha256Hex: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
    }

    private static func transcode(asset: AVAsset, track: AVAssetTrack, range: TimeRange?, to url: URL) async throws {
        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        } catch {
            throw MediaEngineError.exportFailed("hazırlık: \(error.localizedDescription)")
        }
        if let range { reader.timeRange = range.cmTimeRange }

        // Okurken doğrudan 16 kHz monoya indir; kodlayıcı yalnız sıkıştırır.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
        ])
        input.expectsMediaDataInRealTime = false

        guard reader.canAdd(output), writer.canAdd(input) else {
            throw MediaEngineError.exportFailed("biçim desteklenmiyor")
        }
        reader.add(output)
        writer.add(input)

        guard reader.startReading() else {
            throw MediaEngineError.exportFailed("okuma: \(reader.error?.localizedDescription ?? "bilinmiyor")")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw MediaEngineError.exportFailed("yazma: \(writer.error?.localizedDescription ?? "bilinmiyor")")
        }
        writer.startSession(atSourceTime: range?.start.cmTime ?? .zero)

        do {
            while true {
                try Task.checkCancellation()
                guard input.isReadyForMoreMediaData else {
                    try await Task.sleep(nanoseconds: 2_000_000)
                    continue
                }
                guard let buffer = output.copyNextSampleBuffer() else { break }
                guard input.append(buffer) else {
                    throw MediaEngineError.exportFailed("kodlama: \(writer.error?.localizedDescription ?? "bilinmiyor")")
                }
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }

        guard reader.status == .completed else {
            writer.cancelWriting()
            throw MediaEngineError.exportFailed("okuma: \(reader.error?.localizedDescription ?? "yarım kaldı")")
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw MediaEngineError.exportFailed("yazma: \(writer.error?.localizedDescription ?? "tamamlanamadı")")
        }
    }
}
