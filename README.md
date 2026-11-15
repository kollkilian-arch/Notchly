# Notchly

Makes use of the MacBook notch. Hover over it (or click it) and it expands into a small control
centre; while it is closed it shows live activities on both sides of the camera cut-out.
A native SwiftUI/AppKit app, in the spirit of Alcove and Dynamic Island apps.

## Features

**Tabs in the expanded notch**

| Tab | What it does |
|---|---|
| **Home** | Now Playing (Spotify and Apple Music) with artwork, seek bar and controls, plus your next calendar events with a **Join** button for video calls |
| **Shelf** | Drag files toward the notch to park them; drag them out again later |
| **Timer** | Countdown with presets, pause, +1 min, chime |
| **Scores** | Live scores, results and fixtures for favourite teams (Bundesliga, Champions League, NFL, NBA) |
| **Usage** | A ring (in the tab bar) and bars showing how much of your Claude 5-hour and weekly limits you have used |

**While the notch is closed** (highest priority first)

lock padlock · volume/brightness HUD · running timer · meeting reminder · live score · music (artwork + equalizer) · charging

**Also:** replaces the macOS volume/brightness overlay, tints the progress bar with the album colours,
trackpad haptics and subtle sounds, a padlock on the lock screen, and a settings window (gear icon in
the notch, or the menu bar item).

## Requirements

- A Mac with a notch, running macOS 14 or later (developed and tested on macOS 27 only)
- Xcode or the Xcode command line tools (Swift 5.9+)

## Install a release

If you were sent `Notchly-<version>.zip` (or download it from the repo's Releases page):

1. Optionally verify it: `shasum -a 256 -c Notchly-<version>.zip.sha256` (run next to the zip).
2. Unzip and move **Notchly.app** to `/Applications`.
3. Open it. macOS will block the first launch, because the app is signed with a local certificate and is
   **not notarized** (that needs a paid Apple Developer account). Allow it once, either way:
   - **System Settings → Privacy & Security → scroll down → "Open Anyway"** (after the blocked launch), or
   - in Terminal: `xattr -dr com.apple.quarantine /Applications/Notchly.app`, then open it again.
4. Grant the permissions it asks for (see below). Because every release is signed with the same certificate,
   macOS keeps your approvals when you update to a newer version.

Only replacing the macOS volume/brightness overlay needs the Accessibility permission; the other features
work without it (Calendar and Automation each unlock their own feature).

## Making a release (for the maintainer)

```bash
./setup-signing.sh      # once
./release.sh            # builds, signs, checks, and writes dist/Notchly-<version>.zip + .sha256
```

The version is read from `Resources/Info.plist` (`CFBundleShortVersionString`); bump it first. `release.sh`
refuses to run without the stable signing identity, because an ad-hoc signature would make every release look
like a different app to macOS. Then tag the commit (`git tag v<version> && git push origin v<version>`) and
attach the zip and checksum to a GitHub release for that tag. `dist/` is git-ignored on purpose.

## Build and run

```bash
./setup-signing.sh   # once: creates a local self-signed code-signing certificate
./build.sh           # builds build/Notchly.app
open build/Notchly.app
```

`setup-signing.sh` is optional but recommended. macOS ties permissions (Accessibility, Calendar,
Automation) to an app's signature. Without a stable certificate, `build.sh` falls back to an ad-hoc
signature that changes with every build, so macOS asks for the permissions again after each rebuild.

The app runs without a Dock icon; use the menu bar icon (capsule) or the gear in the notch for settings,
and *Launch at Login* under Settings → General.

## Permissions

Notchly asks for these as features need them; each can be skipped.

| Permission | Used for |
|---|---|
| Calendar | Up Next and the Join button / meeting reminder |
| Automation (Music, Spotify) | Now Playing and playback controls |
| Accessibility | Replacing the macOS volume/brightness overlay (intercepts those keys) |

## Things to know (unofficial interfaces)

Several features rely on interfaces that Apple or others do not document, so they may break:

- **Lock screen padlock** uses the private SkyLight framework (best-effort; the app keeps working if it fails).
- **Brightness HUD** reads the built-in display's brightness through the private DisplayServices framework.
- **Scores** come from ESPN's public score feed, which is unofficial.
- **Claude usage** reads the Claude Code sign-in from the macOS Keychain (read-only, via Apple's `security`
  tool) and calls an undocumented Anthropic endpoint. It needs a Claude Code login; if the token has expired,
  Notchly shows local token counts from `~/.claude` instead. Nothing is stored or sent anywhere else.

## Project layout

```
Sources/Notchly/     the app (one file per feature: NotchViews, MediaMonitor, TimerModel, ScoresMonitor, …)
Resources/Info.plist app metadata and permission descriptions
build.sh             build + sign into build/Notchly.app
setup-signing.sh     one-time local signing certificate
```

### Debug preview tool

`Notchly --snapshot <folder>` renders the notch and settings views to PNG files and runs the built-in
logic checks (meeting-link detection, score parsing, timer, …), then exits. Handy for checking layouts
without screen-recording permission:

```bash
mkdir -p /tmp/snap && build/Notchly.app/Contents/MacOS/Notchly --snapshot /tmp/snap
```

Set `NOTCHLY_LIVE_USAGE=1` or `NOTCHLY_LIVE_SCORES=1` to also test the real Claude-usage and score feeds.

## License

[MIT](LICENSE) © 2026 kollkilian-arch
