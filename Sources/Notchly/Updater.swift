import AppKit
import CryptoKit
import Security

// MARK: - Models

struct AppRelease: Equatable {
    struct Asset: Equatable {
        let name: String
        let url: URL
        let size: Int
    }

    let version: String          // "0.1.3"
    let tag: String              // "v0.1.3"
    let pageURL: URL
    let zip: Asset?              // Notchly-<version>.zip
    let sha256: Asset?           // Notchly-<version>.zip.sha256
}

enum UpdateError: LocalizedError {
    case network(String)
    case notFound
    case rateLimited
    case badResponse
    case noInstallableAsset
    case insecureURL(String)
    case checksumMismatch
    case badArchive
    case wrongApp(String)
    case signatureMismatch
    case notWritable(String)
    case replaceFailed(String)

    var errorDescription: String? {
        switch self {
        case .network(let m): return "Couldn't reach GitHub (\(m))."
        case .notFound: return "No release was found. If the repository is private, updates can't be checked."
        case .rateLimited: return "GitHub is limiting requests right now. Try again later."
        case .badResponse: return "GitHub sent a response Notchly couldn't read."
        case .noInstallableAsset: return "This release has no downloadable app."
        case .insecureURL(let u): return "Refusing to download from an unexpected address (\(u))."
        case .checksumMismatch: return "The download is damaged (checksum doesn't match). Nothing was changed."
        case .badArchive: return "The download didn't contain the app. Nothing was changed."
        case .wrongApp(let m): return "The download isn't the expected app (\(m)). Nothing was changed."
        case .signatureMismatch:
            return "The new version isn't signed by the same developer as this one, so it was not installed."
        case .notWritable(let p): return "Notchly can't replace itself in \(p). Move it to your Applications folder, or update by hand."
        case .replaceFailed(let m):
            return "macOS didn't allow Notchly to replace itself (\(m)). You may need to allow it under Privacy & Security → App Management, or update by hand."
        }
    }
}

// MARK: - Updater

/// Checks GitHub for a newer release and installs it in place.
///
/// Install = download the zip → verify its SHA-256 → unzip → verify the new app is signed with the
/// *same* certificate as the running app (its designated requirement) → swap the bundle → relaunch.
/// The signature check is what makes this safe: only a build signed with the original private key
/// can ever be installed this way.
// `@unchecked Sendable`: published state is only changed on the main thread; background work uses copies.
final class Updater: ObservableObject, @unchecked Sendable {
    static let shared = Updater()

    static let owner = "kollkilian-arch"
    static let repo = "Notchly"

    enum Phase: Equatable {
        case idle
        case checking
        case downloading(Double)     // 0...1
        case installing
    }

    enum Status: Equatable {
        case none
        case upToDate
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// A release newer than the running version, if one was found.
    @Published private(set) var available: AppRelease?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var status: Status = .none

    private var timer: Timer?

    private init() {
        let stamp = UserDefaults.standard.double(forKey: Pref.lastUpdateCheck)
        if stamp > 0 { lastChecked = Date(timeIntervalSince1970: stamp) }
    }

    // MARK: Configuration

    /// Tests point this at a local server; the shipped app only talks to GitHub over HTTPS.
    private static var feedOverride: String? { ProcessInfo.processInfo.environment["NOTCHLY_UPDATE_FEED"] }
    static var allowInsecure: Bool { feedOverride != nil }

    static var feedURL: URL {
        if let override = feedOverride, let url = URL(string: override) { return url }
        return URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: Automatic checks

    /// Checks shortly after launch and then at most once a day while running (if enabled in Settings).
    func startAutomaticChecks() {
        // In test mode (NOTCHLY_UPDATE_FEED set) check right away instead of after 15 seconds.
        DispatchQueue.main.asyncAfter(deadline: .now() + (Self.allowInsecure ? 1 : 15)) { [weak self] in self?.checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
    }

    private func checkIfDue() {
        guard Pref.bool(Pref.autoCheckUpdates) else { return }
        if let last = lastChecked, Date().timeIntervalSince(last) < 24 * 3600 { return }
        checkForUpdates(userInitiated: false)
    }

    // MARK: Checking

    /// - Parameter userInitiated: when true, problems are shown in the UI; automatic checks stay quiet.
    func checkForUpdates(userInitiated: Bool) {
        guard phase == .idle else { return }
        phase = .checking
        if userInitiated { status = .none }

        Task {
            do {
                let release = try await Self.fetchLatest(feed: Self.feedURL)
                await MainActor.run {
                    self.lastChecked = Date()
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Pref.lastUpdateCheck)
                    if Self.isNewer(release.version, than: Self.currentVersion) {
                        self.available = release
                        self.status = .none
                        // Test mode only (needs NOTCHLY_UPDATE_FEED too): install without a click.
                        if Self.allowInsecure, ProcessInfo.processInfo.environment["NOTCHLY_AUTOINSTALL"] == "1" {
                            self.phase = .idle
                            self.installAvailableUpdate()
                            return
                        }
                    } else {
                        self.available = nil
                        self.status = .upToDate
                    }
                    self.phase = .idle
                }
            } catch {
                await MainActor.run {
                    self.phase = .idle
                    if userInitiated { self.status = .failed(error.localizedDescription) }
                }
            }
        }
    }

    // MARK: Installing

    /// True if the running app can be replaced in place (its folder is writable).
    var canInstallInPlace: Bool {
        FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path)
    }

    func installAvailableUpdate() {
        guard let release = available, phase == .idle else { return }
        guard canInstallInPlace else {
            status = .failed(UpdateError.notWritable(Bundle.main.bundleURL.deletingLastPathComponent().path).localizedDescription)
            return
        }
        phase = .downloading(0)
        status = .none
        let app = Bundle.main.bundleURL

        Task {
            do {
                let staged = try await Self.stage(release: release, currentApp: app, allowInsecure: Self.allowInsecure) { fraction in
                    DispatchQueue.main.async { self.phase = .downloading(fraction) }
                }
                await MainActor.run { self.phase = .installing }
                try Self.replace(target: app, with: staged)
                await MainActor.run { Self.relaunch(app) }
            } catch {
                await MainActor.run {
                    self.phase = .idle
                    self.status = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Starts a detached helper that reopens the app once this process has exited, then quits.
    private static func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"\(app.path)\""
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try? helper.run()
        NSApp.terminate(nil)
    }

    // MARK: Feed

    static func fetchLatest(feed: URL) async throws -> AppRelease {
        var request = URLRequest(url: feed, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Notchly/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { throw UpdateError.network(error.localizedDescription) }

        guard let http = response as? HTTPURLResponse else { throw UpdateError.badResponse }
        switch http.statusCode {
        case 200: return try parseRelease(data)
        case 404: throw UpdateError.notFound
        case 403, 429: throw UpdateError.rateLimited
        default: throw UpdateError.network("HTTP \(http.statusCode)")
        }
    }

    /// Parses GitHub's "latest release" JSON.
    static func parseRelease(_ data: Data) throws -> AppRelease {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String,
              let page = (root["html_url"] as? String).flatMap(URL.init(string:)) else { throw UpdateError.badResponse }
        if root["draft"] as? Bool == true || root["prerelease"] as? Bool == true { throw UpdateError.notFound }

        let assets = (root["assets"] as? [[String: Any]] ?? []).compactMap { a -> AppRelease.Asset? in
            guard let name = a["name"] as? String,
                  let url = (a["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return nil }
            return AppRelease.Asset(name: name, url: url, size: a["size"] as? Int ?? 0)
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return AppRelease(version: version, tag: tag, pageURL: page,
                          zip: assets.first { $0.name.hasSuffix(".zip") },
                          sha256: assets.first { $0.name.hasSuffix(".zip.sha256") })
    }

    /// Numeric, component-wise comparison: "0.1.10" is newer than "0.1.9".
    static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let r = parts(remote), l = parts(local)
        guard !r.isEmpty, remote.first?.isNumber == true else { return false }
        for i in 0..<max(r.count, l.count) {
            let a = i < r.count ? r[i] : 0
            let b = i < l.count ? l[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    // MARK: Download and verification

    /// Downloads the release, verifies checksum, contents and signature, and returns the staged app.
    /// Nothing outside the temporary folder is touched.
    static func stage(release: AppRelease, currentApp: URL, allowInsecure: Bool,
                      progress: @escaping (Double) -> Void) async throws -> URL {
        guard let zip = release.zip, let shaAsset = release.sha256 else { throw UpdateError.noInstallableAsset }
        for asset in [zip, shaAsset] { try validate(asset.url, allowInsecure: allowInsecure) }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("Notchly-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        do {
            // 1. the published checksum
            var shaRequest = URLRequest(url: shaAsset.url, timeoutInterval: 20)
            shaRequest.setValue("Notchly/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (shaData, shaResponse) = try await URLSession.shared.data(for: shaRequest)
            guard (shaResponse as? HTTPURLResponse)?.statusCode == 200,
                  let expected = String(decoding: shaData, as: UTF8.self).split(whereSeparator: \.isWhitespace).first.map(String.init),
                  expected.count == 64 else { throw UpdateError.checksumMismatch }

            // 2. the zip, hashed while it streams in
            let zipURL = work.appendingPathComponent("Notchly.zip")
            let actual = try await download(zip.url, to: zipURL, progress: progress)
            guard actual.lowercased() == expected.lowercased() else { throw UpdateError.checksumMismatch }

            // 3. unzip: exactly one item, Notchly.app
            let unzipped = work.appendingPathComponent("unzipped")
            try FileManager.default.createDirectory(at: unzipped, withIntermediateDirectories: true)
            guard try run("/usr/bin/ditto", ["-x", "-k", zipURL.path, unzipped.path]) == 0 else { throw UpdateError.badArchive }
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: unzipped.path)) ?? []
            guard contents == ["Notchly.app"] else { throw UpdateError.badArchive }
            let newApp = unzipped.appendingPathComponent("Notchly.app")

            // 4. is it really Notchly, at the advertised version?
            let current = Bundle(url: currentApp)?.infoDictionary ?? [:]
            let incoming = Bundle(url: newApp)?.infoDictionary ?? [:]
            guard let id = incoming["CFBundleIdentifier"] as? String, id == current["CFBundleIdentifier"] as? String else {
                throw UpdateError.wrongApp("different bundle identifier")
            }
            guard incoming["CFBundleShortVersionString"] as? String == release.version else {
                throw UpdateError.wrongApp("version doesn't match the release")
            }

            // 5. signed by the same developer as the running app?
            guard try satisfiesDesignatedRequirement(of: currentApp, by: newApp) else { throw UpdateError.signatureMismatch }
            return newApp
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    private static func validate(_ url: URL, allowInsecure: Bool) throws {
        if allowInsecure { return }
        let prefix = "https://github.com/\(owner)/\(repo)/releases/download/"
        guard url.absoluteString.hasPrefix(prefix) else { throw UpdateError.insecureURL(url.host ?? url.absoluteString) }
    }

    /// Streams a file to disk and returns its SHA-256 (hex).
    private static func download(_ url: URL, to destination: URL, progress: @escaping (Double) -> Void) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("Notchly/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.network("download failed") }
        let total = Double(response.expectedContentLength)

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var hasher = SHA256()
        var buffer = Data()
        var received = 0.0
        var lastReported = 0.0
        func flush() throws {
            guard !buffer.isEmpty else { return }
            try handle.write(contentsOf: buffer)
            hasher.update(data: buffer)
            received += Double(buffer.count)
            buffer.removeAll(keepingCapacity: true)
            if total > 0, received / total - lastReported >= 0.02 {
                lastReported = received / total
                progress(min(lastReported, 1))
            }
        }
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 65_536 { try flush() }
        }
        try flush()
        progress(1)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Does `candidate` satisfy the designated requirement of `reference`? For a build signed with a
    /// certificate, that means "same identifier and same signing certificate".
    static func satisfiesDesignatedRequirement(of reference: URL, by candidate: URL) throws -> Bool {
        var referenceCode: SecStaticCode?
        var candidateCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(reference as CFURL, [], &referenceCode) == errSecSuccess, let referenceCode,
              SecStaticCodeCreateWithPath(candidate as CFURL, [], &candidateCode) == errSecSuccess, let candidateCode else {
            throw UpdateError.signatureMismatch
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(referenceCode, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError.signatureMismatch
        }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        return SecStaticCodeCheckValidity(candidateCode, flags, requirement) == errSecSuccess
    }

    // MARK: Replacing the app

    /// Swaps `target` for `staged`, keeping the old copy until the new one is in place.
    static func replace(target: URL, with staged: URL) throws {
        let fm = FileManager.default
        let folder = target.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: folder.path) else { throw UpdateError.notWritable(folder.path) }

        let backup = folder.appendingPathComponent(".Notchly-previous-\(UUID().uuidString)")
        do { try fm.moveItem(at: target, to: backup) }
        catch { throw UpdateError.replaceFailed(error.localizedDescription) }

        // ditto copies the bundle exactly (signature, permissions, symlinks).
        let status = (try? run("/usr/bin/ditto", [staged.path, target.path])) ?? -1
        if status != 0 {
            try? fm.removeItem(at: target)
            try? fm.moveItem(at: backup, to: target)        // put the old version back
            throw UpdateError.replaceFailed("could not copy the new version")
        }
        try? fm.removeItem(at: backup)
        try? fm.removeItem(at: staged.deletingLastPathComponent().deletingLastPathComponent())   // temp folder
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: Debug hooks

    /// Shows a fixed state in the debug snapshot tool.
    func applyPreview(available: AppRelease?, phase: Phase = .idle, status: Status = .none, lastChecked: Date? = nil) {
        self.available = available
        self.phase = phase
        self.status = status
        self.lastChecked = lastChecked
    }

    /// `Notchly --test-update <app>`: runs check → download → verify → replace against the feed in
    /// NOTCHLY_UPDATE_FEED, replacing `<app>` instead of the running app. Used by the local test script.
    static func commandLineTest(target: URL) async -> Int32 {
        // Read Info.plist straight from disk: Bundle caches a bundle's info per path within a process.
        func versionOnDisk() -> String {
            let plist = NSDictionary(contentsOf: target.appendingPathComponent("Contents/Info.plist"))
            return plist?["CFBundleShortVersionString"] as? String ?? "0"
        }
        do {
            let release = try await fetchLatest(feed: feedURL)
            let installed = versionOnDisk()
            print("feed: \(release.tag) (installed: \(installed))")
            guard isNewer(release.version, than: installed) else {
                print("RESULT: up-to-date")
                return 0
            }
            let staged = try await stage(release: release, currentApp: target, allowInsecure: true) { _ in }
            try replace(target: target, with: staged)
            print("RESULT: installed \(versionOnDisk())")
            return 0
        } catch {
            print("RESULT: refused: \(error.localizedDescription)")
            return 2
        }
    }
}
