import AppKit
import PugglePhotosKit
import SwiftUI

/// The handwriting notes and books are written in: a font on the Mac, chosen in Settings, and for each book.
enum Handwriting {
    /// The styles offered, each a font every Mac has, named for how it looks.
    static let styles: [(name: String, family: String)] = [
        ("Pen", "Bradley Hand"),
        ("Casual", "Noteworthy"),
        ("Marker", "Marker Felt"),
        ("Brush", "SignPainter"),
        ("Cursive", "Snell Roundhand"),
        ("Elegant", "Savoye LET"),
        ("Chalk", "Chalkduster"),
        ("Print", "Chalkboard SE"),
        ("Typewriter", "American Typewriter"),
    ]

    static let key = "HandwritingFont"
    static let defaultFamily = "Bradley Hand"

    /// The family chosen in Settings, if it's still on this Mac.
    static var family: String {
        let chosen = UserDefaults.standard.string(forKey: key) ?? defaultFamily
        return isInstalled(chosen) ? chosen : defaultFamily
    }

    static func isInstalled(_ family: String) -> Bool { NSFontManager.shared.availableMembers(ofFontFamily: family)?.isEmpty == false }

    /// What a family is called here: its style's name, or its own.
    static func name(of family: String) -> String {
        styles.first { $0.family == family }?.name ?? family
    }

    /// A font in a family (nil for the one chosen in Settings), its regular face or its boldest. Sizes are evened
    /// out between families, so "Elegant" isn't tiny beside "Marker".
    static func font(_ family: String? = nil, size: CGFloat, bold: Bool = false) -> NSFont {
        let family = family.flatMap { isInstalled($0) ? $0 : nil } ?? Self.family
        let key = "\(family)|\(bold)"
        let base: NSFont
        if let cached = faces[key] {
            base = cached
        } else {
            let members = (NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []).filter {
                ((($0[3] as? NSNumber)?.uintValue ?? 0) & NSFontTraitMask.italicFontMask.rawValue) == 0
            }
            let weight = { (member: [Any]) -> Int in (member[2] as? NSNumber)?.intValue ?? 5 }
            let chosen = bold ? members.max { weight($0) < weight($1) } : members.min { abs(weight($0) - 5) < abs(weight($1) - 5) }
            base = (chosen?[0] as? String).flatMap { NSFont(name: $0, size: 100) } ?? NSFont.systemFont(ofSize: 100)
            faces[key] = base
        }
        // Letters about half as tall as the size asked for.
        let evened = base.xHeight > 0 ? min(max(0.46 / (base.xHeight / 100), 0.8), 1.7) : 1
        return NSFont(descriptor: base.fontDescriptor, size: size * evened) ?? base
    }

    private static var faces: [String: NSFont] = [:]

    /// Every font family on this Mac, for choosing another.
    static var allFamilies: [String] { NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }.sorted() }
}

/// The handwriting choices in Settings and for a book: each style written in itself, and any other font on the Mac.
struct HandwritingPicker: View {
    @Binding var family: String
    /// Shown first, for a book: "As in Settings".
    var followsSettings: Binding<Bool>?
    @State private var choosingOther = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
                ForEach(Handwriting.styles, id: \.family) { style in
                    let chosen = followsSettings?.wrappedValue != true && family == style.family
                    Button {
                        followsSettings?.wrappedValue = false
                        family = style.family
                    } label: {
                        Text(style.name)
                            .font(Font(Handwriting.font(style.family, size: 21) as CTFont))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(chosen ? Color.pugglePink.opacity(0.16) : Color(nsColor: .controlBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(chosen ? Color.pugglePink : Color(nsColor: .separatorColor), lineWidth: chosen ? 2 : 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(style.name) handwriting")
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
            HStack {
                if !Handwriting.styles.contains(where: { $0.family == family }), followsSettings?.wrappedValue != true {
                    Text(family).font(Font(Handwriting.font(family, size: 17) as CTFont))
                }
                Spacer()
                Button("Other Font…") { choosingOther = true }
                    .popover(isPresented: $choosingOther) {
                        OtherFontList(family: $family) {
                            followsSettings?.wrappedValue = false
                            choosingOther = false
                        }
                    }
            }
        }
    }
}

/// Every font on the Mac, each in itself, to search and pick from.
private struct OtherFontList: View {
    @Binding var family: String
    let onChoose: () -> Void
    @State private var search = ""

    var body: some View {
        let families = Handwriting.allFamilies.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
        VStack(spacing: 8) {
            TextField("Search", text: $search).textFieldStyle(.roundedBorder)
            List(families, id: \.self) { name in
                Button {
                    family = name
                    onChoose()
                } label: {
                    Text(name).font(Font(Handwriting.font(name, size: 16) as CTFont)).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            .frame(height: 300)
        }
        .padding(12)
        .frame(width: 300)
    }
}
