import AppKit
import Combine
import UniformTypeIdentifiers
import XCTest
@testable import Notchly

final class ShelfStoreTests: XCTestCase {
    private var directory: URL!
    private var index: URL { directory.appendingPathComponent("shelf.json") }
    private var pasteboard: NSPasteboard!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pasteboard = NSPasteboard.withUniqueName()
    }

    override func tearDownWithError() throws {
        pasteboard.releaseGlobally()
        try FileManager.default.removeItem(at: directory)
    }

    func testLegacyBookmarksSurviveMigrationAndPinning() throws {
        struct Legacy: Encodable { let id: UUID; let bookmark: Data }
        let original = directory.appendingPathComponent("original.txt")
        try Data("Original file".utf8).write(to: original)
        let id = UUID()
        try JSONEncoder().encode([Legacy(id: id, bookmark: try original.bookmarkData())]).write(to: index)

        let shelf = ShelfStore(storeURL: index)
        XCTAssertNil(shelf.errorMessage)
        XCTAssertEqual(shelf.items.map(\.id), [id])
        XCTAssertEqual(shelf.items.first?.kind, .file)
        shelf.togglePin(try XCTUnwrap(shelf.items.first))
        XCTAssertTrue(shelf.addText("A new snippet"))

        let reloaded = ShelfStore(storeURL: index)
        XCTAssertEqual(reloaded.items.first?.id, id)
        XCTAssertEqual(reloaded.items.first?.isPinned, true)
        reloaded.remove(try XCTUnwrap(reloaded.items.first))
        XCTAssertEqual(try String(contentsOf: original), "Original file")
    }

    func testMixedItemsAndPinOrderPersist() throws {
        let shelf = ShelfStore(storeURL: index)
        XCTAssertTrue(shelf.addText("First snippet\nwith a second line"))
        let text = try XCTUnwrap(shelf.items.first)
        XCTAssertTrue(shelf.addText("https://example.com/docs?q=hello#section"))
        shelf.togglePin(text)
        XCTAssertTrue(shelf.addImage(try imageData(.png)))
        XCTAssertEqual(shelf.items.map(\.kind), [.text, .image, .link])

        let reloaded = ShelfStore(storeURL: index)
        XCTAssertNil(reloaded.errorMessage)
        XCTAssertEqual(reloaded.items, shelf.items)
        XCTAssertEqual(try String(contentsOf: text.url), text.text)
        reloaded.togglePin(try XCTUnwrap(reloaded.items.first))
        XCTAssertFalse(reloaded.items.contains(where: \.isPinned))
        XCTAssertFalse(ShelfStore(storeURL: index).items.contains(where: \.isPinned))
    }

    func testOnlyStandaloneWebURLsBecomeLinks() {
        let shelf = ShelfStore(storeURL: index)
        let prose = "See https://example.com for details.\n  Keep this formatting. 🎉"
        XCTAssertTrue(shelf.addText(prose))
        XCTAssertEqual(shelf.items.first?.kind, .text)
        XCTAssertEqual(shelf.items.first?.text, prose)
        XCTAssertTrue(shelf.addText("  https://example.com/path  \n"))
        XCTAssertEqual(shelf.items.first?.kind, .link)
        XCTAssertEqual(shelf.items.first?.url.absoluteString, "https://example.com/path")
        XCTAssertTrue(shelf.addText("file:///etc/hosts"))
        XCTAssertEqual(shelf.items.first?.kind, .text)
        XCTAssertFalse(shelf.addLink(URL(string: "javascript:alert(1)")!))
        XCTAssertFalse(shelf.addText(" \n\t "))
        XCTAssertEqual(shelf.items.count, 3)
    }

    func testDuplicateContentSelectsExistingItem() throws {
        let shelf = ShelfStore(storeURL: index)
        shelf.addText("A snippet")
        let snippetID = shelf.selectedID
        shelf.addText("https://example.com")
        shelf.addText("A snippet")
        XCTAssertEqual(shelf.selectedID, snippetID)
        shelf.add([URL(string: "https://example.com")!])
        XCTAssertEqual(shelf.items.count, 2)
        let file = directory.appendingPathComponent("file.txt")
        try Data().write(to: file)
        shelf.add([file, file])
        XCTAssertEqual(shelf.items.count, 3)
    }

    func testPastedScreenshotWinsOverTextFallbackAndSurvivesRestart() throws {
        let representation = NSPasteboardItem()
        representation.setData(try imageData(.tiff), forType: .tiff)
        representation.setString("Screenshot", forType: .string)
        pasteboard.writeObjects([representation])
        let shelf = ShelfStore(storeURL: index)
        XCTAssertTrue(shelf.paste(from: pasteboard))
        XCTAssertEqual(shelf.items.count, 1)
        let image = try XCTUnwrap(shelf.items.first)
        XCTAssertEqual(image.kind, .image)
        XCTAssertEqual(image.url.pathExtension, "png")
        XCTAssertNotNil(NSBitmapImageRep(data: try Data(contentsOf: image.url)))
        XCTAssertEqual(ShelfStore(storeURL: index).items, shelf.items)
        shelf.remove(image)
        XCTAssertFalse(FileManager.default.fileExists(atPath: image.url.path))
    }

    func testClipboardSupportsMultipleFilesLinksAndText() throws {
        let file = directory.appendingPathComponent("file.txt")
        try Data().write(to: file)
        let fileItem = NSPasteboardItem()
        fileItem.setString(file.absoluteString, forType: .fileURL)
        fileItem.setString("file.txt", forType: .string)
        let linkItem = NSPasteboardItem()
        linkItem.setString("https://example.com", forType: .URL)
        linkItem.setString("Website title", forType: .string)
        let textItem = NSPasteboardItem()
        textItem.setString("Snippet\nFull contents", forType: .string)
        pasteboard.writeObjects([fileItem, linkItem, textItem])
        let shelf = ShelfStore(storeURL: index)
        XCTAssertTrue(shelf.paste(from: pasteboard))
        XCTAssertEqual(shelf.items.map(\.kind), [.text, .link, .file])
        XCTAssertEqual(shelf.items.first?.text, "Snippet\nFull contents")
    }

    func testCopyRoundTripsSnippetsLinksAndImages() throws {
        let source = ShelfStore(storeURL: index)
        source.addText("  A snippet\nWith formatting.  ")
        source.addLink(URL(string: "https://example.com/path")!)
        source.addImage(try imageData(.png))
        let destination = ShelfStore(storeURL: directory.appendingPathComponent("other.json"))
        for item in source.items {
            item.copy(to: pasteboard)
            XCTAssertTrue(destination.paste(from: pasteboard))
        }
        XCTAssertEqual(Set(destination.items.map(\.kind)), Set(source.items.map(\.kind)))
        XCTAssertEqual(destination.items.first { $0.kind == .text }?.text, "  A snippet\nWith formatting.  ")
    }

    func testDroppedContentUsesOneRepresentationAndCanBeDraggedBackOut() throws {
        let shelf = ShelfStore(storeURL: index)
        let link = NSItemProvider(object: URL(string: "https://example.com/drop")! as NSURL)
        link.registerObject("Website title" as NSString, visibility: .all)
        let snippet = NSItemProvider(object: "Dropped text 🎉" as NSString)
        let image = NSItemProvider(item: try imageData(.png) as NSData, typeIdentifier: UTType.png.identifier)
        image.registerObject("Image fallback" as NSString, visibility: .all)
        let file = directory.appendingPathComponent("file.txt")
        try Data().write(to: file)
        XCTAssertTrue(shelf.handle(providers: [link, snippet, image, NSItemProvider(object: file as NSURL)]))
        waitForItems(4, on: shelf)
        XCTAssertEqual(Set(shelf.items.map(\.kind)), [.file, .link, .text, .image])
        XCTAssertEqual(shelf.items.first { $0.kind == .text }?.text, "Dropped text 🎉")

        let destination = ShelfStore(storeURL: directory.appendingPathComponent("other.json"))
        XCTAssertTrue(destination.handle(providers: shelf.items.map { $0.dragProvider() }))
        waitForItems(4, on: destination)
        XCTAssertEqual(destination.items.filter { $0.kind == .link }.count, 1)
        XCTAssertEqual(destination.items.first { $0.kind == .text }?.text, "Dropped text 🎉")
    }

    func testClearDeletesOwnedAssetsAndKeepsOriginalFiles() throws {
        let shelf = ShelfStore(storeURL: index)
        let original = directory.appendingPathComponent("original.png")
        try imageData(.png).write(to: original)
        shelf.add([original])
        shelf.addText("Text")
        shelf.addImage(try imageData(.png))
        let owned = shelf.items.filter { $0.kind == .text || $0.kind == .image }.map(\.url)
        shelf.clear()
        XCTAssertTrue(shelf.items.isEmpty)
        XCTAssertTrue(ShelfStore(storeURL: index).items.isEmpty)
        XCTAssertNil(shelf.selectedID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(owned.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testFailedSaveDoesNotAddAnItemOrLeaveAnImage() throws {
        // A directory in place of the JSON file forces an atomic write failure.
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        let shelf = ShelfStore(storeURL: index)
        XCTAssertFalse(shelf.addImage(try imageData(.png)))
        XCTAssertTrue(shelf.items.isEmpty)
        XCTAssertNotNil(shelf.errorMessage)
        let assets = index.deletingPathExtension().appendingPathExtension("assets")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: assets.path), [])
    }

    func testMissingSnippetPreviewIsRecreatedWithoutLosingText() throws {
        let shelf = ShelfStore(storeURL: index)
        shelf.addText("Keep me")
        let item = try XCTUnwrap(shelf.items.first)
        try FileManager.default.removeItem(at: item.url)
        let reloaded = ShelfStore(storeURL: index)
        XCTAssertEqual(reloaded.items, shelf.items)
        XCTAssertEqual(try String(contentsOf: item.url), "Keep me")
    }

    func testUnavailableOriginalDoesNotBlockSavingNewContent() throws {
        let shelf = ShelfStore(storeURL: index)
        let original = directory.appendingPathComponent("original.txt")
        try Data().write(to: original)
        shelf.add([original])
        try FileManager.default.removeItem(at: original)
        XCTAssertTrue(shelf.addText("New content"))
        XCTAssertNil(shelf.errorMessage)
        let reloaded = ShelfStore(storeURL: index)
        XCTAssertEqual(reloaded.items.map(\.text), ["New content"])
    }

    func testSelectionClampsAtEdgesAndSurvivesRemoval() throws {
        let shelf = ShelfStore(storeURL: index)
        shelf.addText("First")
        shelf.addText("Second")
        shelf.selectedID = nil
        shelf.select(offset: 1)
        XCTAssertEqual(shelf.selectedItem?.text, "Second")
        shelf.select(offset: -1)
        XCTAssertEqual(shelf.selectedItem?.text, "Second")
        shelf.select(offset: 1)
        shelf.select(offset: 1)
        XCTAssertEqual(shelf.selectedItem?.text, "First")
        shelf.remove(try XCTUnwrap(shelf.selectedItem))
        XCTAssertEqual(shelf.selectedItem?.text, "Second")
    }

    private func imageData(_ type: NSBitmapImageRep.FileType) throws -> Data {
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        let blue = NSColor(deviceRed: 0.2, green: 0.5, blue: 0.9, alpha: 1)
        for x in 0..<2 { for y in 0..<2 { image.setColor(blue, atX: x, y: y) } }
        return try XCTUnwrap(image.representation(using: type, properties: [:]))
    }

    private func waitForItems(_ count: Int, on shelf: ShelfStore) {
        let loaded = expectation(description: "Loaded dropped items")
        let subscription = shelf.$items.first { $0.count == count }.sink { _ in loaded.fulfill() }
        wait(for: [loaded], timeout: 5)
        withExtendedLifetime(subscription) {}
    }
}
