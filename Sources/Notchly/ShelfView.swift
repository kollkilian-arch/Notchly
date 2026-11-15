import SwiftUI
import UniformTypeIdentifiers
import QuickLookThumbnailing

struct ShelfView: View {
    @ObservedObject var shelf: ShelfStore
    var isActive = true
    var pasteboard: NSPasteboard = .general
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text(shelf.items.isEmpty ? "Your shelf" : "\(shelf.items.count) items")
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Text("Space to preview · double-click to open")
                    .foregroundStyle(.white.opacity(0.4))
                Button { shelf.paste(from: pasteboard) } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.plain)
                .help("Paste files, links, text, or screenshots (⌘V)")
                .accessibilityLabel("Paste into Shelf")
            }
            .font(.system(size: 10, weight: .medium))
            .frame(height: 18)

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(targeted ? Color.accentColor.opacity(0.16) : Color.white.opacity(0.04))
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(targeted ? Color.accentColor : Color.white.opacity(0.18),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))

                if shelf.items.isEmpty {
                    VStack(spacing: 4) {
                        Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 20))
                        Text("Drop files, links, or text here").font(.system(size: 12, weight: .semibold))
                        Text("Or paste a screenshot with ⌘V")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                    }
                    .foregroundStyle(.white.opacity(targeted ? 0.95 : 0.6))
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(shelf.items) { item in
                                    ShelfTile(item: item, shelf: shelf).id(item.id)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                        }
                        .onChange(of: shelf.selectedID) { _, id in
                            if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                        }
                        .onChange(of: shelf.items.map(\.id)) { _, _ in
                            if let id = shelf.selectedID { proxy.scrollTo(id) }
                        }
                    }
                }
            }
        }
        .background(ShelfKeyboardInput(isActive: isActive, shelf: shelf, pasteboard: pasteboard))
        .animation(.easeOut(duration: 0.15), value: targeted)
        .onDrop(of: ShelfStore.dropTypes, isTargeted: $targeted) { providers in
            shelf.handle(providers: providers)
        }
        .alert("Shelf", isPresented: Binding(
            get: { isActive && shelf.errorMessage != nil },
            set: { if !$0 { shelf.errorMessage = nil } }
        )) {
            Button("OK") { shelf.errorMessage = nil }
        } message: { Text(shelf.errorMessage ?? "") }
    }
}

struct ShelfTile: View {
    let item: ShelfItem
    @ObservedObject var shelf: ShelfStore
    @State private var thumbnail: NSImage?
    @State private var hovering = false
    private var selected: Bool { shelf.selectedID == item.id }

    // This view is built from several small pieces on purpose: one long chain of modifiers is slow
    // for the Swift compiler to type-check, and older compilers (GitHub's build machines) give up on it.
    var body: some View {
        accessible(interactive)
    }

    /// What the tile looks like.
    private var tile: some View {
        VStack(spacing: 3) {
            artwork.frame(width: 44, height: 38)
            Text(item.name)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 24, alignment: .top)
                .frame(width: 70)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
        .background(tileBackground)
        .overlay(tileBorder)
        .overlay(alignment: .topLeading) { pinBadge }
        .overlay(alignment: .topTrailing) { removeButton }
    }

    private var tileBackground: some View {
        let fill: Color = selected ? Color.accentColor.opacity(0.25) : Color.white.opacity(hovering ? 0.1 : 0)
        return RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fill)
    }

    private var tileBorder: some View {
        let color: Color = selected ? Color.accentColor : Color.clear
        return RoundedRectangle(cornerRadius: 10).strokeBorder(color)
    }

    @ViewBuilder private var pinBadge: some View {
        if item.isPinned {
            Image(systemName: "pin.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(3)
                .background(Circle().fill(.black.opacity(0.8)))
        }
    }

    @ViewBuilder private var removeButton: some View {
        if hovering {
            Button { shelf.remove(item) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color(white: 0.35))
            }
            .buttonStyle(.plain)
            .offset(x: 2, y: -2)
        }
    }

    /// Gestures, drag, context menu, tooltip and thumbnail loading.
    private var interactive: some View {
        tile
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
            .onTapGesture { shelf.selectedID = item.id }
            .onDrag {
                shelf.selectedID = item.id
                return item.dragProvider()
            }
            .contextMenu { menuItems }
            .help(item.detail)
            .task(id: item.id) { await loadThumbnail() }
    }

    @ViewBuilder private var menuItems: some View {
        Button("Preview") { ShelfPreview.shared.show(item) }
        Button("Open") { NSWorkspace.shared.open(item.url) }
        Button("Copy") { item.copy() }
        if item.kind == .file || item.kind == .image {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        }
        Button(item.isPinned ? "Unpin" : "Pin to Front") { shelf.togglePin(item) }
        Divider()
        Button("Remove from Shelf") { shelf.remove(item) }
    }

    private func accessible<V: View>(_ view: V) -> some View {
        let label: String = item.isPinned ? "\(item.name), pinned" : item.name
        let traits: AccessibilityTraits = selected ? .isSelected : []
        let pinTitle: String = item.isPinned ? "Unpin" : "Pin"
        return view
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
            .accessibilityAddTraits(traits)
            .accessibilityAction(named: Text("Preview")) { ShelfPreview.shared.show(item) }
            .accessibilityAction(named: Text(pinTitle)) { shelf.togglePin(item) }
    }

    @ViewBuilder private var artwork: some View {
        if item.kind == .link {
            Image(systemName: "link.circle.fill").font(.system(size: 30)).foregroundStyle(.blue)
        } else if item.kind == .text {
            Image(systemName: "text.quote").font(.system(size: 28)).foregroundStyle(.white.opacity(0.8))
        } else {
            Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable().scaledToFit()
                .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
        }
    }

    private func loadThumbnail() async {
        guard item.kind == .file || item.kind == .image else { return }
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url, size: CGSize(width: 64, height: 64), scale: 2, representationTypes: .thumbnail
        )
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            thumbnail = rep.nsImage
        }
    }
}

/// Home / Shelf switcher shown in the expanded header.
struct TabSwitcher: View {
    @ObservedObject var state: NotchState
    @ObservedObject var shelf: ShelfStore
    @ObservedObject var usage: UsageMonitor
    @AppStorage(Pref.showUsage) private var showUsage = true
    @AppStorage(Pref.scoresEnabled) private var showScores = true

    var body: some View {
        HStack(spacing: 2) {
            button(.home, symbol: "house.fill")
            button(.audio, symbol: "headphones")
            button(.shelf, symbol: "tray.fill")
            button(.timer, symbol: "timer")
            if showScores { button(.scores, symbol: "sportscourt.fill") }
            if showUsage { button(.usage, symbol: "") }
        }
        .padding(2)
        .background(Capsule().fill(.white.opacity(0.1)))
    }

    private func button(_ tab: NotchTab, symbol: String) -> some View {
        let selected = state.tab == tab
        return Button {
            guard state.tab != tab else { return }
            state.tab = tab
            Feedback.haptic(.light)
        } label: {
            ZStack(alignment: .topTrailing) {
                if tab == .usage {
                    // A ring that fills with how much of the 5-hour limit is used.
                    UsageRing(percent: usage.fiveHourPercent)
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 11))
                        .frame(width: 20, height: 20)
                }
                if tab == .shelf, !shelf.items.isEmpty {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6).offset(x: -3, y: 3)
                }
            }
            .foregroundStyle(.white.opacity(selected ? 1 : 0.55))
            .background(Capsule().fill(.white.opacity(selected ? 0.2 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}
