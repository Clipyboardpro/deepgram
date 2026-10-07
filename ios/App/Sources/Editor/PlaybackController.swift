import AVFoundation
import Observation
import EditorDomain
import MediaEngine

/// Önizleme oynatıcısı. Proje her değiştiğinde yeni kompozisyon yüklenir ve
/// oynatma kaldığı yerden sürer.
@MainActor
@Observable
final class PlaybackController {
    let player = AVPlayer()
    private(set) var currentTime: MediaTime = .zero
    private(set) var isPlaying = false
    private(set) var duration: MediaTime = .zero

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var loadedRevision: Int?

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = MediaTime(time)
                self.isPlaying = self.player.timeControlStatus == .playing
            }
        }
    }

    /// Yeni kompozisyonu yükler; aynı revizyon tekrar yüklenmez.
    func load(_ built: BuiltComposition) {
        guard built.revision != loadedRevision else { return }
        loadedRevision = built.revision
        let resume = min(currentTime, MediaTime(built.duration))
        player.replaceCurrentItem(with: built.makePlayerItem())
        duration = MediaTime(built.duration)
        seek(to: resume)
    }

    func togglePlay() {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            if currentTime >= duration { seek(to: .zero) }
            player.play()
        }
    }

    func seek(to time: MediaTime) {
        currentTime = time
        player.seek(to: time.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }
}
