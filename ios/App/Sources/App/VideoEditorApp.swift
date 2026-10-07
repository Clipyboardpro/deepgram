import SwiftUI
import ProjectLibrary

@main
struct VideoEditorApp: App {
    @State private var library: ProjectLibraryModel

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        _library = State(initialValue: ProjectLibraryModel(repository: FileProjectRepository(root: documents)))
    }

    var body: some Scene {
        WindowGroup {
            ProjectLibraryView()
                .environment(library)
        }
    }
}
