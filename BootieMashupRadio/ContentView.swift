import SwiftUI
import AVKit
#if canImport(UIKit)
import UIKit
#endif

/// Audio-only AirPlay picker. `prioritizesVideoDevices = false` plus
/// `AVPlayer.allowsExternalPlayback = false` keeps AirPlay on the audio route
/// so Now Playing stays on the iPhone (and therefore on Apple Watch).
struct AirPlayView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.activeTintColor = .systemBlue
        picker.tintColor = .white
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct ContentView: View {
    @StateObject private var audioManager = AudioPlayerManager.shared

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Image("background")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .ignoresSafeArea()

                Color.black.opacity(0.25)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer(minLength: 12)

                    ZStack {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.black)
                            .shadow(color: Color.black.opacity(0.5), radius: 8, x: 0, y: 4)

                        if let artwork = audioManager.artworkImage {
                            Image(uiImage: artwork)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        } else {
                            Image(systemName: "radio")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .foregroundColor(.white.opacity(0.6))
                                .padding(32)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                    }
                    .frame(
                        width: min(geometry.size.width * 0.45, 180),
                        height: min(geometry.size.width * 0.45, 180)
                    )
                    .padding(.bottom, 12)

                    Text("NOW PLAYING")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white.opacity(0.8))
                        .tracking(1.5)
                        .shadow(color: .black.opacity(0.8), radius: 3, x: 1, y: 1)
                        .padding(.bottom, 2)

                    Text(audioManager.trackTitle)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.8), radius: 4, x: 2, y: 2)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)

                    if !audioManager.nextTrackTitle.isEmpty {
                        Text("COMING NEXT")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white.opacity(0.8))
                            .tracking(1.5)
                            .shadow(color: .black.opacity(0.8), radius: 3, x: 1, y: 1)
                            .padding(.bottom, 2)

                        Text(audioManager.nextTrackTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .shadow(color: .black.opacity(0.8), radius: 4, x: 2, y: 2)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 12)
                    }

                    Spacer(minLength: 12)

                    HStack(spacing: 32) {
                        Button(action: { audioManager.toggleMute() }) {
                            Image(systemName: audioManager.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 48, height: 48)
                        }
                        .accessibilityLabel(audioManager.isMuted ? "Unmute Audio" : "Mute Audio")

                        Button(action: { audioManager.togglePlayPause() }) {
                            Image(systemName: audioManager.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 32, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 64, height: 64)
                        }
                        .accessibilityLabel(audioManager.isPlaying ? "Pause" : "Play")

                        AirPlayView()
                            .frame(width: 48, height: 48)
                            .accessibilityLabel("AirPlay")
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)

                    Spacer(minLength: 12)
                }
            }
        }
        .onAppear {
            #if canImport(UIKit)
            UIApplication.shared.beginReceivingRemoteControlEvents()
            #endif
            audioManager.play()
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
