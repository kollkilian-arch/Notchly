import AppKit

Pref.registerDefaults()

let app = NSApplication.shared

if let i = CommandLine.arguments.firstIndex(of: "--snapshot-experimental"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { renderExperimentalSnapshots(to: CommandLine.arguments[i + 1]) }
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { renderSnapshots(to: CommandLine.arguments[i + 1]) }
    exit(0)
}

// Debug: `Notchly --test-update <path/to/Notchly.app>` (see Updater.commandLineTest)
if let i = CommandLine.arguments.firstIndex(of: "--test-update"), i + 1 < CommandLine.arguments.count {
    let target = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    Task { exit(await Updater.commandLineTest(target: target)) }
    RunLoop.main.run()
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
