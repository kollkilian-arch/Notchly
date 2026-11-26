import XCTest
import AppKit
import ImageIO
import PDFKit
@testable import Notchly

final class ShelfFileToolsTests: XCTestCase {
    func testSubtitleRoundTripAndUnsupportedSettings() throws {
        let srt = "1\r\n00:00:01,250 --> 00:00:02,500\r\nHello!\r\n\r\n2\r\n00:00:03,000 --> 00:00:04,000\r\nWorld\r\n"
        let vtt = try ShelfFileTools.convertSubtitles(srt, toVTT: true)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n\n"))
        XCTAssertTrue(vtt.contains("00:00:01.250 --> 00:00:02.500"))
        let roundTrip = try ShelfFileTools.convertSubtitles(vtt, toVTT: false)
        XCTAssertEqual(roundTrip, srt.replacingOccurrences(of: "\r\n", with: "\n"))
        XCTAssertThrowsError(try ShelfFileTools.convertSubtitles("WEBVTT\n\n00:00:01.000 --> 00:00:02.000 align:start\nHi\n", toVTT: false))
    }

    func testResizeAndPDFRotationPreserveOriginal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 60, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let source = directory.appendingPathComponent("source.png")
        let resized = directory.appendingPathComponent("small.png")
        try png.write(to: source)
        try ShelfFileTools.apply(.resizeHalf, source: source, destination: resized)
        let result = try XCTUnwrap(CGImageSourceCreateWithURL(resized as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(result, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 50)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 30)
        XCTAssertEqual(try Data(contentsOf: source), png)
        XCTAssertThrowsError(try ShelfFileTools.apply(.resizeHalf, source: source, destination: source))

        let image = NSImage(size: NSSize(width: 100, height: 60))
        image.addRepresentation(bitmap)
        let page = try XCTUnwrap(PDFPage(image: image))
        let document = PDFDocument()
        document.insert(page, at: 0)
        let pdf = directory.appendingPathComponent("original.pdf")
        let rotated = directory.appendingPathComponent("rotated.pdf")
        let original = try XCTUnwrap(document.dataRepresentation())
        try original.write(to: pdf)
        try ShelfFileTools.apply(.rotatePDF, source: pdf, destination: rotated)
        XCTAssertEqual(PDFDocument(url: rotated)?.page(at: 0)?.rotation, 90)
        XCTAssertEqual(try Data(contentsOf: pdf), original)
        XCTAssertThrowsError(try ShelfFileTools.apply(.pdfText, source: pdf, destination: directory.appendingPathComponent("text.txt")))
    }
    func testDelimitedTextHandlesQuotesNewlinesAndEmptyFields() throws {
        let csv = "name,note,empty\r\n\"Doe, Jane\",\"Line 1\nLine \"\"2\"\"\",\r\n"
        let tsv = try DelimitedText.convert(csv, from: ",", to: "\t")
        XCTAssertEqual(tsv, "name\tnote\tempty\nDoe, Jane\t\"Line 1\nLine \"\"2\"\"\"\t\n")
        let roundTrip = try DelimitedText.convert(tsv, from: "\t", to: ",")
        XCTAssertEqual(roundTrip, csv.replacingOccurrences(of: "\r\n", with: "\n"))
        XCTAssertThrowsError(try DelimitedText.convert("\"unclosed", from: ",", to: "\t"))
    }

}
