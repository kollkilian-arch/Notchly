import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Image conversion uses system codecs and leaves the original file untouched.
enum FileConverter {
    struct Format: Identifiable {
        let name: String
        let type: UTType
        var id: String { type.identifier }
    }

    static var formats: [Format] {
        let writable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        return ([Format(name: "PNG", type: .png), Format(name: "JPEG", type: .jpeg),
                Format(name: "TIFF", type: .tiff), Format(name: "GIF", type: .gif),
                Format(name: "HEIC", type: .heic), Format(name: "BMP", type: .bmp)]
            + ["webp", "avif"].compactMap { ext in
                UTType(filenameExtension: ext).map { Format(name: ext.uppercased(), type: $0) }
            }
            ).filter { writable.contains($0.type.identifier) }
    }

    static func canConvert(_ item: ShelfItem) -> Bool {
        guard item.kind == .file || item.kind == .image else { return false }
        guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) == 1
    }

    static func convert(_ item: ShelfItem, to format: Format, shelf: ShelfStore) {
        let panel = NSSavePanel()
        panel.title = "Convert Image"
        if item.kind == .file { panel.directoryURL = item.url.deletingLastPathComponent() }
        panel.prompt = "Convert"
        panel.allowedContentTypes = [format.type]
        let input = CGImageSourceCreateWithURL(item.url as CFURL, nil)
        let sameType = input.flatMap { CGImageSourceGetType($0) as String? } == format.type.identifier
        let name = item.suggestedBaseName
        panel.nameFieldStringValue = name + (sameType ? "-converted" : "") + "." + (format.type.preferredFilenameExtension ?? "")
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard destination.resolvingSymlinksInPath().standardizedFileURL != item.url.resolvingSymlinksInPath().standardizedFileURL else {
            shelf.errorMessage = "Choose a different file name to preserve the original."
            return
        }
        shelf.conversionStarted()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try write(source: item.url, destination: destination, format: format)
                DispatchQueue.main.async { shelf.conversionFinished(destination: destination) }
            } catch {
                DispatchQueue.main.async { shelf.conversionFinished(destination: nil, error: "Couldn't convert the image: \(error.localizedDescription)") }
            }
        }
    }

    static func write(source: URL, destination: URL, format: Format) throws {
        guard source.resolvingSymlinksInPath().standardizedFileURL != destination.resolvingSymlinksInPath().standardizedFileURL else { throw ConversionError.sameFile }
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              CGImageSourceGetCount(imageSource) == 1 else { throw ConversionError.invalidImage }
        // Write beside the destination first so a failed conversion cannot leave a partial file.
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let writer = CGImageDestinationCreateWithURL(temporary as CFURL, format.type.identifier as CFString, 1, nil) else {
            throw ConversionError.unsupportedFormat
        }
        CGImageDestinationAddImageFromSource(writer, imageSource, 0, nil)
        guard CGImageDestinationFinalize(writer) else { throw ConversionError.failed }
        let data = try Data(contentsOf: temporary)
        try data.write(to: destination, options: .atomic)
    }

    enum ConversionError: LocalizedError {
        case sameFile, invalidImage, unsupportedFormat, failed
        var errorDescription: String? {
            switch self {
            case .sameFile: return "Choose a different file name to preserve the original."
            case .invalidImage: return "The source must be a readable, single-frame image."
            case .unsupportedFormat: return "This format is not available on this Mac."
            case .failed: return "The image encoder could not save this file."
            }
        }
    }
}
