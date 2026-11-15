import AppKit
import UniformTypeIdentifiers

struct ShelfItem: Identifiable, Equatable {
    let id: UUID
    var url: URL
    var name: String { url.lastPathComponent }
}

/// Files parked on the shelf. Items are references (not copies) kept as bookmarks,
/// so they survive the file being moved or renamed. Persisted across launches.
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []

    private struct Stored: Codable {
        var id: UUID
        var bookmark: Data
    }

    private let storeURL: URL

    /// - Parameter storeURL: where to persist the shelf (defaults to Application Support/Notchly/shelf.json).
    init(storeURL: URL? = nil) {
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let dir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Notchly", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.storeURL = dir.appendingPathComponent("shelf.json")
        }
        load()
    }

    // MARK: Mutations

    func add(_ urls: [URL]) {
        var changed = false
        for url in urls {
            let std = url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: std.path),
                  !items.contains(where: { $0.url.standardizedFileURL == std }) else { continue }
            items.insert(ShelfItem(id: UUID(), url: std), at: 0)
            changed = true
        }
        if changed { save() }
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    /// Accepts dropped file URLs. Returns `true` if any provider carried a file.
    func handle(providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                }
                guard let url else { return }
                DispatchQueue.main.async { self?.add([url]) }
            }
        }
        return accepted
    }

    // MARK: Persistence

    private func save() {
        let stored = items.compactMap { item -> Stored? in
            guard let data = try? item.url.bookmarkData() else { return nil }
            return Stored(id: item.id, bookmark: data)
        }
        try? JSONEncoder().encode(stored).write(to: storeURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let stored = try? JSONDecoder().decode([Stored].self, from: data) else { return }
        var needsSave = false
        items = stored.compactMap { s in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: s.bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale),
                  FileManager.default.fileExists(atPath: url.path) else { needsSave = true; return nil }
            if stale { needsSave = true }
            return ShelfItem(id: s.id, url: url)
        }
        if needsSave { save() }
    }
}
