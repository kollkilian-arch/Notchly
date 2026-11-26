import AppKit
import UniformTypeIdentifiers

struct ShelfItem: Identifiable, Equatable {
    enum Kind: String, Codable { case file, link, text, image }

    let id: UUID
    let kind: Kind
    var url: URL
    var text: String? = nil
    var isPinned = false

    var name: String {
        switch kind {
        case .file: return url.lastPathComponent
        case .link: return url.host ?? url.absoluteString
        case .text: return String((text ?? "Text snippet").trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        case .image: return "Pasted image"
        }
    }

    var detail: String { kind == .text ? (text ?? name) : url.absoluteString }

    /// Shelf-owned assets use UUIDs internally; never expose those as suggested names.
    var suggestedBaseName: String {
        switch kind {
        case .text: return "Text snippet"
        case .image: return "Pasted image"
        case .file: return url.deletingPathExtension().lastPathComponent
        case .link: return name
        }
    }

    var suggestedArchiveName: String {
        switch kind {
        case .text: return "Text snippet.txt.zip"
        case .image: return "Pasted image.png.zip"
        case .file, .link: return url.lastPathComponent + ".zip"
        }
    }

    func dragProvider() -> NSItemProvider {
        if kind == .text { return NSItemProvider(object: (text ?? "") as NSString) }
        return NSItemProvider(object: url as NSURL)
    }

    func copy(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        switch kind {
        case .text: pasteboard.writeObjects([(text ?? "") as NSString])
        case .image:
            if let image = NSImage(contentsOf: url) { pasteboard.writeObjects([image]) }
        case .file, .link: pasteboard.writeObjects([url as NSURL])
        }
    }
}

/// Original files remain bookmarks. Pasted images and snippet preview files live beside the index.
/// The optional fields in Stored also decode the original file-only shelf format.
final class ShelfStore: ObservableObject {
    static let dropTypes: [UTType] = [.fileURL, .url, .image, .text]

    @Published private(set) var items: [ShelfItem] = []
    @Published var selectedID: UUID?
    @Published var errorMessage: String?
    @Published private(set) var activeConversions = 0
    @Published private(set) var lastConversionID: UUID?

    func conversionStarted() {
        activeConversions += 1
        lastConversionID = nil
    }

    func conversionFinished(destination: URL?, error: String? = nil) {
        activeConversions = max(0, activeConversions - 1)
        if let error { errorMessage = error }
        if let destination {
            add([destination])
            lastConversionID = items.first(where: { $0.url.standardizedFileURL == destination.standardizedFileURL })?.id
        }
    }

    var selectedItem: ShelfItem? { items.first { $0.id == selectedID } }

    private struct Stored: Codable {
        var id: UUID
        var kind: ShelfItem.Kind?
        var bookmark: Data?
        var value: String?
        var assetName: String?
        var isPinned: Bool?
    }

    private let storeURL: URL
    private var fileBookmarks: [UUID: Data] = [:]
    private var assetsURL: URL { storeURL.deletingPathExtension().appendingPathExtension("assets") }

    init(storeURL: URL? = nil) {
        self.storeURL = storeURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notchly/shelf.json")
        load()
    }

    // MARK: Adding content

    func add(_ urls: [URL]) {
        for url in urls {
            if !url.isFileURL { _ = addLink(url); continue }
            let url = url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if let existing = items.first(where: { $0.url == url }) {
                selectedID = existing.id
                continue
            }
            insert(ShelfItem(id: UUID(), kind: .file, url: url))
        }
    }

    @discardableResult
    func addLink(_ url: URL) -> Bool {
        guard Self.webURL(url.absoluteString) != nil else { return false }
        if let existing = items.first(where: { $0.kind == .link && $0.url == url }) {
            selectedID = existing.id
            return true
        }
        return insert(ShelfItem(id: UUID(), kind: .link, url: url))
    }

    @discardableResult
    func addText(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if let url = Self.webURL(text) { return addLink(url) }
        if let existing = items.first(where: { $0.kind == .text && $0.text == text }) {
            selectedID = existing.id
            return true
        }
        let id = UUID()
        let url = assetsURL.appendingPathComponent("\(id).txt")
        return addOwned(ShelfItem(id: id, kind: .text, url: url, text: text), data: Data(text.utf8))
    }

    @discardableResult
    func addImage(_ data: Data) -> Bool {
        guard let image = NSBitmapImageRep(data: data),
              let png = image.representation(using: .png, properties: [:]) else {
            errorMessage = "This image couldn't be read."
            return false
        }
        let id = UUID()
        let url = assetsURL.appendingPathComponent("\(id).png")
        return addOwned(ShelfItem(id: id, kind: .image, url: url), data: png)
    }

    /// Only a standalone web address becomes a link; prose containing URLs stays intact.
    private static func webURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: { $0.isWhitespace }),
              let url = URL(string: trimmed),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    private func addOwned(_ item: ShelfItem, data: Data) -> Bool {
        do {
            try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
            try data.write(to: item.url, options: .atomic)
            if insert(item) { return true }
            try? FileManager.default.removeItem(at: item.url)
        } catch { errorMessage = "Couldn't save this item: \(error.localizedDescription)" }
        return false
    }

    @discardableResult
    private func insert(_ item: ShelfItem) -> Bool {
        guard save([item] + items) else { return false }
        selectedID = item.id
        return true
    }

    // MARK: Selection and pinning

    func select(offset: Int) {
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selectedID } ?? (offset > 0 ? -1 : items.count)
        selectedID = items[min(max(current + offset, 0), items.count - 1)].id
    }

    func togglePin(_ item: ShelfItem) {
        var updated = items
        guard let index = updated.firstIndex(where: { $0.id == item.id }) else { return }
        updated[index].isPinned.toggle()
        _ = save(updated)
    }

    func remove(_ item: ShelfItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        guard save(items.filter { $0.id != item.id }) else { return }
        if selectedID == item.id { selectedID = items.isEmpty ? nil : items[min(index, items.count - 1)].id }
        deleteOwnedAsset(item)
    }

    func clear() {
        let old = items
        guard save([]) else { return }
        selectedID = nil
        old.forEach(deleteOwnedAsset)
    }

    private func deleteOwnedAsset(_ item: ShelfItem) {
        guard item.kind == .text || item.kind == .image,
              item.url.deletingLastPathComponent().standardizedFileURL == assetsURL.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: item.url)
    }

    // MARK: Clipboard and drops

    /// Reads the clipboard only in response to Paste. Prefer the actual image over its text fallback.
    @discardableResult
    func paste(from pasteboard: NSPasteboard = .general) -> Bool {
        var accepted = false
        for item in pasteboard.pasteboardItems ?? [] {
            if let value = item.string(forType: .fileURL), let url = URL(string: value), url.isFileURL {
                add([url])
                accepted = true
            } else if let type = item.types.first(where: { UTType($0.rawValue)?.conforms(to: .image) == true }),
                      let data = item.data(forType: type) {
                accepted = addImage(data) || accepted
            } else if let value = item.string(forType: .URL), let url = Self.webURL(value) {
                accepted = addLink(url) || accepted
            } else if let text = item.string(forType: .string) {
                accepted = addText(text) || accepted
            }
        }
        if !accepted && errorMessage == nil { errorMessage = "Copy a file, web link, text, or screenshot, then paste it here." }
        return accepted
    }

    /// Load one representation per provider so a browser's link + title doesn't become two items.
    func handle(providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            let type: String
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                type = UTType.fileURL.identifier
            } else if let imageType = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
                type = imageType
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                type = UTType.url.identifier
            } else if provider.canLoadObject(ofClass: NSString.self) {
                accepted = true
                _ = provider.loadObject(ofClass: NSString.self) { [weak self] object, error in
                    DispatchQueue.main.async {
                        if let text = object as? String { _ = self?.addText(text) }
                        else { self?.errorMessage = error?.localizedDescription ?? "This text couldn't be read." }
                    }
                }
                continue
            } else { continue }
            accepted = true
            provider.loadDataRepresentation(forTypeIdentifier: type) { [weak self] data, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard let data else {
                        self.errorMessage = error?.localizedDescription ?? "This item couldn't be read."
                        return
                    }
                    if type == UTType.fileURL.identifier || type == UTType.url.identifier {
                        guard let url = URL(dataRepresentation: data, relativeTo: nil) else {
                            self.errorMessage = "This link couldn't be read."
                            return
                        }
                        if url.isFileURL { self.add([url]) }
                        else if !self.addLink(url) { _ = self.addText(url.absoluteString) }
                    } else { _ = self.addImage(data) }
                }
            }
        }
        return accepted
    }

    // MARK: Persistence

    @discardableResult
    private func save(_ updated: [ShelfItem]) -> Bool {
        let ordered = updated.filter(\.isPinned) + updated.filter { !$0.isPinned }
        do {
            var bookmarks: [UUID: Data] = [:]
            let stored = try ordered.map { item -> Stored in
                if item.kind == .file {
                    // A deleted or temporarily unavailable file must not block saving other items.
                    bookmarks[item.id] = (try? item.url.bookmarkData()) ?? fileBookmarks[item.id]
                    if bookmarks[item.id] == nil { throw CocoaError(.fileReadNoSuchFile) }
                }
                return Stored(id: item.id, kind: item.kind, bookmark: bookmarks[item.id],
                              value: item.kind == .link ? item.url.absoluteString : item.text,
                              assetName: (item.kind == .text || item.kind == .image) ? item.url.lastPathComponent : nil,
                              isPinned: item.isPinned)
            }
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(stored).write(to: storeURL, options: .atomic)
            fileBookmarks = bookmarks
            items = ordered
            return true
        } catch {
            errorMessage = "Couldn't save the shelf: \(error.localizedDescription)"
            return false
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        do {
            let stored = try JSONDecoder().decode([Stored].self, from: Data(contentsOf: storeURL))
            var needsSave = false
            let loaded = stored.compactMap { s -> ShelfItem? in
                let kind = s.kind ?? .file
                let url: URL
                switch kind {
                case .file:
                    var stale = false
                    guard let bookmark = s.bookmark,
                          let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil,
                                                  bookmarkDataIsStale: &stale),
                          FileManager.default.fileExists(atPath: resolved.path) else { needsSave = true; return nil }
                    url = resolved
                    fileBookmarks[s.id] = bookmark
                    if stale { needsSave = true }
                case .link:
                    guard let value = s.value, let link = Self.webURL(value) else { needsSave = true; return nil }
                    url = link
                case .text, .image:
                    guard let name = s.assetName, name == URL(fileURLWithPath: name).lastPathComponent else {
                        needsSave = true; return nil
                    }
                    url = assetsURL.appendingPathComponent(name)
                    if kind == .text, let value = s.value, !FileManager.default.fileExists(atPath: url.path) {
                        do {
                            try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
                            try Data(value.utf8).write(to: url, options: .atomic)
                        } catch { errorMessage = "Couldn't restore a text snippet: \(error.localizedDescription)"; return nil }
                    }
                    guard FileManager.default.fileExists(atPath: url.path) else { needsSave = true; return nil }
                }
                return ShelfItem(id: s.id, kind: kind, url: url,
                                 text: kind == .text ? s.value : nil, isPinned: s.isPinned ?? false)
            }
            items = loaded.filter(\.isPinned) + loaded.filter { !$0.isPinned }
            selectedID = items.first?.id
            if needsSave { _ = save(items) }
        } catch { errorMessage = "Couldn't load the shelf: \(error.localizedDescription)" }
    }
}
