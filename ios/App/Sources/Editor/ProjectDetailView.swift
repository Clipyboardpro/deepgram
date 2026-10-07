import SwiftUI
import EditorDomain

/// Düzenleyici ekranının yer tutucusu. Zaman çizelgesi ve önizleme aşama 1'de
/// (MediaEngine + EditorUI) gelecek; şimdilik projenin açıldığını gösterir.
struct ProjectDetailView: View {
    @Environment(ProjectLibraryModel.self) private var library
    let projectId: UUID
    @State private var document: ProjectDocument?

    var body: some View {
        Group {
            if let document {
                List {
                    LabeledContent("Süre", value: DurationText.format(document.duration))
                    LabeledContent("Medya", value: "\(document.mediaAssets.count)")
                    LabeledContent("Klip", value: "\(document.tracks.reduce(0) { $0 + $1.clips.count })")
                    LabeledContent("Kanvas", value: "\(document.canvas.width)×\(document.canvas.height), \(document.canvas.fps) fps")
                    Section {
                        Text("Zaman çizelgesi ve önizleme bir sonraki aşamada eklenecek.")
                            .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle(document.title ?? "Adsız proje")
            } else {
                ProgressView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { document = library.load(projectId) }
    }
}
