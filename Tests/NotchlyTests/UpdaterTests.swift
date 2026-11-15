import XCTest
@testable import Notchly

final class UpdaterTests: XCTestCase {
    private let base = "https://github.com/kollkilian-arch/Notchly/releases/download/v0.1.3"

    // MARK: Version comparison

    func testVersionComparisonIsNumericAndComponentWise() {
        let cases: [(remote: String, local: String, newer: Bool)] = [
            ("0.1.3", "0.1.2", true), ("0.1.2", "0.1.2", false), ("0.1.1", "0.1.2", false),
            ("0.1.10", "0.1.9", true), ("0.2", "0.1.99", true), ("1.0.0", "0.9.9", true),
            ("0.1.2.1", "0.1.2", true), ("0.1.3-beta", "0.1.2", true),
            ("garbage", "0.1.2", false), ("", "0.1.2", false),
        ]
        for c in cases {
            XCTAssertEqual(Updater.isNewer(c.remote, than: c.local), c.newer, "isNewer(\(c.remote), \(c.local))")
        }
    }

    // MARK: Release parsing

    private var releaseJSON: Data {
        Data(#"{"tag_name":"v0.1.3","html_url":"https://github.com/kollkilian-arch/Notchly/releases/tag/v0.1.3","draft":false,"prerelease":false,"body":"x","assets":[{"name":"Notchly-0.1.3.zip.sha256","size":98,"browser_download_url":"\#(base)/Notchly-0.1.3.zip.sha256"},{"name":"Notchly-0.1.3.zip","size":578000,"browser_download_url":"\#(base)/Notchly-0.1.3.zip"}]}"#.utf8)
    }

    func testParsesReleaseAndTellsAssetsApart() throws {
        let release = try Updater.parseRelease(releaseJSON)
        XCTAssertEqual(release.version, "0.1.3")
        XCTAssertEqual(release.tag, "v0.1.3")
        XCTAssertEqual(release.zip?.name, "Notchly-0.1.3.zip")
        XCTAssertEqual(release.sha256?.name, "Notchly-0.1.3.zip.sha256")
        XCTAssertTrue(release.pageURL.absoluteString.hasSuffix("/tag/v0.1.3"))
    }

    func testIgnoresDraftsPrereleasesAndGarbage() {
        XCTAssertThrowsError(try Updater.parseRelease(Data(#"{"tag_name":"v9","html_url":"https://x.y","prerelease":true}"#.utf8)))
        XCTAssertThrowsError(try Updater.parseRelease(Data(#"{"tag_name":"v9","html_url":"https://x.y","draft":true}"#.utf8)))
        XCTAssertThrowsError(try Updater.parseRelease(Data("not json".utf8)))
    }

    func testReleaseWithoutAssetsHasNothingToInstall() throws {
        let release = try Updater.parseRelease(Data(#"{"tag_name":"v0.1.3","html_url":"https://x.y"}"#.utf8))
        XCTAssertNil(release.zip)
    }

    // MARK: Translocation

    func testTranslocatedPaths() {
        XCTAssertTrue(Updater.isTranslocatedPath(URL(fileURLWithPath: "/private/var/folders/hn/abc/T/AppTranslocation/3AA87629-664A/d/Notchly.app")))
        XCTAssertFalse(Updater.isTranslocatedPath(URL(fileURLWithPath: "/Applications/Notchly.app")))
        XCTAssertFalse(Updater.isTranslocatedPath(URL(fileURLWithPath: "/Users/x/Downloads/Notchly.app")))
    }

    func testOriginalLocationLookupDoesNotInventPaths() {
        let normal = Updater.originalLocation(ofTranslocated: URL(fileURLWithPath: "/Applications/Notchly.app"))
        XCTAssertTrue(normal == nil || normal?.path == "/Applications/Notchly.app")
    }

    // MARK: Safety checks before anything is downloaded

    private func release(zip: String, sha: String) -> AppRelease {
        AppRelease(version: "0.1.3", tag: "v0.1.3", pageURL: URL(string: "https://example.com")!,
                   zip: .init(name: "Notchly-0.1.3.zip", url: URL(string: zip)!, size: 1),
                   sha256: .init(name: "Notchly-0.1.3.zip.sha256", url: URL(string: sha)!, size: 1))
    }

    private func stageError(_ release: AppRelease) async -> UpdateError? {
        do {
            _ = try await Updater.stage(release: release, currentApp: URL(fileURLWithPath: "/Applications/Notchly.app"),
                                        allowInsecure: false, progress: { _ in })
            return nil
        } catch { return error as? UpdateError }
    }

    func testStageRefusesDownloadsFromOtherHosts() async {
        let foreign = release(zip: "https://evil.example.com/Notchly-0.1.3.zip", sha: "\(base)/Notchly-0.1.3.zip.sha256")
        guard case .insecureURL(let host)? = await stageError(foreign) else { return XCTFail("expected insecureURL") }
        XCTAssertEqual(host, "evil.example.com")
    }

    func testStageRefusesOtherRepositoriesOnGitHub() async {
        let other = release(zip: "https://github.com/someone-else/Notchly/releases/download/v0.1.3/Notchly-0.1.3.zip",
                            sha: "\(base)/Notchly-0.1.3.zip.sha256")
        guard case .insecureURL? = await stageError(other) else { return XCTFail("expected insecureURL") }
    }

    func testStageRefusesPlainHTTP() async {
        let http = release(zip: "http://github.com/kollkilian-arch/Notchly/releases/download/v0.1.3/Notchly-0.1.3.zip",
                           sha: "\(base)/Notchly-0.1.3.zip.sha256")
        guard case .insecureURL? = await stageError(http) else { return XCTFail("expected insecureURL") }
    }

    func testStageNeedsBothZipAndChecksum() async {
        let noChecksum = AppRelease(version: "0.1.3", tag: "v0.1.3", pageURL: URL(string: "https://example.com")!,
                                    zip: .init(name: "z", url: URL(string: "\(base)/Notchly-0.1.3.zip")!, size: 1), sha256: nil)
        guard case .noInstallableAsset? = await stageError(noChecksum) else { return XCTFail("expected noInstallableAsset") }
    }

    // MARK: Replacing the app

    private func makeFakeApp(at url: URL, marker: String) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try marker.write(to: url.appendingPathComponent("Contents/marker.txt"), atomically: true, encoding: .utf8)
    }

    private func marker(of app: URL) -> String? {
        try? String(contentsOf: app.appendingPathComponent("Contents/marker.txt"), encoding: .utf8)
    }

    func testReplaceSwapsInTheNewVersionAndRemovesTheBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotchlyReplace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let installDir = root.appendingPathComponent("Applications")
        let target = installDir.appendingPathComponent("Notchly.app")
        let staged = root.appendingPathComponent("work/unzipped/Notchly.app")
        try makeFakeApp(at: target, marker: "old")
        try makeFakeApp(at: staged, marker: "new")

        try Updater.replace(target: target, with: staged)

        XCTAssertEqual(marker(of: target), "new")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: installDir.path)
        XCTAssertEqual(leftovers, ["Notchly.app"], "the previous version's backup must be cleaned up")
    }

    func testReplaceRestoresTheOldVersionWhenTheCopyFails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotchlyReplace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let installDir = root.appendingPathComponent("Applications")
        let target = installDir.appendingPathComponent("Notchly.app")
        try makeFakeApp(at: target, marker: "old")
        let missing = root.appendingPathComponent("work/unzipped/Notchly.app")      // never created

        XCTAssertThrowsError(try Updater.replace(target: target, with: missing))
        XCTAssertEqual(marker(of: target), "old", "a failed update must leave the running app untouched")
    }
}
