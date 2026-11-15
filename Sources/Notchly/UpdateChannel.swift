import Foundation

enum UpdateChannel: String, CaseIterable {
    case stable, experimental

    static var current: UpdateChannel {
        if let name = Bundle.main.object(forInfoDictionaryKey: "NotchlyUpdateChannel") as? String,
           let channel = UpdateChannel(rawValue: name) { return channel }
        return Updater.currentVersion.contains("-experimental.") ? .experimental : .stable
    }

    static var selected: UpdateChannel {
        Pref.bool(Pref.useExperimentalBranch) ? .experimental : .stable
    }

    func accepts(tag: String, prerelease: Bool) -> Bool {
        switch self {
        case .stable: return !prerelease && !tag.contains("-experimental.")
        case .experimental: return prerelease && tag.contains("-experimental.")
        }
    }
}

