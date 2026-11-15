# Notchly

Makes use of the MacBook notch. Hover over it (or click it) and it expands into a small control
centre; while it is closed it shows live activities on both sides of the camera cut-out.
A native SwiftUI/AppKit app, in the spirit of Alcove and Dynamic Island apps.

## Features

**Tabs in the expanded notch**

| Tab | What it does |
|---|---|
| **Home** | Now Playing (Spotify and Apple Music) with artwork, seek bar and controls, plus your next calendar events with a **Join** button for video calls |
| **Audio** | Choose the Mac's sound output and see reported Bluetooth device batteries, including individual earbuds and case |
| **Shelf** | Park files, links, text snippets, and pasted screenshots; preview with Space and pin favourites |
| **Timer** | Countdown with presets, pause, +1 min, chime |
| **Scores** | Live scores, results and fixtures for favourite teams (Bundesliga, Champions League, NFL, NBA) |
| **Usage** | A ring (in the tab bar) and bars showing how much of your Claude 5-hour and weekly limits you have used |

**While the notch is closed**

Shows a timer, meeting reminder, live score, music (artwork + equalizer), or charging status.
Choose and pin an activity, cycle between active ones, or let automatic priorities decide.
The lock padlock and volume/brightness HUD take priority; important timer and meeting alerts briefly
interrupt your chosen activity.

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

### Choosing live activities

Open the notch and use the **activity menu** beside the clock to select an active timer, meeting,
live score, music, or charging status. Use **Next activity** to cycle, or hold **Option** while
approaching the closed notch and click it to cycle without opening it. Selections last **20 seconds**,
then return to your pin or automatic priorities. **Pin** keeps an activity preferred across launches;
if it becomes inactive, another activity fills in until it returns. **Use Automatic Priorities** clears
the pin and any temporary selection.

Completed timers and meetings entering their last minute (and starting) get a **12-second** alert,
then return to your selection. You can choose another activity to acknowledge an alert immediately.
Automatic mode favours a meeting in the minute before and after its start over a running timer.
Otherwise, its order is finished timer, active timer, meeting reminder, live score, music, then charging.
Lock and volume/brightness indicators always take priority. Opening the notch takes you to the
activity it is showing; dragging content in still opens the Shelf.

### Audio devices

Open the **headphones tab** to choose a sound output. The active output has a checkmark; changes made
in macOS appear here too. Connecting or disconnecting an audio device, or changing the active output,
shows a six-second notice in the closed notch. Open it during that notice to go straight to Audio.
Lock, volume/brightness, and urgent timer/meeting alerts keep their priority. Connection notices can
be switched off under **Settings → HUD → Audio devices**.

Bluetooth batteries appear only when macOS reports them, with separate left, right, and case levels
where available. Missing readings stay blank. Notchly reads the local `system_profiler` Bluetooth report
in the background at most once per minute while Bluetooth audio outputs exist, and refreshes when a
new one connects. The report's battery fields are best-effort and may lag or be absent. Output selection
uses Core Audio; it doesn't change your microphone or the separate system alert output.

## Requirements

- A Mac with a notch, running macOS 14 or later (developed and tested on macOS 27 only)
- Xcode or the Xcode command line tools (Swift 5.9+)

## Install a release

If you were sent `Notchly-<version>.zip` (or download it from the repo's Releases page):

1. Optionally verify it: `shasum -a 256 -c Notchly-<version>.zip.sha256` (run next to the zip).
2. Unzip and move **Notchly.app** to `/Applications`.
3. macOS would block the first launch, because the app is signed with a local certificate and is
   **not notarized** (that needs a paid Apple Developer account). Remove the "downloaded" mark first, in
   Terminal, then open the app:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Notchly.app
   ```

   (The alternative, **System Settings → Privacy & Security → "Open Anyway"**, also works, but macOS then keeps
   running the app from a temporary read-only copy, so in-app updates can't install themselves. If you used it,
   run the command above, quit Notchly and open it again.)
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
