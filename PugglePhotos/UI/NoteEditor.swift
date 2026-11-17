import AppKit
import PugglePhotosKit
import SwiftUI

/// What's written in a note editor, kept outside the view so it can be saved however the editor closes.
@Observable final class NoteDraft {
    var text: String
    /// Set by Cancel, so closing saves nothing.
    var isCancelled = false

    init(_ text: String) { self.text = text }
}

/// Writing on the back of a photo: its note, in handwriting on the photo paper.
struct NoteEditorView: View {
    @Bindable var draft: NoteDraft
    /// The day the photo was taken.
    let title: String
    /// The handwriting; nil for the one chosen in Settings.
    let family: String?
    let onCancel: () -> Void
    let onSave: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("The Back of the Photo").font(.system(size: 15, weight: .bold, design: .rounded))
                if !title.isEmpty { Text(title).font(.callout).foregroundStyle(.secondary) }
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft.text)
                    .font(Font(Handwriting.font(family, size: 20) as CTFont))
                    .foregroundStyle(Color(nsColor: PhotoBack.ink))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .accessibilityLabel("Note")
                if draft.text.isEmpty {
                    Text("Who’s in it? Where was it? What happened just before?")
                        .font(Font(Handwriting.font(family, size: 18) as CTFont))
                        .foregroundStyle(Color(nsColor: PhotoBack.pencilInk).opacity(0.5))
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .padding(10)
            .frame(minHeight: 170)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: PhotoBack.paper)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.black.opacity(0.12)))
            .environment(\.colorScheme, .light)
            HStack {
                Text("Shows when the photo is turned over, and in photo books.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) {
                    draft.isCancelled = true
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button("Done", action: onSave)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Done (⌘↩)")
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear { focused = true }
    }
}
