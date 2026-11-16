import SwiftUI

struct ExperimentalPlayer: View {
    @ObservedObject var media: MediaMonitor
    @ObservedObject private var spotify = SpotifyLibrary.shared
    @AppStorage(Pref.tintFromArtwork) private var tintFromArtwork = true

    var body: some View {
        if let track = media.track {
            VStack(spacing: 6) {
                HStack(spacing: 12) {
                    ArtworkView(image: media.artwork, size: 48, radius: 8)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(track.artist).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                ProgressRow(position: media.position, duration: track.duration,
                            tint: media.tint(artworkColors: tintFromArtwork), onSeek: media.seek(to:))
                HStack(spacing: 0) {
                    if track.source == .spotify {
                        Button {
                            if !spotify.connected { SettingsWindowController.shared.show(tab: .home) }
                            else { spotify.toggleCurrentTrack() }
                        } label: {
                            Group {
                                if spotify.trackState == .checking || spotify.trackState == .saving || spotify.trackState == .removing {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: spotify.trackState == .saved ? "checkmark.circle.fill" : "plus.circle")
                                        .foregroundStyle(spotify.trackState == .saved ? Color.green : .white.opacity(0.8))
                                }
                            }
                            .frame(width: 32, height: 32)
                        }
                        .disabled(spotify.trackState == .unavailable || spotify.trackState == .checking || spotify.trackState == .saving || spotify.trackState == .removing)
                        .help(spotifyHelp)
                        .accessibilityLabel(spotifyHelp)
                    } else {
                        Button(action: media.toggleShuffle) {
                            Image(systemName: "shuffle").frame(width: 32, height: 32)
                                .foregroundStyle(media.isShuffling ? Color.accentColor : .white.opacity(0.65))
                        }
                        .disabled(!media.canShuffle)
                        .help("Shuffle")
                        .accessibilityLabel("Shuffle")
                        .accessibilityValue(media.isShuffling ? "On" : "Off")
                    }
                    Spacer(minLength: 6)
                    Button(action: media.previous) { Image(systemName: "backward.fill").frame(width: 32, height: 32) }
                        .help("Previous track").accessibilityLabel("Previous track")
                    Spacer(minLength: 6)
                    Button(action: media.togglePlayPause) {
                        Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18)).frame(width: 36, height: 32)
                    }
                    .help(media.isPlaying ? "Pause" : "Play").accessibilityLabel(media.isPlaying ? "Pause" : "Play")
                    Spacer(minLength: 6)
                    Button(action: media.next) { Image(systemName: "forward.fill").frame(width: 32, height: 32) }
                        .help("Next track").accessibilityLabel("Next track")
                    Spacer(minLength: 6)
                    if track.source == .music {
                        MusicAirPlayButton()
                    } else {
                        Button {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
                        } label: {
                            Image(systemName: "airplay.audio").frame(width: 32, height: 32)
                        }
                        .help("Choose an AirPlay output in macOS Sound Settings")
                        .accessibilityLabel("Open macOS Sound Settings for AirPlay")
                    }
                }
                .font(.system(size: 13))
                .buttonStyle(IconButtonStyle())
            }
        } else { NowPlayingView(media: media) }
    }

    private var spotifyHelp: String {
        switch spotify.trackState {
        case .unavailable: return "This Spotify item can't be added to Liked Songs"
        case .signedOut: return "Connect Spotify in Settings to save songs"
        case .checking: return "Checking Liked Songs"
        case .unsaved: return "Add to Liked Songs"
        case .saved: return "Remove from Liked Songs"
        case .saving: return "Adding to Liked Songs"
        case .removing: return "Removing from Liked Songs"
        case .failed: return (spotify.message ?? "Couldn't update Liked Songs.") + " Click to check again."
        }
    }
}
