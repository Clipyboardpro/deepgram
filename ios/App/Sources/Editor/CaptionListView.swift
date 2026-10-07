import SwiftUI
import EditorDomain

/// Altyazı satırları: dokununca o ana gidilir ve satır düzenlenir. AI'nın emin
/// olmadığı kelimeler turuncu gösterilir; düzeltilmiş satır orijinaline döndürülebilir.
struct CaptionListView: View {
    let editor: ProjectEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing: EditableCaptionLine?

    var body: some View {
        NavigationStack {
            let lines = editor.captionLines
            Group {
                if lines.isEmpty {
                    ContentUnavailableView {
                        Label("Altyazı yok", systemImage: "captions.bubble")
                    } description: {
                        Text("Önce \"Otomatik altyazı\" ile altyazı oluştur.")
                    }
                } else {
                    List(lines) { line in
                        CaptionRow(line: line, isCurrent: line.range.contains(editor.playback.currentTime))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                editor.playback.seek(to: line.range.start)
                                editing = line
                            }
                            .swipeActions {
                                if line.isCorrected {
                                    Button("Orijinal") { editor.revertCaption(line) }
                                        .tint(.gray)
                                }
                            }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Altyazılar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Bitti") { dismiss() } }
            }
            .sheet(item: $editing) { line in
                CaptionLineEditorView(line: line) { text in
                    editor.editCaption(line, newText: text)
                }
                .presentationDetents([.height(260)])
            }
        }
    }
}

private struct CaptionRow: View {
    let line: EditableCaptionLine
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(DurationText.format(line.range.start))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            styledText
                .frame(maxWidth: .infinity, alignment: .leading)
            if line.isCorrected {
                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Düzeltildi")
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(isCurrent ? Color.accentColor.opacity(0.12) : nil)
    }

    /// Kelime kelime: emin olunmayanlar turuncu; satırın tümü gizliyse soluk not.
    private var styledText: Text {
        let uncertain = line.uncertainWordIds()
        let visible = line.words.filter { !$0.text.isEmpty }
        guard !visible.isEmpty else { return Text("(gizli satır)").italic().foregroundColor(.secondary) }
        return visible.enumerated().reduce(Text("")) { result, item in
            let (index, word) = item
            let piece = Text((index == 0 ? "" : " ") + word.text)
            return result + (uncertain.contains(word.wordId) ? piece.foregroundColor(.orange) : piece)
        }
    }
}

/// Tek satırın metnini düzenler. Boş bırakılan satır gizlenir.
private struct CaptionLineEditorView: View {
    let line: EditableCaptionLine
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var focused: Bool

    init(line: EditableCaptionLine, save: @escaping (String) -> Void) {
        self.line = line
        self.save = save
        _text = State(initialValue: line.text)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Altyazı", text: $text, axis: .vertical)
                        .lineLimit(2...4)
                        .focused($focused)
                } footer: {
                    Text("\(DurationText.format(line.range.start)) – \(DurationText.format(line.range.end)) · Boş bırakırsan satır gizlenir.")
                }
            }
            .navigationTitle("Satırı düzenle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kaydet") {
                        save(text)
                        dismiss()
                    }
                }
            }
            .onAppear { focused = true }
        }
    }
}
