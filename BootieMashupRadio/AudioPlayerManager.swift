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
    @Published public private(set) var trackArtist: String = "Bootie Mashup Radio"
    @Published public private(set) var songName: String = "Bootie Mashup Radio"
    @Published public private(set) var nextTrackTitle: String = ""
    @Published public private(set) var artworkImage: UIImage? = nil

    private var player: AVPlayer?
    private var timeControlStatusObservation: NSKeyValueObservation?
    private var currentStreamURL: URL = AudioPlayerManager.primaryStreamURL
    private var pollingTimer: Timer?
    private var lastNowPlaying: String = ""

    private init() {
        configureAudioSession()
        setupAudioSessionObservers()
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

    private func setupAudioSessionObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        if type == .began {
            DispatchQueue.main.async {
                self.isPlaying = false
                self.updateNowPlayingInfo()
            }
        } else if type == .ended {
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    DispatchQueue.main.async {
                        self.play()
                    }
                }
            }
        }
    }

    @objc private func handleRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        if reason == .oldDeviceUnavailable {
            DispatchQueue.main.async {
                self.pause()
            }
        }
    }

    public func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // Disable unsupported commands for live radio streaming
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.nextTrackCommand.removeTarget(nil)

        commandCenter.previousTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.removeTarget(nil)

        commandCenter.changePlaybackPositionCommand.isEnabled = false
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)

        commandCenter.seekForwardCommand.isEnabled = false
        commandCenter.seekForwardCommand.removeTarget(nil)

        commandCenter.seekBackwardCommand.isEnabled = false
        commandCenter.seekBackwardCommand.removeTarget(nil)

        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipForwardCommand.removeTarget(nil)

        commandCenter.skipBackwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.removeTarget(nil)

        // Enable supported commands
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }

        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }

        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }

        commandCenter.stopCommand.removeTarget(nil)
        commandCenter.stopCommand.isEnabled = true
        commandCenter.stopCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }

        #if canImport(UIKit)
        DispatchQueue.main.async {
            UIApplication.shared.beginReceivingRemoteControlEvents()
        }
        #endif
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
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.isMuted = isMuted
        self.player = newPlayer

        timeControlStatusObservation?.invalidate()
        timeControlStatusObservation = newPlayer.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if player.timeControlStatus == .playing {
                    if !self.isPlaying {
                        self.isPlaying = true
                    }
                } else if player.timeControlStatus == .paused {
                    if self.isPlaying {
                        self.isPlaying = false
                    }
                }
                self.updateNowPlayingInfo()
            }
        }

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

                    let finalArtist = !artist.isEmpty ? artist : "Bootie Mashup Radio"
                    let finalTitle = !title.isEmpty ? title : (displayText.isEmpty ? "Bootie Mashup Radio" : displayText)
                    let nextText = !nextTrack.isEmpty ? nextTrack : "Bootie Mashup Radio"

                    DispatchQueue.main.async {
                        self.trackTitle = displayText
                        self.trackArtist = finalArtist
                        self.songName = finalTitle
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

        nowPlayingInfo[MPMediaItemPropertyTitle] = songName
        nowPlayingInfo[MPMediaItemPropertyArtist] = trackArtist
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = "Bootie Mashup Radio"

        let effectiveArtworkImage = artworkImage ?? UIImage(named: "background")
        if let image = effectiveArtworkImage {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        }

        nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = true
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        if let currentTimeSeconds = player?.currentTime().seconds, currentTimeSeconds.isFinite, !currentTimeSeconds.isNaN {
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTimeSeconds
        } else {
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0.0
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
}
