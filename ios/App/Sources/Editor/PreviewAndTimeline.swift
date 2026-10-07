import SwiftUI
import AVKit
import EditorDomain

/// 9:16 önizleme + o anki altyazı satırı. Satırın punto, genişlik ve konumu
/// `CaptionStyle`'dan kanvasa oranla hesaplanır; dışa aktarmadaki katmanla
/// aynı geometri (kutu alttan `bottomMargin`, yüksekliği 2,6 × punto, metin üstte).
struct PreviewView: View {
    let editor: ProjectEditorModel
    private let style = CaptionStyle.standard

    var body: some View {
        let canvas = editor.document.canvas
        GeometryReader { proxy in
            let scale = proxy.size.height / CGFloat(canvas.height)
            let fontSize = CGFloat(style.fontSize(forCanvasHeight: Double(canvas.height))) * scale
            ZStack(alignment: .bottom) {
                VideoPlayer(player: editor.playback.player)
                    .disabled(true)   // kendi kontrollerimiz var
                if let caption = editor.currentCaption {
                    Text(caption)
                        .font(.system(size: fontSize, weight: .bold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.85), radius: fontSize * 0.08)
                        .frame(width: CGFloat(style.maxWidth(forCanvasWidth: Double(canvas.width))) * scale,
                               height: fontSize * 2.6, alignment: .top)
                        .padding(.bottom, CGFloat(style.bottomMargin(forCanvasHeight: Double(canvas.height))) * scale)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(CGFloat(canvas.width) / CGFloat(canvas.height), contentMode: .fit)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { editor.playback.togglePlay() }
    }
}

/// Oynatma ve düzenleme düğmeleri.
struct TransportBar: View {
    let editor: ProjectEditorModel

    var body: some View {
        HStack(spacing: 20) {
            Button { editor.playback.togglePlay() } label: {
                Image(systemName: editor.playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
            }
            .accessibilityLabel(editor.playback.isPlaying ? "Duraklat" : "Oynat")

            Text("\(DurationText.format(editor.playback.currentTime)) / \(DurationText.format(editor.document.duration))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            Button { editor.splitAtPlayhead() } label: {
                Label("Böl", systemImage: "scissors")
            }
            .disabled(editor.clipUnderPlayhead() == nil)

            Menu {
                ForEach(ProjectEditorModel.speedOptions, id: \.self) { rate in
                    Button {
                        editor.setSpeed(rate)
                    } label: {
                        if editor.selectedClip?.playbackRate == rate {
                            Label(SpeedText.format(rate), systemImage: "checkmark")
                        } else {
                            Text(SpeedText.format(rate))
                        }
                    }
                }
            } label: {
                Label("Hız", systemImage: "gauge.with.dots.needle.67percent")
            }
            .disabled(editor.selectedClip == nil)

            Button(role: .destructive) { editor.deleteSelectedClip() } label: {
                Label("Sil", systemImage: "trash")
            }
            .disabled(editor.selectedClipId == nil)
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal)
    }
}

/// Klipler sürelerine orantılı bloklar; dokununca seçilir, sürükleyince imleç
/// gezer. Seçili klibin kenarlarındaki tutamaçlar sürüklenerek kırpılır.
struct TimelineStrip: View {
    let editor: ProjectEditorModel
    private let pointsPerSecond: CGFloat = 40
    /// Sürüklenen kenar ve zaman çizelgesindeki miktarı (sn).
    @State private var trim: (edge: ClipEdge, seconds: Double)?

    var body: some View {
        let document = editor.document
        let clips = document.tracks.first { $0.kind == .video }?.clips ?? []
        let total = max(CGFloat(document.duration.seconds) * pointsPerSecond, 1)

        ScrollView(.horizontal, showsIndicators: false) {
            ZStack(alignment: .leading) {
                ForEach(clips, id: \.clipId) { clip in
                    clipBlock(clip, selected: clip.clipId == editor.selectedClipId)
                }
                Rectangle()
                    .fill(.white)
                    .frame(width: 2, height: 72)
                    .offset(x: CGFloat(editor.playback.currentTime.seconds) * pointsPerSecond)
                    .allowsHitTesting(false)
            }
            .frame(width: total, height: 72, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let seconds = max(0, min(Double(value.location.x / pointsPerSecond), document.duration.seconds))
                editor.playback.seek(to: MediaTime(seconds: seconds))
            })
            .padding(.horizontal, 24)
        }
        .frame(height: 80)
        .background(Color(.secondarySystemBackground))
    }

    @ViewBuilder
    private func clipBlock(_ clip: Clip, selected: Bool) -> some View {
        // Sürüklenirken seçili klip yeni uzunluğuyla gösterilir (bırakınca uygulanır).
        let duration: Double = {
            guard selected, let trim else { return clip.timelineDuration.seconds }
            let range = editor.trimPreview(clip, edge: trim.edge, timelineSeconds: trim.seconds)
            return (range.sourceOut - range.sourceIn).seconds / clip.playbackRate
        }()
        let width = max(CGFloat(duration) * pointsPerSecond - 2, 4)

        RoundedRectangle(cornerRadius: 6)
            .fill(selected ? Color.accentColor : Color.accentColor.opacity(0.45))
            .overlay(alignment: .leading) {
                if clip.playbackRate != 1 {
                    Text(SpeedText.format(clip.playbackRate))
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.leading, 18)
                }
            }
            .overlay {
                if selected {
                    HStack {
                        handle(clip, edge: .start)
                        Spacer(minLength: 0)
                        handle(clip, edge: .end)
                    }
                }
            }
            .frame(width: width, height: 56)
            .offset(x: CGFloat(clip.timelineStart.seconds) * pointsPerSecond)
            .onTapGesture {
                editor.selectedClipId = selected ? nil : clip.clipId
            }
    }

    private func handle(_ clip: Clip, edge: ClipEdge) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(.white)
            .frame(width: 14, height: 56)
            .overlay(Capsule().fill(Color.accentColor).frame(width: 3, height: 20))
            .contentShape(Rectangle().inset(by: -8))
            .highPriorityGesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        trim = (edge, Double(value.translation.width / pointsPerSecond))
                    }
                    .onEnded { value in
                        trim = nil
                        editor.commitTrim(clip, edge: edge, timelineSeconds: Double(value.translation.width / pointsPerSecond))
                    }
            )
            .accessibilityLabel(edge == .start ? "Başlangıcı kırp" : "Sonu kırp")
    }
}

enum SpeedText {
    /// 0.5 → "0.5x", 2 → "2x"
    static func format(_ rate: Double) -> String {
        rate == rate.rounded() ? "\(Int(rate))x" : "\(rate.formatted(.number.precision(.fractionLength(0...2))))x"
    }
}
