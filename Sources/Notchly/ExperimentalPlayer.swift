import SwiftUI

struct ExperimentalPlayer: View {
    @ObservedObject var media: MediaMonitor
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
                    Button(action: media.toggleShuffle) {
                        Image(systemName: "shuffle").frame(width: 32, height: 32)
                            .foregroundStyle(media.isShuffling ? Color.accentColor : .white.opacity(0.65))
                    }
                    .disabled(!media.canShuffle)
                    .help(media.canShuffle ? "Turn shuffle \(media.isShuffling ? "off" : "on")" : "Shuffle is unavailable for this playback context")
                    .accessibilityLabel("Shuffle")
                    .accessibilityValue(media.isShuffling ? "On" : "Off")
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
                    AirPlayPicker().frame(width: 32, height: 32).accessibilityLabel("AirPlay speakers and TVs")
                }
                .font(.system(size: 13))
                .buttonStyle(IconButtonStyle())
            }
        } else { NowPlayingView(media: media) }
    }
}
