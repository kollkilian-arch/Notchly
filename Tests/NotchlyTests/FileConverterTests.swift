import XCTest
import AppKit
import ImageIO
import AVFoundation
@testable import Notchly

final class FileConverterTests: XCTestCase {
    func testConvertsImageAndPreservesOriginal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.png")
        let output = directory.appendingPathComponent("converted.jpg")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                    isPlanar: false, colorSpaceName: .deviceRGB,
                                                    bytesPerRow: 0, bitsPerPixel: 0))
        let original = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try original.write(to: source)
        let jpeg = try XCTUnwrap(FileConverter.formats.first { $0.type == .jpeg })
        try FileConverter.write(source: source, destination: output, format: jpeg)
        XCTAssertEqual(try Data(contentsOf: source), original)
        let result = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(result) as String?, jpeg.type.identifier)
        XCTAssertThrowsError(try FileConverter.write(source: source, destination: source, format: jpeg))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    func testTextRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("original.txt")
        let rich = directory.appendingPathComponent("converted.rtf")
        let output = directory.appendingPathComponent("result.txt")
        try "Hello, café".write(to: source, atomically: true, encoding: .utf8)
        try MoreFileConversions.convertDocument(source: source, destination: rich, format: .rtf)
        try MoreFileConversions.convertDocument(source: rich, destination: output, format: .txt)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "Hello, café")
        XCTAssertThrowsError(try MoreFileConversions.convertDocument(source: source, destination: source, format: .rtf))
    }

    func testAudioExport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        let destination = directory.appendingPathComponent("output.m4a")
        let audioFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: 4410))
        buffer.frameLength = 4410
        do {
            let file = try AVAudioFile(forWriting: source, settings: audioFormat.settings)
            try file.write(from: buffer)
        }
        let done = expectation(description: "audio export")
        MoreFileConversions.exportMedia(source: source, destination: destination, format: .m4a) { result in
            if case .failure(let error) = result { XCTFail("Export failed: \(error)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 15)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testZipContainsOriginalFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.txt")
        let archive = directory.appendingPathComponent("archive.zip")
        let extracted = directory.appendingPathComponent("extracted")
        try "Hello".write(to: source, atomically: true, encoding: .utf8)
        try MoreFileConversions.createZip(source: source, destination: archive)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, extracted.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: extracted.appendingPathComponent("source.txt"), encoding: .utf8), "Hello")
        XCTAssertThrowsError(try MoreFileConversions.createZip(source: directory, destination: archive))
    }

}
