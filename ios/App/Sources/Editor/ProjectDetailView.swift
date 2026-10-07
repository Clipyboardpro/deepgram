import SwiftUI
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers
import EditorDomain

/// Düzenleyici ekranı (ilk sürüm): video ekleme, klip listesi, geri al/yinele.
/// Zaman çizelgesi ve önizleme sonraki adımda (MediaEngine önizleme + EditorUI).
struct ProjectDetailView: View {
    @Environment(ProjectLibraryModel.self) private var library
    let projectId: UUID
    @State private var editor: ProjectEditorModel?

    var body: some View {
        Group {
            if let editor {
                EditorContent(editor: editor)
            } else {
                ProgressView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if editor == nil { editor = library.makeEditor(projectId) }
        }
        .onDisappear { library.reload() }
    }
}

private struct EditorContent: View {
    @Bindable var editor: ProjectEditorModel
    @State private var pickerItem: PhotosPickerItem?

    var body: some View {
        let document = editor.document
        List {
            Section {
                LabeledContent("Süre", value: DurationText.format(document.duration))
                LabeledContent("Kanvas", value: "\(document.canvas.width)×\(document.canvas.height), \(document.canvas.fps) fps")
            }
            Section("Klipler") {
                let clips = document.tracks.filter { $0.kind == .video }.flatMap(\.clips)
                if clips.isEmpty {
                    Text("Henüz video yok. Sağ üstten video ekle.")
                        .foregroundStyle(.secondary)
                }
                ForEach(clips, id: \.clipId) { clip in
                    HStack {
                        Image(systemName: "film")
                        VStack(alignment: .leading) {
                            Text("\(DurationText.format(clip.timelineRange.start)) – \(DurationText.format(clip.timelineRange.end))")
                            if clip.playbackRate != 1 {
                                Text("\(clip.playbackRate, format: .number)x").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if editor.isImporting {
                ProgressView("Video ekleniyor…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .navigationTitle(document.title ?? "Adsız proje")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { editor.undo() } label: { Label("Geri al", systemImage: "arrow.uturn.backward") }
                    .disabled(!editor.canUndo)
                Button { editor.redo() } label: { Label("Yinele", systemImage: "arrow.uturn.forward") }
                    .disabled(!editor.canRedo)
                PhotosPicker(selection: $pickerItem, matching: .videos, photoLibrary: .shared()) {
                    Label("Video ekle", systemImage: "plus")
                }
                .disabled(editor.isImporting)
            }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            pickerItem = nil
            Task {
                do {
                    guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { return }
                    await editor.importVideo(from: movie.url)
                } catch {
                    editor.errorMessage = "Video okunamadı."
                }
            }
        }
        .alert("Bir sorun oluştu", isPresented: Binding(
            get: { editor.errorMessage != nil },
            set: { if !$0 { editor.errorMessage = nil } }
        )) {
            Button("Tamam", role: .cancel) {}
        } message: {
            Text(editor.errorMessage ?? "")
        }
    }
}

/// Fotoğraflar'dan seçilen videonun geçici kopyası. Sistem dosyayı yalnız
/// içe aktarma süresince verir; kalıcı kopya proje klasörüne alınır.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("picked-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}
