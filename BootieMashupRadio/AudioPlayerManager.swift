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
    #if canImport(UIKit)
    @Published public private(set) var artworkImage: UIImage? = nil
    #endif

    private var player: AVPlayer?
    private var timeControlStatusObservation: NSKeyValueObservation?
    private var currentStreamURL: URL = AudioPlayerManager.primaryStreamURL
    private var pollingTimer: Timer?
    private var lastNowPlaying: String = ""

    /// Modern Now Playing session (iOS 16+ / tvOS 16+). Stored as AnyObject
    /// so the class itself can still target iOS 15 / tvOS 15.
    private var _nowPlayingSessionBox: AnyObject?

    private init() {
        configureAudioSession()
        setupAudioSessionObservers()
        setupRemoteCommandCenter()
    }

    // MARK: - Audio Session

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

    // MARK: - Remote Command Center

    public func setupRemoteCommandCenter() {
        // Prefer the session's command center when available; fall back to shared.
        let commandCenter: MPRemoteCommandCenter
        if #available(iOS 16.0, tvOS 16.0, *) {
            // Session is created later (once we have a player). Use shared for now;
            // we re-wire targets after the session exists.
            commandCenter = MPRemoteCommandCenter.shared()
        } else {
            commandCenter = MPRemoteCommandCenter.shared()
        }

        configureCommandCenter(commandCenter)

        #if canImport(UIKit)
        DispatchQueue.main.async {
            UIApplication.shared.beginReceivingRemoteControlEvents()
        }
        #endif
    }

    private func configureCommandCenter(_ commandCenter: MPRemoteCommandCenter) {
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
    }

    // MARK: - Playback

    public func play() {
        configureAudioSession()
        if player == nil {
            setupPlayer(with: currentStreamURL)
        }
        player?.play()
        isPlaying = true

        // Promote the session so the system (Watch, Lock Screen, Control Center)
        // treats this app as the Now Playing source.
        if #available(iOS 16.0, tvOS 16.0, *) {
            if let session = _nowPlayingSessionBox as? MPNowPlayingSession {
                session.becomeActiveIfPossible { [weak self] success in
                    if success {
                        self?.updateNowPlayingInfo()
                    }
                }
            }
        }

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
        // Tear down previous observation / session
        timeControlStatusObservation?.invalidate()
        timeControlStatusObservation = nil
        if #available(iOS 16.0, tvOS 16.0, *) {
            _nowPlayingSessionBox = nil
        }

        let item = AVPlayerItem(url: url)
        // Help the system publish basic metadata even before our manual update
        if #available(iOS 12.2, tvOS 12.2, *) {
            var metadata: [AVMetadataItem] = []
            let titleItem = AVMutableMetadataItem()
            titleItem.identifier = .commonIdentifierTitle
            titleItem.value = songName as NSString
            titleItem.extendedLanguageTag = "und"
            metadata.append(titleItem)

            let artistItem = AVMutableMetadataItem()
            artistItem.identifier = .commonIdentifierArtist
            artistItem.value = trackArtist as NSString
            artistItem.extendedLanguageTag = "und"
            metadata.append(artistItem)

            item.externalMetadata = metadata
        }

        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.isMuted = isMuted
        self.player = newPlayer

        // Create / attach modern Now Playing session (iOS 16+ / tvOS 16+)
        if #available(iOS 16.0, tvOS 16.0, *) {
            let session = MPNowPlayingSession(players: [newPlayer])
            // We publish metadata manually for full control over live-stream keys.
            self._nowPlayingSessionBox = session
            // Re-wire remote commands through the session's command center
            configureCommandCenter(session.remoteCommandCenter)
            session.becomeActiveIfPossible { _ in }
        }

        timeControlStatusObservation = newPlayer.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch player.timeControlStatus {
                case .playing:
                    if !self.isPlaying { self.isPlaying = true }
                case .paused:
                    if self.isPlaying { self.isPlaying = false }
                default:
                    break
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

    // MARK: - Metadata Polling

    public func startMetadataPolling() {
        stopMetadataPolling()
        fetchMetadata()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.fetchMetadata()
        }
        // Keep the timer firing while the app is in the background (RunLoop.common)
        if let timer = pollingTimer {
            RunLoop.main.add(timer, forMode: .common)
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
                    let nextText = !nextTrack.isEmpty ? nextTrack : ""

                    DispatchQueue.main.async {
                        self.trackTitle = displayText
                        self.trackArtist = finalArtist
                        self.songName = finalTitle
                        self.nextTrackTitle = nextText
                        self.updateNowPlayingInfo()
                        self.updatePlayerItemExternalMetadata()
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
            guard let self = self, let data = data, error == nil else { return }
            #if canImport(UIKit)
            guard let image = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                self.artworkImage = image
                self.updateNowPlayingInfo()
                self.updatePlayerItemExternalMetadata()
            }
            #endif
        }.resume()
    }

    // MARK: - Now Playing Info (Lock Screen / Control Center / Watch / CarPlay / tvOS)

    /// Keeps AVPlayerItem.externalMetadata in sync so automatic publishers
    /// (and some accessories) also receive title / artist / artwork.
    private func updatePlayerItemExternalMetadata() {
        guard let item = player?.currentItem else { return }
        if #available(iOS 12.2, tvOS 12.2, *) {
            var metadata: [AVMetadataItem] = []

            let titleItem = AVMutableMetadataItem()
            titleItem.identifier = .commonIdentifierTitle
            titleItem.value = songName as NSString
            titleItem.extendedLanguageTag = "und"
            metadata.append(titleItem)

            let artistItem = AVMutableMetadataItem()
            artistItem.identifier = .commonIdentifierArtist
            artistItem.value = trackArtist as NSString
            artistItem.extendedLanguageTag = "und"
            metadata.append(artistItem)

            let albumItem = AVMutableMetadataItem()
            albumItem.identifier = .commonIdentifierAlbumName
            albumItem.value = "Bootie Mashup Radio" as NSString
            albumItem.extendedLanguageTag = "und"
            metadata.append(albumItem)

            #if canImport(UIKit)
            if let image = artworkImage ?? UIImage(named: "background"),
               let jpeg = image.jpegData(compressionQuality: 0.85) {
                let artItem = AVMutableMetadataItem()
                artItem.identifier = .commonIdentifierArtwork
                artItem.value = jpeg as NSData
                artItem.dataType = kCMMetadataBaseDataType_JPEG as String
                artItem.extendedLanguageTag = "und"
                metadata.append(artItem)
            }
            #endif

            item.externalMetadata = metadata
        }
    }

    public func updateNowPlayingInfo() {
        // Always build the dictionary on the main thread
        var nowPlayingInfo = [String: Any]()

        nowPlayingInfo[MPMediaItemPropertyTitle] = songName
        nowPlayingInfo[MPMediaItemPropertyArtist] = trackArtist
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = "Bootie Mashup Radio"

        // Media type helps some surfaces (Watch, CarPlay) classify the content
        nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue

        // Live stream flag – shows the "LIVE" indicator and disables scrubbing
        nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = true

        // Playback rate is the primary signal for play vs pause UI
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0

        // For live radio do NOT publish a finite duration; some clients
        // mis-behave if duration is present together with IsLiveStream.
        // Elapsed time can still be supplied (starts at 0 and grows).
        if let currentTimeSeconds = player?.currentTime().seconds,
           currentTimeSeconds.isFinite, !currentTimeSeconds.isNaN {
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, currentTimeSeconds)
        } else {
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0.0
        }

        #if canImport(UIKit)
        // Prefer the live artwork; fall back to the bundled background image
        let effectiveArtworkImage = artworkImage ?? UIImage(named: "background")
        if let image = effectiveArtworkImage {
            // Provide a reasonably sized artwork. Very large images can be
            // dropped by the Watch / CarPlay pipelines.
            let maxDimension: CGFloat = 600
            let artworkImageToUse: UIImage
            if max(image.size.width, image.size.height) > maxDimension {
                let scale = maxDimension / max(image.size.width, image.size.height)
                let newSize = CGSize(width: image.size.width * scale,
                                     height: image.size.height * scale)
                let renderer = UIGraphicsImageRenderer(size: newSize)
                artworkImageToUse = renderer.image { _ in
                    image.draw(in: CGRect(origin: .zero, size: newSize))
                }
            } else {
                artworkImageToUse = image
            }

            let artwork = MPMediaItemArtwork(boundsSize: artworkImageToUse.size) { _ in
                artworkImageToUse
            }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        }
        #endif

        // Publish via the modern session when available; otherwise fall back
        // to the global default center (pre-iOS 16 / older tvOS).
        if #available(iOS 16.0, tvOS 16.0, *) {
            if let session = _nowPlayingSessionBox as? MPNowPlayingSession {
                session.nowPlayingInfoCenter.nowPlayingInfo = nowPlayingInfo
            }
            // Always keep the global centre in sync – Watch / Lock Screen /
            // Control Center / CarPlay still read it on many OS versions.
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        } else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        }

        // On macOS Catalyst / some older paths the explicit playbackState helps
        #if targetEnvironment(macCatalyst)
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        #endif
    }
}
