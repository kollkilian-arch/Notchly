import Foundation
import Security

struct LimitWindow: Equatable {
    var percent: Double          // 0...100
    var resetsAt: Date?
}

struct LimitUsage: Equatable {
    var fiveHour: LimitWindow?
    var sevenDay: LimitWindow?
    var plan: String?
    var fetched: Date
}

struct LocalUsage: Equatable {
    var last5h: Int              // tokens
    var last7d: Int
}

enum UsageState: Equatable {
    case idle
    case loading
    /// Real plan limits from Anthropic.
    case limits(LimitUsage)
    /// Fallback: token counts from local Claude Code logs, with the reason limits aren't available.
    case local(LocalUsage, note: String)
}

/// Fetches how much of your Claude plan limits you've used.
///
/// Uses the sign-in that Claude Code keeps in the macOS Keychain, read-only: the token is held in
/// memory for one request, never logged or stored, and never refreshed here (refreshing would rotate
/// the refresh token and could sign Claude Code out). If the sign-in is missing or expired, it falls
/// back to counting tokens in `~/.claude/projects`.
final class UsageMonitor: ObservableObject {
    @Published private(set) var state: UsageState = .idle
    /// Hour-by-hour Claude Code activity over the last seven days (nil until first loaded).
    @Published private(set) var heatmap: UsageHeatmap?

    private var lastFetch: Date?
    private var inFlight = false
    private var heatmapFetched: Date?
    private var heatmapInFlight = false
    private let isPreview: Bool

    init() { isPreview = false }

    /// For the debug snapshot tool: shows a fixed state and never touches the network or Keychain.
    init(preview: UsageState, heatmap: UsageHeatmap? = nil) {
        state = preview
        self.heatmap = heatmap
        isPreview = true
    }

    /// How much of the 5-hour limit is used (0...100), when real limits are available.
    var fiveHourPercent: Double? {
        if case .limits(let limits) = state { return limits.fiveHour?.percent }
        return nil
    }

    /// - Parameter minInterval: skip the request if the last one was more recent than this (seconds).
    func refresh(force: Bool = false, minInterval: TimeInterval = 90) {
        guard !isPreview, !inFlight else { return }
        if !force, let last = lastFetch, Date().timeIntervalSince(last) < minInterval { return }
        inFlight = true
        if case .idle = state { state = .loading }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.load()
            DispatchQueue.main.async {
                self?.inFlight = false
                self?.lastFetch = Date()
                self?.state = result
            }
        }
    }

    /// Rebuilds the heatmap from the local logs, off the main thread. Only worth doing while the Usage
    /// tab is showing; at most once per `minInterval` unless forced.
    func refreshHeatmap(force: Bool = false, minInterval: TimeInterval = 300) {
        guard !isPreview, !heatmapInFlight else { return }
        if !force, let last = heatmapFetched, Date().timeIntervalSince(last) < minInterval { return }
        heatmapInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let now = Date()
            let start = UsageHeatmap.windowStart(now: now)
            let map = UsageHeatmap.build(events: Self.readLocalEvents(since: start), start: start, now: now)
            DispatchQueue.main.async {
                self?.heatmapInFlight = false
                self?.heatmapFetched = Date()
                self?.heatmap = map
            }
        }
    }

    // MARK: Loading

    private struct Note: Error { let text: String }
    private struct Credentials { let token: String; let plan: String? }

    private static func load() -> UsageState {
        do {
            let creds = try readCredentials()
            return .limits(try fetchLimits(creds))
        } catch let note as Note {
            return .local(scanLocalLogs(), note: note.text)
        } catch {
            return .local(scanLocalLogs(), note: "Couldn't load limits")
        }
    }

    private static let keychainService = "Claude Code-credentials"

    /// Reads the sign-in through Apple's `security` tool, which is already trusted by the item
    /// (that is how Claude Code itself reads it). Unlike a direct Keychain read, this never shows a
    /// password prompt, and it keeps working when Notchly is rebuilt: macOS remembers "Always Allow"
    /// per exact build of an app, so every rebuild of Notchly would be asked again.
    private static func readViaSecurityTool() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()   // read before waiting: avoids a full-pipe deadlock
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : Data(trimmed.utf8)
    }

    /// Fallback: ask the Keychain directly (may show the system's access prompt).
    private static func readViaKeychain() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: break
        case errSecItemNotFound: throw Note(text: "Not signed in to Claude Code")
        default: throw Note(text: "Keychain access was not allowed")
        }
        guard let data = item as? Data else { throw Note(text: "Unrecognised Claude Code sign-in") }
        return data
    }

    private static func readCredentials() throws -> Credentials {
        let data = try readViaSecurityTool() ?? readViaKeychain()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            throw Note(text: "Unrecognised Claude Code sign-in")
        }
        let expiresMs = (oauth["expiresAt"] as? NSNumber)?.doubleValue ?? 0
        if expiresMs / 1000 < Date().timeIntervalSince1970 + 15 {
            throw Note(text: "Claude sign-in expired. Run “claude” once to refresh it.")
        }
        return Credentials(token: token, plan: oauth["subscriptionType"] as? String)
    }

    private static func fetchLimits(_ creds: Credentials) throws -> LimitUsage {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 15)
        request.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Notchly", forHTTPHeaderField: "User-Agent")

        var body: Data?
        var status = 0
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            body = data
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            done.signal()
        }.resume()
        done.wait()

        switch status {
        case 200:
            guard let body, var usage = parseLimits(body) else { throw Note(text: "Unexpected response from Anthropic") }
            usage.plan = creds.plan
            return usage
        case 401, 403:
            throw Note(text: "Claude sign-in expired. Run “claude” once to refresh it.")
        case 0:
            throw Note(text: "Can't reach Anthropic")
        default:
            throw Note(text: "Anthropic returned \(status)")
        }
    }

    /// Parses `{"five_hour": {"utilization": 37.0, "resets_at": "..."}, "seven_day": {...}}`.
    static func parseLimits(_ data: Data) -> LimitUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        func window(_ key: String) -> LimitWindow? {
            guard let w = root[key] as? [String: Any],
                  let pct = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return LimitWindow(percent: pct, resetsAt: (w["resets_at"] as? String).flatMap(parseDate))
        }
        let five = window("five_hour"), seven = window("seven_day")
        guard five != nil || seven != nil else { return nil }
        return LimitUsage(fiveHour: five, sevenDay: seven, plan: nil, fetched: Date())
    }

    // MARK: Local fallback

    /// Every assistant message since `since`, with input + output + cache-creation tokens.
    /// (Cache reads are excluded: they would hugely inflate the number.)
    static func readLocalEvents(since: Date) -> [UsageEvent] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let files = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var seen = Set<String>()
        var events: [UsageEvent] = []
        let needle = Array("\"usage\"".utf8)

        /// One log line that mentions usage: keep it if it is a message with a timestamp after `since`.
        func consume(_ line: Data) {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let stamp = obj["timestamp"] as? String,
                  let date = parseDate(stamp), date > since else { return }

            // A message is logged once per content block with identical usage; count it once.
            let key = "\(message["id"] as? String ?? "")|\(obj["requestId"] as? String ?? "")"
            if key != "|", !seen.insert(key).inserted { return }

            func n(_ k: String) -> Int { (usage[k] as? NSNumber)?.intValue ?? 0 }
            events.append(UsageEvent(date: date,
                                     tokens: n("input_tokens") + n("output_tokens") + n("cache_creation_input_tokens")))
        }

        for case let url as URL in files where url.pathExtension == "jsonl" {
            guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  modified > since,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }

            // Logs run to tens of megabytes, almost all of it tool output. Walk the raw bytes and only
            // decode the few lines that mention usage (a String per file and line would take seconds).
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                var lineStart = 0
                while lineStart < raw.count {
                    let lineEnd = memchr(base + lineStart, 0x0A, raw.count - lineStart)
                        .map { base.distance(to: UnsafeRawPointer($0)) } ?? raw.count
                    let length = lineEnd - lineStart
                    if length > needle.count, memmem(base + lineStart, length, needle, needle.count) != nil {
                        consume(Data(bytes: base + lineStart, count: length))
                    }
                    lineStart = lineEnd + 1
                }
            }
        }
        return events
    }

    /// Token totals for the last 5 hours and 7 days.
    static func scanLocalLogs() -> LocalUsage {
        let now = Date()
        return totals(of: readLocalEvents(since: now.addingTimeInterval(-7 * 86400)), now: now)
    }

    static func totals(of events: [UsageEvent], now: Date) -> LocalUsage {
        let from5h = now.addingTimeInterval(-5 * 3600), from7d = now.addingTimeInterval(-7 * 86400)
        var t5 = 0, t7 = 0
        for event in events where event.date > from7d {
            t7 += event.tokens
            if event.date > from5h { t5 += event.tokens }
        }
        return LocalUsage(last5h: t5, last7d: t7)
    }

    // Creating a formatter is expensive; one log read parses hundreds of timestamps.
    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    private static func parseDate(_ s: String) -> Date? {
        if let d = isoWithFraction.date(from: s) { return d }
        if let d = isoPlain.date(from: s) { return d }
        // e.g. 6-digit fractions: drop the fraction and retry
        let stripped = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return isoPlain.date(from: stripped)
    }
}
