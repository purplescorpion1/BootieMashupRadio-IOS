import SwiftUI
import AVKit

struct AirPlayView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.activeTintColor = .systemBlue
        picker.tintColor = .white
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct ContentView: View {
    @StateObject private var audioManager = AudioPlayerManager.shared

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // App Background Image
                Image("background")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .ignoresSafeArea()

                // Semitransparent overlay (#40000000)
                Color.black.opacity(0.25)
                    .ignoresSafeArea()

                // Main Content Layout
                VStack(spacing: 0) {
                    Spacer(minLength: 20)

                    // Album Artwork Container
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
                            Image("banner320")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .padding(12)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                    }
                    .frame(width: 180, height: 180)
                    .padding(.bottom, 20)

                    // Dynamic Now Playing Text
                    Text("NOW PLAYING")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white.opacity(0.8))
                        .tracking(1.5)
                        .shadow(color: .black.opacity(0.8), radius: 3, x: 1, y: 1)
                        .padding(.bottom, 4)

                    Text(audioManager.trackTitle)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.8), radius: 4, x: 2, y: 2)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)

                    // Dynamic Next Playing Text
                    if !audioManager.nextTrackTitle.isEmpty {
                        Text("COMING NEXT")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white.opacity(0.8))
                            .tracking(1.5)
                            .shadow(color: .black.opacity(0.8), radius: 3, x: 1, y: 1)
                            .padding(.bottom, 4)

                        Text(audioManager.nextTrackTitle)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .shadow(color: .black.opacity(0.8), radius: 4, x: 2, y: 2)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 24)
                    }

                    Spacer(minLength: 20)

                    // Control Buttons Container
                    HStack(spacing: 32) {
                        // Mute/Unmute Button
                        Button(action: {
                            audioManager.toggleMute()
                        }) {
                            Image(systemName: audioManager.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 48, height: 48)
                        }
                        .accessibilityLabel(audioManager.isMuted ? "Unmute Audio" : "Mute Audio")

                        // Play/Pause Button
                        Button(action: {
                            audioManager.togglePlayPause()
                        }) {
                            Image(systemName: audioManager.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 32, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 64, height: 64)
                        }
                        .accessibilityLabel(audioManager.isPlaying ? "Pause" : "Play")

                        // AirPlay / Remote Route Button
                        AirPlayView()
                            .frame(width: 48, height: 48)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .padding(.bottom, 24)
                }
            }
        }
        .onAppear {
            audioManager.startMetadataPolling()
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
