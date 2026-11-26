import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Small, local file tools. Each operation writes a new file chosen by the user.
enum ShelfFileTools {
    enum Tool: String {
        case resizeHalf, resizeQuarter, compressJPEG, pdfText, rotatePDF, srt, vtt, csv, tsv

        var title: String {
            switch self {
            case .resizeHalf: return "Resize to 50%…"
            case .resizeQuarter: return "Resize to 25%…"
            case .compressJPEG: return "Compress as JPEG…"
            case .pdfText: return "Extract PDF Text…"
            case .rotatePDF: return "Rotate PDF Clockwise…"
            case .srt: return "Convert to SRT…"
            case .vtt: return "Convert to WebVTT…"
            case .csv: return "Convert to CSV…"
            case .tsv: return "Convert to TSV…"
            }
        }
        var ext: String {
            switch self {
            case .resizeHalf, .resizeQuarter: return "png"
            case .compressJPEG: return "jpg"
            case .pdfText: return "txt"
            case .rotatePDF: return "pdf"
            case .srt: return "srt"
            case .vtt: return "vtt"
            case .csv: return "csv"
            case .tsv: return "tsv"
            }
        }
    }

    static func tools(for item: ShelfItem) -> [Tool] {
        guard item.kind == .file || item.kind == .image else { return [] }
        if FileConverter.canConvert(item) { return [.resizeHalf, .resizeQuarter, .compressJPEG] }
        switch item.url.pathExtension.lowercased() {
        case "pdf": return [.pdfText, .rotatePDF]
        case "srt": return [.vtt]
        case "vtt": return [.srt]
        case "csv": return [.tsv]
        case "tsv": return [.csv]
        default: return []
        }
    }

    static func run(_ tool: Tool, item: ShelfItem, shelf: ShelfStore) {
        let panel = NSSavePanel()
        panel.title = tool.title.replacingOccurrences(of: "…", with: "")
        if item.kind == .file { panel.directoryURL = item.url.deletingLastPathComponent() }
        panel.prompt = "Save"
        if let type = UTType(filenameExtension: tool.ext) { panel.allowedContentTypes = [type] }
        panel.nameFieldStringValue = item.suggestedBaseName + "-" + suffix(tool) + "." + tool.ext
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard differentFiles(item.url, destination) else {
            shelf.errorMessage = FileConverter.ConversionError.sameFile.localizedDescription
            return
        }
        shelf.conversionStarted()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try apply(tool, source: item.url, destination: destination)
                DispatchQueue.main.async { shelf.conversionFinished(destination: destination) }
            } catch {
                DispatchQueue.main.async { shelf.conversionFinished(destination: nil, error: "Couldn't process the file: \(error.localizedDescription)") }
            }
        }
    }

    private static func suffix(_ tool: Tool) -> String {
        switch tool {
        case .resizeHalf: return "50-percent"
        case .resizeQuarter: return "25-percent"
        case .compressJPEG: return "compressed"
        case .rotatePDF: return "rotated"
        default: return "converted"
        }
    }

    static func differentFiles(_ source: URL, _ destination: URL) -> Bool {
        source.resolvingSymlinksInPath().standardizedFileURL != destination.resolvingSymlinksInPath().standardizedFileURL
    }

    static func apply(_ tool: Tool, source: URL, destination: URL) throws {
        guard differentFiles(source, destination) else { throw FileConverter.ConversionError.sameFile }
        switch tool {
        case .resizeHalf, .resizeQuarter, .compressJPEG:
            try writeImage(tool, source: source, destination: destination)
        case .pdfText, .rotatePDF:
            guard let document = PDFDocument(url: source), !document.isLocked else { throw ToolError.invalidPDF }
            if tool == .pdfText {
                guard let text = document.string, !text.isEmpty else { throw ToolError.noText }
                try Data(text.utf8).write(to: destination, options: .atomic)
            } else {
                for index in 0..<document.pageCount {
                    guard let page = document.page(at: index) else { throw ToolError.invalidPDF }
                    page.rotation = (page.rotation + 90) % 360
                }
                guard let data = document.dataRepresentation() else { throw ToolError.invalidPDF }
                try data.write(to: destination, options: .atomic)
            }
        case .csv, .tsv:
            let data = try Data(contentsOf: source)
            guard let text = String(data: data, encoding: .utf8) else { throw ToolError.invalidDelimitedText }
            let bom = text.hasPrefix("\u{feff}")
            let content = bom ? String(text.dropFirst()) : text
            let result = try DelimitedText.convert(content, from: tool == .csv ? "\t" : ",", to: tool == .csv ? "," : "\t")
            try Data(((bom ? "\u{feff}" : "") + result).utf8).write(to: destination, options: .atomic)
        case .srt, .vtt:
            let data = try Data(contentsOf: source)
            guard let text = String(data: data, encoding: .utf8) else { throw ToolError.invalidSubtitles }
            let converted = try convertSubtitles(text, toVTT: tool == .vtt)
            try Data(converted.utf8).write(to: destination, options: .atomic)
        }
    }

    private static func writeImage(_ tool: Tool, source: URL, destination: URL) throws {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(input) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw FileConverter.ConversionError.invalidImage }
        let scale: Double = tool == .resizeHalf ? 0.5 : (tool == .resizeQuarter ? 0.25 : 1)
        let maxDimension = max(1, Int((Double(max(width, height)) * scale).rounded()))
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                       kCGImageSourceCreateThumbnailWithTransform: true,
                                       kCGImageSourceThumbnailMaxPixelSize: maxDimension]
        guard let image = CGImageSourceCreateThumbnailAtIndex(input, 0, options as CFDictionary) else { throw FileConverter.ConversionError.invalidImage }
        let data = NSMutableData()
        let type = tool == .compressJPEG ? UTType.jpeg : UTType.png
        guard let output = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { throw FileConverter.ConversionError.unsupportedFormat }
        let outputOptions: [CFString: Any] = tool == .compressJPEG ? [kCGImageDestinationLossyCompressionQuality: 0.75] : [:]
        CGImageDestinationAddImage(output, image, outputOptions as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw FileConverter.ConversionError.failed }
        try (data as Data).write(to: destination, options: .atomic)
    }

    static func convertSubtitles(_ text: String, toVTT: Bool) throws -> String {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if normalized.hasPrefix("\u{feff}") { normalized.removeFirst() }
        if toVTT {
            guard !normalized.hasPrefix("WEBVTT") else { throw ToolError.invalidSubtitles }
        } else {
            guard normalized.hasPrefix("WEBVTT"), let firstNewline = normalized.firstIndex(of: "\n") else { throw ToolError.invalidSubtitles }
            let header = normalized[..<firstNewline]
            guard header.trimmingCharacters(in: .whitespaces) == "WEBVTT" else { throw ToolError.unsupportedSubtitles }
            normalized = String(normalized[normalized.index(after: firstNewline)...])
            // SRT cannot faithfully represent WebVTT styles, regions, notes or cue settings.
            let lines = normalized.components(separatedBy: "\n")
            if lines.contains(where: { $0.hasPrefix("STYLE") || $0.hasPrefix("REGION") || $0.hasPrefix("NOTE") }) { throw ToolError.unsupportedSubtitles }
        }
        normalized = normalized.trimmingCharacters(in: .newlines)
        let blocks = normalized.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !blocks.isEmpty else { throw ToolError.invalidSubtitles }
        let timestampPattern = #"^(\d{2,}):(\d{2}):(\d{2})[,.](\d{3}) --> (\d{2,}):(\d{2}):(\d{2})[,.](\d{3})$"#
        var result: [String] = []
        for (index, block) in blocks.enumerated() {
            var lines = block.components(separatedBy: "\n")
            guard let timingIndex = lines.firstIndex(where: { $0.contains(" --> ") }), timingIndex <= 1,
                  lines[timingIndex].range(of: timestampPattern, options: .regularExpression) != nil,
                  timingIndex + 1 < lines.count else { throw ToolError.unsupportedSubtitles }
            lines[timingIndex] = lines[timingIndex].replacingOccurrences(of: toVTT ? "," : ".", with: toVTT ? "." : ",")
            if !toVTT {
                if timingIndex == 1 {
                    guard Int(lines[0]) != nil else { throw ToolError.unsupportedSubtitles }
                    lines.removeFirst()
                }
                lines.insert(String(index + 1), at: 0)
            }
            result.append(lines.joined(separator: "\n"))
        }
        return (toVTT ? "WEBVTT\n\n" : "") + result.joined(separator: "\n\n") + "\n"
    }

    enum ToolError: LocalizedError {
        case invalidPDF, noText, invalidSubtitles, unsupportedSubtitles, invalidDelimitedText
        var errorDescription: String? {
            switch self {
            case .invalidDelimitedText: return "The table must be UTF-8 encoded."
            case .invalidPDF: return "The PDF is unreadable or locked."
            case .noText: return "This PDF has no extractable text. Scanned pages need OCR."
            case .invalidSubtitles: return "The subtitle file must be valid UTF-8."
            case .unsupportedSubtitles: return "This subtitle file uses cues or settings that cannot be converted without losing information."
            }
        }
    }
}
