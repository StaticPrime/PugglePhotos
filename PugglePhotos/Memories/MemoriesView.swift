import AppKit
import PugglePhotosKit
import SwiftUI

/// What the Memories page asks the window to do.
protocol MemoriesActions: AnyObject {
    func play(_ memory: Memory)
    func showPhotos(of memory: Memory)
}

/// The Memories page: this day in past years at the top, then big days and trips, years and labels, each a card
/// with its best photo. Click a card to play it as a slideshow.
struct MemoriesView: View {
    let memories: MemoriesController
    let actions: () -> MemoriesActions?

    private var formatting: Formatting { memories.library.formatting }

    var body: some View {
        let page = memories.page
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("On This Day").font(.system(size: 26, weight: .bold, design: .rounded))
                    Text(formatting.weekdayAndDay(memories.today))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                if page.onThisDay.isEmpty, memories.isFinding {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .accessibilityLabel("Looking for memories")
                } else if page.onThisDay.isEmpty {
                    NothingTodayCard(nextDay: memories.nextDay, today: memories.today, formatting: formatting)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 640), spacing: 18)], spacing: 18) {
                        ForEach(page.onThisDay) { memory in
                            MemoryCard(memory: memory, library: memories.library, height: 280, actions: actions)
                        }
                    }
                }
                section("Highlights", page.highlights)
                section("Collections", page.collections)
                section("Years", page.years)
                section("Labels", page.labels)
            }
            .padding(EdgeInsets(top: 22, leading: 26, bottom: 30, trailing: 26))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: Theme.gridBackground))
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [Memory]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.system(size: 20, weight: .bold, design: .rounded))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 420), spacing: 16)], spacing: 16) {
                    ForEach(items) { memory in
                        MemoryCard(memory: memory, library: memories.library, height: 200, actions: actions)
                    }
                }
            }
        }
    }
}

/// A memory's card: its best photo, its name and dates, and a play button.
struct MemoryCard: View {
    let memory: Memory
    let library: LibraryController
    let height: CGFloat
    let actions: () -> MemoriesActions?
    @State private var image: CGImage?
    @State private var hovering = false
    @State private var request: ImageRequest?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Whether the card keeps still under the pointer, for Reduce Motion.
    private var still: Bool { reduceMotion || Motion.isReduced }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color(nsColor: Theme.placeholder)
                }
            }
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .scaleEffect(hovering && !still ? 1.06 : 1)
            .animation(.easeOut(duration: 2.5), value: hovering)
            .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(memory.title)
                        .font(.system(size: height > 240 ? 26 : 20, weight: .heavy, design: .rounded))
                        .lineLimit(2)
                    Text(memory.subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .opacity(0.9)
                        .lineLimit(1)
                    if !memory.note.isEmpty {
                        Text("“\(SlideshowPlan.quote(memory.note, limit: height > 240 ? 150 : 80))”")
                            .font(.system(size: height > 240 ? 15 : 13, design: .serif).italic())
                            .lineLimit(2)
                            .padding(.top, 4)
                    }
                }
                Spacer(minLength: 12)
                Image(systemName: "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.pugglePink))
                    .scaleEffect(hovering && !still ? 1.12 : 1)
                    .animation(.spring(duration: 0.3), value: hovering)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.4), radius: 4)
            .padding(16)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(hovering ? 0.28 : 0.14), radius: hovering ? 12 : 6, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onHover { hovering = $0 }
        .onTapGesture { actions()?.play(memory) }
        .contextMenu {
            Button("Play Slideshow") { actions()?.play(memory) }
            Button("Show Photos") { actions()?.showPhotos(of: memory) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(memory.note.isEmpty ? "\(memory.title), \(memory.subtitle)"
                            : "\(memory.title), \(memory.subtitle). You wrote: \(memory.note)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Show Photos") { actions()?.showPhotos(of: memory) }
        .onAppear(perform: load)
        .onDisappear {
            request?.cancel()
            request = nil
        }
    }

    private func load() {
        guard image == nil, let photo = memory.keyPhoto else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        request = library.source.requestImage(photo, pixels: CGSize(width: 640 * scale, height: height * scale), fit: false) { image, _ in
            if let image { self.image = image }
        }
    }
}

/// What the top of the page says on a day with no photos from earlier years.
struct NothingTodayCard: View {
    let nextDay: CivilDay?
    let today: CivilDay
    let formatting: Formatting

    var body: some View {
        HStack(spacing: 18) {
            Image("AboutLogo")
                .resizable()
                .interpolation(.high)
                .frame(width: 86, height: 86)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("No photos from this day in earlier years")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                Text(nextText).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.pugglePink.opacity(0.08)))
    }

    private var nextText: String {
        guard let nextDay else { return "Take some photos today: next year, they’ll be waiting here." }
        let days = nextDay.number - today.number
        let when = days == 1 ? "tomorrow" : "in \(days) days, on \(formatting.dayTitle(nextDay, today: today))"
        return "Your next memory comes \(when). Meanwhile, here are some favorites."
    }
}
