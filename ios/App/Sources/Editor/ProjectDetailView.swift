import SwiftUI
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers
import EditorDomain

/// Düzenleyici ekranı: önizleme, oynatma, zaman çizelgesi (seç, böl, sil),
/// video ekleme, geri al/yinele.
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
    @Environment(AccountModel.self) private var account
    @State private var pickerItem: PhotosPickerItem?

    var body: some View {
        let document = editor.document
        VStack(spacing: 12) {
            if document.tracks.allSatisfy({ $0.clips.isEmpty }) {
                ContentUnavailableView {
                    Label("Henüz video yok", systemImage: "film")
                } description: {
                    Text("Sağ üstteki + ile Fotoğraflar'dan video ekle.")
                }
            } else {
                PreviewView(editor: editor)
                    .padding(.horizontal)
                TransportBar(editor: editor)
                TimelineStrip(editor: editor)
                CaptionButton(editor: editor)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
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
                Button { editor.startExport() } label: {
                    Label("Dışa aktar", systemImage: "square.and.arrow.up")
                }
                .disabled(document.duration == .zero || editor.exportState != .idle)
            }
        }
        .overlay {
            if case let .exporting(progress) = editor.exportState {
                VStack(spacing: 12) {
                    ProgressView(value: progress) { Text("Video hazırlanıyor…") }
                        .frame(width: 220)
                    Button("Vazgeç", role: .cancel) { editor.cancelExport() }
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .overlay {
            if case let .working(text) = editor.captionState {
                VStack(spacing: 12) {
                    ProgressView(text)
                    Button("Vazgeç", role: .cancel) { editor.cancelCaptioning() }
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .sheet(isPresented: $editor.needsSignIn) {
            SignInView()
        }
        .sheet(isPresented: Binding(
            get: { if case .finished = editor.exportState { true } else { false } },
            set: { if !$0 { editor.dismissExport() } }
        )) {
            if case let .finished(url) = editor.exportState {
                ExportDoneView(url: url) { editor.dismissExport() }
                    .presentationDetents([.medium])
            }
        }
        .task { await editor.refreshPreview() }
        .onChange(of: editor.captionState) { _, state in
            if state == .idle { Task { await account.refreshQuota() } }
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

/// Altyazısı olmayan videolar için sunucuda otomatik altyazı başlatır.
/// Oturum yoksa önce giriş ekranı açılır.
private struct CaptionButton: View {
    let editor: ProjectEditorModel
    @Environment(AccountModel.self) private var account

    var body: some View {
        let hasTargets = !editor.captionTargets.isEmpty
        Button {
            guard let api = account.api else { return }
            if account.isSignedIn {
                editor.startCaptioning(api: api)
            } else {
                editor.needsSignIn = true
            }
        } label: {
            Label(hasTargets ? "Otomatik altyazı" : "Altyazılar hazır", systemImage: "captions.bubble")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!hasTargets || account.state == .unavailable || editor.captionState != .idle)
        .padding(.horizontal)
    }
}

/// Dışa aktarma bitti: paylaş / Fotoğraflar'a kaydet (paylaşım ekranından).
private struct ExportDoneView: View {
    let url: URL
    let done: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Video hazır")
                .font(.title2.bold())
            Text("Paylaşım ekranından \"Videoyu Kaydet\" ile Fotoğraflar'a ekleyebilirsin.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            ShareLink(item: url) {
                Label("Paylaş veya kaydet", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button("Kapat", action: done)
        }
        .padding(24)
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
