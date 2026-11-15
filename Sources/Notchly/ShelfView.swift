import SwiftUI
import UniformTypeIdentifiers
import QuickLookThumbnailing

struct ShelfView: View {
    @ObservedObject var shelf: ShelfStore
    @State private var targeted = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(targeted ? Color.accentColor.opacity(0.16) : Color.white.opacity(0.04))
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(targeted ? Color.accentColor : Color.white.opacity(0.18),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))

            if shelf.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 22))
                    Text("Drop files here").font(.system(size: 12, weight: .semibold))
                    Text("Drag them out again whenever you need them")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                }
                .foregroundStyle(.white.opacity(targeted ? 0.95 : 0.6))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(shelf.items) { item in
                            ShelfTile(item: item, shelf: shelf)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: targeted)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            shelf.handle(providers: providers)
        }
    }
}

struct ShelfTile: View {
    let item: ShelfItem
    @ObservedObject var shelf: ShelfStore
    @State private var thumbnail: NSImage?
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .scaledToFit()
                .frame(width: 54, height: 54)
                .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
            Text(item.name)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 70)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(hovering ? 0.1 : 0)))
        .overlay(alignment: .topTrailing) {
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
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { NSWorkspace.shared.open(item.url) }
        .onDrag { NSItemProvider(object: item.url as NSURL) }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(item.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Divider()
            Button("Remove from Shelf") { shelf.remove(item) }
        }
        .task(id: item.id) { await loadThumbnail() }
    }

    private func loadThumbnail() async {
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
