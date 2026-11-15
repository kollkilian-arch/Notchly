# Notchly

Makes use of the MacBook notch. Hover over it (or click it) and it expands into a small control
centre; while it is closed it shows live activities on both sides of the camera cut-out.
A native SwiftUI/AppKit app, in the spirit of Alcove and Dynamic Island apps.

## Features

**Tabs in the expanded notch**

| Tab | What it does |
|---|---|
| **Home** | Now Playing (Spotify and Apple Music) with artwork, seek bar and controls, plus your next calendar events with a **Join** button for video calls |
| **Shelf** | Park files, links, text snippets, and pasted screenshots; preview with Space and pin favourites |
| **Timer** | Countdown with presets, pause, +1 min, chime |
| **Scores** | Live scores, results and fixtures for favourite teams (Bundesliga, Champions League, NFL, NBA) |
| **Usage** | A ring (in the tab bar) and bars showing how much of your Claude 5-hour and weekly limits you have used |

**While the notch is closed** (highest priority first)

lock padlock · volume/brightness HUD · running timer · meeting reminder · live score · music (artwork + equalizer) · charging

**Also:** replaces the macOS volume/brightness overlay, tints the progress bar with the album colours,
trackpad haptics and subtle sounds, a padlock on the lock screen, and a settings window (gear icon in
the notch, or the menu bar item).

### Using the Shelf

Drag files, web links, text, or images toward the notch to open the Shelf. Use **Paste** or **⌘V**
in the Shelf to add clipboard content, including screenshots copied with **⌃⇧⌘4**.
Click an item to select it, use **← / →** to move between items, and press **Space** to preview.
Press **Space** or **Esc** in the preview window to close it. Double-click an item (or press **Return**)
to open it. **⌘C** copies the selected item; dragging it out carries its file, link, or text.

Right-click an item for **Pin to Front / Unpin**, Preview, Copy, and Remove. Pinned items stay before
other items across launches. Original files remain references; pasted images and text previews are
saved locally in `~/Library/Application Support/Notchly/shelf.assets/`. Removing a Shelf item never
deletes an original file.

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

## Updates

Notchly checks this repository's GitHub releases about once a day (switch it off, or check by hand, under
**Settings → About**, or use *Check for Updates…* in the menu bar item). When a newer release exists, the gear in
the notch gets an orange dot and the menu bar icon changes; **Install and Restart** then:

1. downloads the release zip and verifies its SHA-256 against the published `.sha256` file,
2. checks the new app has the same bundle identifier and is **signed by the same certificate** as the running
   one (anything else is refused, so only a build made with the original signing key can be installed),
3. swaps itself in and restarts. Your permissions are kept, because the signature is the same.

Requirements: the repository must be **public** (GitHub hides a private repo's releases from the app), and
Notchly must sit somewhere it may write to, such as `/Applications`. If macOS blocks the swap (App Management),
or the app is somewhere read-only, use *Release Notes* to download the update and replace the app by hand.
Versions released before this feature (0.1.2 and earlier) cannot update themselves; install the first version
that has it by hand once.

## Making a release (for the maintainer)

**Automatic (GitHub Actions).** Bump `CFBundleShortVersionString` in `Resources/Info.plist`, commit, then:

```bash
git tag v0.2.0 && git push origin main v0.2.0
```

The *Release* workflow builds the app on GitHub, signs it, checks that the tag matches the plist version, and
publishes a release with `Notchly-<version>.zip` and its checksum attached. To release a tag that already exists
(for example `v0.1.0`), run the workflow manually: *Actions → Release → Run workflow* and enter the tag.

**One-time setup for stable signing.** The workflow signs with a dedicated release certificate stored as two
repository secrets, so every release carries the same signature and users keep their permission approvals.

```bash
./setup-ci-signing.sh   # writes two files to ~/Notchly-release-signing (outside the repo)
```

Add their contents as repository secrets named `RELEASE_CERT_P12_BASE64` and `RELEASE_CERT_PASSWORD`
(*Settings → Secrets and variables → Actions*), then delete that folder. Without the secrets the workflow still
works, but falls back to an ad-hoc signature and says so in its log and in the release notes.

**Manual alternative.** `./setup-signing.sh` once, then `./release.sh` builds, signs (with your local identity)
and writes `dist/Notchly-<version>.zip` plus a `.sha256`; attach those to a release yourself. `release.sh`
refuses an ad-hoc signature unless you set `ALLOW_ADHOC=1`. `dist/` is git-ignored on purpose.

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
release.sh           build, sign and package a release zip
setup-ci-signing.sh  one-time release certificate for the GitHub workflow
.github/workflows/   the release workflow
Sources/Notchly/Updater.swift   update check + self-update
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
