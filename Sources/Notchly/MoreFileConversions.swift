import AppKit
import AVFoundation
import UniformTypeIdentifiers
import Darwin

/// Additional local conversions using the codecs and document readers built into macOS.
enum MoreFileConversions {
    enum Format: String, Identifiable {
        case m4a, mp4, mov, txt, rtf
        var id: String { rawValue }
        var label: String { rawValue.uppercased() }
        var type: UTType {
            switch self {
            case .m4a: return .mpeg4Audio
            case .mp4: return .mpeg4Movie
            case .mov: return .quickTimeMovie
            case .txt: return .plainText
            case .rtf: return .rtf
            }
        }
    }

    static func formats(for item: ShelfItem) -> [Format] {
        guard item.kind == .file || item.kind == .text else { return [] }
        let ext = item.url.pathExtension.lowercased()
        if ["txt", "rtf"].contains(ext) { return [.txt, .rtf].filter { $0.rawValue != ext } }
        if ["mp3", "m4a", "aac", "wav", "aiff", "aif", "caf"].contains(ext) { return [.m4a] }
        if ["mp4", "m4v", "mov"].contains(ext) { return [.mp4, .mov, .m4a] }
        return []
    }

    static func convert(_ item: ShelfItem, to format: Format, shelf: ShelfStore) {
        let panel = NSSavePanel()
        panel.title = "Convert File"
        if item.kind == .file { panel.directoryURL = item.url.deletingLastPathComponent() }
        panel.prompt = "Convert"
        panel.allowedContentTypes = [format.type]
        let name = item.suggestedBaseName
        let sameExtension = item.url.pathExtension.lowercased() == format.rawValue
        panel.nameFieldStringValue = name + (sameExtension ? "-converted" : "") + "." + format.rawValue
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard item.url.resolvingSymlinksInPath().standardizedFileURL != destination.resolvingSymlinksInPath().standardizedFileURL else {
            shelf.errorMessage = "Choose a different file name to preserve the original."
            return
        }
        shelf.conversionStarted()
        if format == .txt || format == .rtf {
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try convertDocument(source: item.url, destination: destination, format: format)
                    DispatchQueue.main.async { shelf.conversionFinished(destination: destination) }
                } catch {
                    DispatchQueue.main.async { shelf.conversionFinished(destination: nil, error: "Couldn't convert the document: \(error.localizedDescription)") }
                }
            }
        } else {
            exportMedia(source: item.url, destination: destination, format: format) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success: shelf.conversionFinished(destination: destination)
                    case .failure(let error): shelf.conversionFinished(destination: nil, error: "Couldn't convert the media: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    static func compress(_ item: ShelfItem, shelf: ShelfStore) {
        let panel = NSSavePanel()
        panel.title = "Create ZIP Archive"
        if item.kind == .file { panel.directoryURL = item.url.deletingLastPathComponent() }
        panel.prompt = "Compress"
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = item.suggestedArchiveName
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let source = item.url.resolvingSymlinksInPath().standardizedFileURL
        let target = destination.resolvingSymlinksInPath().standardizedFileURL
        guard source != target, !target.path.hasPrefix(source.path + "/") else {
            shelf.errorMessage = "Choose a destination outside the original file or folder."
            return
        }
        shelf.conversionStarted()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try createZip(source: source, destination: destination)
                DispatchQueue.main.async { shelf.conversionFinished(destination: destination) }
            } catch {
                DispatchQueue.main.async { shelf.conversionFinished(destination: nil, error: "Couldn't create the archive: \(error.localizedDescription)") }
            }
        }
    }

    static func createZip(source: URL, destination: URL) throws {
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        let target = destination.resolvingSymlinksInPath().standardizedFileURL
        guard source != target, !target.path.hasPrefix(source.path + "/") else { throw FileConverter.ConversionError.sameFile }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
        process.arguments = ["-c", "-k", "--sequesterRsrc"] + (isDirectory.boolValue ? ["--keepParent"] : []) + [source.path, temporary.path]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw FileConverter.ConversionError.failed }
        guard rename(temporary.path, destination.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    static func convertDocument(source: URL, destination: URL, format: Format) throws {
        guard source.resolvingSymlinksInPath().standardizedFileURL != destination.resolvingSymlinksInPath().standardizedFileURL else { throw FileConverter.ConversionError.sameFile }
        let inputType: NSAttributedString.DocumentType = source.pathExtension.lowercased() == "rtf" ? .rtf : .plain
        let document = try NSAttributedString(url: source, options: [.documentType: inputType], documentAttributes: nil)
        let outputType: NSAttributedString.DocumentType = format == .rtf ? .rtf : .plain
        let data = try document.data(from: NSRange(location: 0, length: document.length), documentAttributes: [.documentType: outputType, .characterEncoding: String.Encoding.utf8.rawValue])
        try data.write(to: destination, options: .atomic)
    }

    static func exportMedia(source: URL, destination: URL, format: Format, completion: @escaping (Result<Void, Error>) -> Void) {
        let asset = AVURLAsset(url: source)
        let preset = format == .m4a ? AVAssetExportPresetAppleM4A : AVAssetExportPresetHighestQuality
        guard let export = AVAssetExportSession(asset: asset, presetName: preset) else {
            completion(.failure(FileConverter.ConversionError.unsupportedFormat)); return
        }
        let fileType: AVFileType = format == .m4a ? .m4a : (format == .mp4 ? .mp4 : .mov)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).\(format.rawValue)")
        export.outputURL = temporary
        export.outputFileType = fileType
        export.determineCompatibleFileTypes { types in
            guard types.contains(fileType) else {
                completion(.failure(FileConverter.ConversionError.unsupportedFormat)); return
            }
            export.exportAsynchronously {
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard export.status == .completed else {
                    completion(.failure(export.error ?? FileConverter.ConversionError.failed)); return
                }
                // rename atomically replaces a destination approved in the save panel.
                guard rename(temporary.path, destination.path) == 0 else {
                    completion(.failure(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))); return
                }
                completion(.success(()))
            }
        }
    }
}
