import Foundation
import AVFoundation
import MediaPlayer
import Combine
#if canImport(UIKit)
import UIKit
#endif

public final class AudioPlayerManager: ObservableObject {
    public static let shared = AudioPlayerManager()

    public static let primaryStreamURL = URL(string: "https://c7.radioboss.fm/stream/205")!
    public static let fallbackStreamURL = URL(string: "https://c7.radioboss.fm:8205/stream")!
    public static let defaultArtworkURL = URL(string: "https://c7.radioboss.fm/w/artwork/205.jpg")!
    public static let nowPlayingAPIURL = URL(string: "https://c7.radioboss.fm/w/nowplayinginfo?u=205")!

    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var isMuted: Bool = false
    @Published public private(set) var trackTitle: String = "Bootie Mashup Radio"
    @Published public private(set) var nextTrackTitle: String = ""
    @Published public private(set) var artworkImage: UIImage? = nil

    private var player: AVPlayer?
    private var currentStreamURL: URL = AudioPlayerManager.primaryStreamURL
    private var pollingTimer: Timer?
    private var lastNowPlaying: String = ""
    private var lastNextTrack: String = ""

    private init() {
        configureAudioSession()
        setupRemoteCommandCenter()
    }

    public func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true, options: [])
        } catch {
            print("Failed to configure AVAudioSession: \(error.localizedDescription)")
        }
    }

    public func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
    }

    public func play() {
        configureAudioSession()
        if player == nil {
            setupPlayer(with: currentStreamURL)
        }
        player?.play()
        isPlaying = true
        updateNowPlayingInfo()
        startMetadataPolling()
    }

    public func pause() {
        player?.pause()
        isPlaying = false
        updateNowPlayingInfo()
    }

    public func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    public func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted
    }

    private func setupPlayer(with url: URL) {
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        player?.isMuted = isMuted

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePlaybackStalled),
            name: .AVPlayerItemPlaybackStalled,
            object: item
        )
    }

    @objc private func handlePlaybackStalled() {
        if currentStreamURL == AudioPlayerManager.primaryStreamURL {
            switchToFallbackStream()
        } else {
            currentStreamURL = AudioPlayerManager.primaryStreamURL
            setupPlayer(with: currentStreamURL)
            if isPlaying {
                player?.play()
            }
        }
    }

    private func switchToFallbackStream() {
        currentStreamURL = AudioPlayerManager.fallbackStreamURL
        setupPlayer(with: currentStreamURL)
        if isPlaying {
            player?.play()
        }
    }

    public func startMetadataPolling() {
        stopMetadataPolling()
        fetchMetadata()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.fetchMetadata()
        }
    }

    public func stopMetadataPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    public func fetchMetadata() {
        var request = URLRequest(url: AudioPlayerManager.nowPlayingAPIURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 10.0

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self, let data = data, error == nil else { return }
            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                    let nowPlaying = (json["nowplaying"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    var artist = (json["currenttrack_artist"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    var title = (json["currenttrack_title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let nextTrack = (json["nexttrack"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    if artist.isEmpty || title.isEmpty {
                        if nowPlaying.contains(" - ") {
                            let parts = nowPlaying.components(separatedBy: " - ")
                            if parts.count >= 2 {
                                if artist.isEmpty { artist = parts[0].trimmingCharacters(in: .whitespacesAndNewlines) }
                                if title.isEmpty { title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines) }
                            }
                        } else if title.isEmpty {
                            title = nowPlaying
                        }
                    }

                    let displayText: String
                    if !nowPlaying.isEmpty {
                        displayText = nowPlaying
                    } else if !artist.isEmpty && !title.isEmpty {
                        displayText = "\(artist) - \(title)"
                    } else if !title.isEmpty {
                        displayText = title
                    } else {
                        displayText = "Bootie Mashup Radio"
                    }

                    let nextText = !nextTrack.isEmpty ? nextTrack : "Bootie Mashup Radio"

                    DispatchQueue.main.async {
                        self.trackTitle = displayText
                        self.nextTrackTitle = nextText
                        self.updateNowPlayingInfo()
                    }

                    if nowPlaying != self.lastNowPlaying || self.artworkImage == nil {
                        self.lastNowPlaying = nowPlaying
                        self.fetchArtwork()
                    }
                }
            } catch {
                print("Failed to parse nowplaying JSON: \(error)")
            }
        }.resume()
    }

    public func fetchArtwork() {
        let timestamp = Int(Date().timeIntervalSince1970)
        guard let artworkURL = URL(string: "https://c7.radioboss.fm/w/artwork/205.jpg?_=\(timestamp)") else { return }

        var request = URLRequest(url: artworkURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 10.0

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self, let data = data, error == nil, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                self.artworkImage = image
                self.updateNowPlayingInfo()
            }
        }.resume()
    }

    public func updateNowPlayingInfo() {
        var nowPlayingInfo = [String: Any]()

        nowPlayingInfo[MPMediaItemPropertyTitle] = trackTitle
        nowPlayingInfo[MPMediaItemPropertyArtist] = "Bootie Mashup Radio"
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = "Bootie Mashup Radio Live Stream"

        if let image = artworkImage {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        }

        nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = true
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
}
