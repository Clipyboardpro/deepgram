import SwiftUI
import EditorDomain
import ProjectLibrary

struct ProjectLibraryView: View {
    @Environment(ProjectLibraryModel.self) private var library
    @State private var path: [UUID] = []
    @State private var isNaming = false
    @State private var newTitle = ""

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Projeler")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            newTitle = ""
                            isNaming = true
                        } label: {
                            Label("Yeni proje", systemImage: "plus")
                        }
                    }
                }
                .navigationDestination(for: UUID.self) { id in
                    ProjectDetailView(projectId: id)
                }
                .alert("Yeni proje", isPresented: $isNaming) {
                    TextField("Proje adı", text: $newTitle)
                    Button("Oluştur") {
                        if let id = library.create(title: newTitle) { path.append(id) }
                    }
                    Button("Vazgeç", role: .cancel) {}
                }
                .alert("Bir sorun oluştu", isPresented: errorBinding) {
                    Button("Tamam", role: .cancel) {}
                } message: {
                    Text(library.errorMessage ?? "")
                }
        }
        .task { library.reload() }
    }

    @ViewBuilder
    private var content: some View {
        if library.projects.isEmpty {
            ContentUnavailableView {
                Label("Henüz proje yok", systemImage: "film.stack")
            } description: {
                Text("Bir video seçip kesmeye ve altyazı eklemeye başla.")
            } actions: {
                Button("Yeni proje") {
                    newTitle = ""
                    isNaming = true
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            List {
                if library.unreadableCount > 0 {
                    Label("\(library.unreadableCount) proje açılamadı ve listede gösterilmiyor.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
                ForEach(library.projects) { project in
                    NavigationLink(value: project.id) {
                        ProjectRow(project: project)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            library.delete(project.id)
                        } label: {
                            Label("Sil", systemImage: "trash")
                        }
                        Button {
                            library.duplicate(project.id)
                        } label: {
                            Label("Çoğalt", systemImage: "plus.square.on.square")
                        }
                    }
                }
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { library.errorMessage != nil },
            set: { if !$0 { library.errorMessage = nil } }
        )
    }
}

private struct ProjectRow: View {
    let project: ProjectSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(project.title)
                .font(.headline)
            HStack(spacing: 8) {
                Text(DurationText.format(project.duration))
                Text("·")
                Text(project.updatedAt, format: .relative(presentation: .named))
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

enum DurationText {
    /// 75 sn → "1:15"; boş proje → "0:00".
    static func format(_ time: MediaTime) -> String {
        let total = max(0, Int(time.seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
