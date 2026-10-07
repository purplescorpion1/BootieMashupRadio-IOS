import Foundation
import AVFoundation
import MediaPlayer
import Combine
import CoreMedia
#if canImport(UIKit)
import UIKit
#endif

/// Live Icecast player.
///
/// The stream itself has **no ICY / timed metadata and no artwork**.
/// All Lock Screen / Control Center / Dynamic Island / CarPlay / AirPlay /
/// Apple Watch Now Playing data is injected by `StreamMetadataHook` from the
/// RadioBoss JSON + artwork endpoints — never from the audio bytes.
public final class AudioPlayerManager: ObservableObject {
    public static let shared = AudioPlayerManager()

    public static let primaryStreamURL = URL(string: "https://c7.radioboss.fm/stream/205")!
    public static let fallbackStreamURL = URL(string: "https://c7.radioboss.fm:8205/stream")!
    public static let nowPlayingAPIURL = URL(string: "https://c7.radioboss.fm/w/nowplayinginfo?u=205")!
    public static let artworkURLString = "https://c7.radioboss.fm/w/artwork/205.jpg"

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
    private var lastArtworkToken: String = ""
    private var artworkJPEG: Data?

    /// Boxed: `MPNowPlayingSession` is iOS 16+ and this project warns on unguarded availability.
    private var nowPlayingSessionBox: AnyObject?

    private let metadataHook = StreamMetadataHook()
    private init() {
        configureAudioSession()
        setupAudioSessionObservers()
        setupSharedRemoteCommandCenter()
        metadataHook.onUpdate = { [weak self] payload in
            self?.applyRadioBossPayload(payload)
        }
        metadataHook.onArtwork = { [weak self] image, jpeg in
            guard let self else { return }
            #if canImport(UIKit)
            self.artworkImage = image
            #endif
            self.artworkJPEG = jpeg
            self.publishNowPlaying()
        }    }

    // MARK: - Audio session

    public func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            print("AVAudioSession: \(error.localizedDescription)")
        }
    }

    private func setupAudioSessionObservers() {
        let center = NotificationCenter.default
        let audio = AVAudioSession.sharedInstance()
        center.addObserver(self, selector: #selector(handleInterruption), name: AVAudioSession.interruptionNotification, object: audio)
        center.addObserver(self, selector: #selector(handleRouteChange), name: AVAudioSession.routeChangeNotification, object: audio)
        center.addObserver(self, selector: #selector(handleMediaServicesReset), name: AVAudioSession.mediaServicesWereResetNotification, object: audio)
    }

    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            DispatchQueue.main.async {
                self.isPlaying = false
                self.publishNowPlaying()
            }
        case .ended:
            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                DispatchQueue.main.async { self.play() }
            }
        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        if reason == .oldDeviceUnavailable {
            DispatchQueue.main.async { self.pause() }
        }
    }

    @objc private func handleMediaServicesReset() {
        DispatchQueue.main.async {
            self.configureAudioSession()
            let url = self.currentStreamURL
            self.tearDownPlayer()
            self.setupPlayer(with: url)
            if self.isPlaying {
                self.player?.playImmediately(atRate: 1.0)
            }
            self.publishNowPlaying()
        }
    }

    // MARK: - Remote commands

    private func setupSharedRemoteCommandCenter() {
        configureCommandCenter(MPRemoteCommandCenter.shared())
        #if canImport(UIKit)
        DispatchQueue.main.async {
            UIApplication.shared.beginReceivingRemoteControlEvents()
        }
        #endif
    }

    private func configureCommandCenter(_ commandCenter: MPRemoteCommandCenter) {
        let disable: [MPRemoteCommand] = [
            commandCenter.nextTrackCommand,
            commandCenter.previousTrackCommand,
            commandCenter.changePlaybackPositionCommand,
            commandCenter.seekForwardCommand,
            commandCenter.seekBackwardCommand,
            commandCenter.skipForwardCommand,
            commandCenter.skipBackwardCommand
        ]
        for command in disable {
            command.isEnabled = false
            command.removeTarget(nil)
        }

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
        // Live radio: start immediately rather than waiting on a long buffer.
        player?.playImmediately(atRate: 1.0)
        isPlaying = true
        becomeNowPlayingApp()
        publishNowPlaying()
        metadataHook.start()
    }

    public func pause() {
        player?.pause()
        isPlaying = false
        publishNowPlaying()
    }

    public func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    public func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted
    }

    private func tearDownPlayer() {
        timeControlStatusObservation?.invalidate()
        timeControlStatusObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        nowPlayingSessionBox = nil
    }

    private func setupPlayer(with url: URL) {
        tearDownPlayer()

        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ])
        let item = AVPlayerItem(asset: asset)
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        item.preferredForwardBufferDuration = 8

        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.automaticallyWaitsToMinimizeStalling = true
        newPlayer.isMuted = isMuted
        // Audio-only AirPlay. Video external playback steals Now Playing from
        // the iPhone and leaves Watch / Lock Screen showing "Not Playing".
        newPlayer.allowsExternalPlayback = false
        self.player = newPlayer

        attachNowPlayingSession(to: newPlayer)
        publishNowPlaying()

        timeControlStatusObservation = newPlayer.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] observed, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                switch observed.timeControlStatus {
                case .playing:
                    self.isPlaying = true
                    self.becomeNowPlayingApp()
                case .paused:
                    self.isPlaying = false
                default:
                    break
                }
                self.publishNowPlaying()
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePlaybackStalled),
            name: .AVPlayerItemPlaybackStalled,
            object: item
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFailedToPlayToEnd),
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: item
        )
    }

    private func attachNowPlayingSession(to player: AVPlayer) {
        // iOS deliberately does not create an MPNowPlayingSession here.
        // The iPhone's MPNowPlayingInfoCenter is the sole iOS Now Playing
        // source. This prevents a second empty media session from taking
        // ownership of Now Playing on Apple Watch.
        #if os(tvOS)
        if #available(tvOS 16.0, *) {
            let session = MPNowPlayingSession(players: [player])
            session.automaticallyPublishesNowPlayingInfo = false
            configureCommandCenter(session.remoteCommandCenter)
            nowPlayingSessionBox = session
            session.becomeActiveIfPossible { _ in }
        }
        #else
        _ = player
        #endif
    }

    private func becomeNowPlayingApp() {
        #if os(tvOS)
        if #available(tvOS 16.0, *) {
            (nowPlayingSessionBox as? MPNowPlayingSession)?.becomeActiveIfPossible { [weak self] _ in
                self?.publishNowPlaying()
            }
        }
        #endif        #if canImport(UIKit)
        UIApplication.shared.beginReceivingRemoteControlEvents()
        #endif
    }

    @objc private func handlePlaybackStalled() {
        failover()
    }

    @objc private func handleFailedToPlayToEnd() {
        failover()
    }

    private func failover() {
        if currentStreamURL == Self.primaryStreamURL {
            currentStreamURL = Self.fallbackStreamURL
        } else {
            currentStreamURL = Self.primaryStreamURL
        }
        let shouldResume = isPlaying
        setupPlayer(with: currentStreamURL)
        if shouldResume {
            player?.playImmediately(atRate: 1.0)
            isPlaying = true
        }
        publishNowPlaying()
    }

    // MARK: - RadioBoss hook (the stream itself has none)

    public func startMetadataPolling() {
        metadataHook.start()
    }

    public func stopMetadataPolling() {
        metadataHook.stop()
    }

    public func fetchMetadata() {
        metadataHook.fetchNow()
    }

    public func fetchArtwork() {
        metadataHook.fetchArtwork(cacheBuster: String(Int(Date().timeIntervalSince1970)))
    }

    private func applyRadioBossPayload(_ json: RadioBossNowPlaying) {
        let nowPlaying = json.nowplaying.trimmed
        var artist = json.currenttrack_artist.trimmed
        var title = json.currenttrack_title.trimmed
        let nextTrack = json.nexttrack.trimmed

        if artist.isEmpty || title.isEmpty, nowPlaying.contains(" - ") {
            let parts = nowPlaying.components(separatedBy: " - ")
            if parts.count >= 2 {
                if artist.isEmpty { artist = parts[0].trimmed }
                if title.isEmpty { title = parts.dropFirst().joined(separator: " - ").trimmed }
            }
        } else if title.isEmpty {
            title = nowPlaying
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

        let finalArtist = artist.isEmpty ? "Bootie Mashup Radio" : artist
        let finalTitle = title.isEmpty ? displayText : title
        let artworkToken = json.artwork_ts.map(String.init) ?? nowPlaying

        trackTitle = displayText
        trackArtist = finalArtist
        songName = finalTitle
        nextTrackTitle = nextTrack
        publishNowPlaying()

        if artworkToken != lastArtworkToken || artworkJPEG == nil {
            lastArtworkToken = artworkToken
            metadataHook.fetchArtwork(cacheBuster: artworkToken)
        }
    }

    // MARK: - Publish hook output to Watch / Lock Screen / AirPlay

    public func updateNowPlayingInfo() {
        publishNowPlaying()
    }

    private func publishNowPlaying() {
        let info = makeNowPlayingDictionary()

        // AirPlay receivers that ignore MediaPlayer and read AVFoundation tags.
        if let item = player?.currentItem {
            item.externalMetadata = makeExternalMetadata()
            if #available(iOS 16.0, tvOS 16.0, *) {
                item.nowPlayingInfo = info
            }
        }
        #if os(tvOS)
        if #available(tvOS 16.0, *) {
            if let session = nowPlayingSessionBox as? MPNowPlayingSession {
                session.nowPlayingInfoCenter.nowPlayingInfo = info
            }
        }
        #endif

        // Watch + Lock Screen + Control Center always read the default centre
        // for a single-player iOS radio app.
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info

        if #available(iOS 13.0, *) {
            center.playbackState = isPlaying ? .playing : .paused
        }

        // Give the system one more update after the artwork/metadata has
        // reached the main thread. This is especially useful when RadioBoss
        // metadata arrives immediately after playback starts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }

            let refreshed = self.makeNowPlayingDictionary()
            let center = MPNowPlayingInfoCenter.default()

            center.nowPlayingInfo = refreshed

            if #available(iOS 13.0, *) {
                center.playbackState = self.isPlaying ? .playing : .paused
            }
        }
    }

    private func makeNowPlayingDictionary() -> [String: Any] {
        // IMPORTANT:
        // The RadioBoss API is the source of truth for the currently playing
        // programme/song. The live audio stream itself contains no ICY metadata.
        //
        // Use the actual song title as the Now Playing title. `trackTitle`
        // remains the combined "Artist - Title" string used by the app UI.
        let nowPlayingTitle = songName.isEmpty
            ? (trackTitle.isEmpty ? "Bootie Mashup Radio" : trackTitle)
            : songName

        let nowPlayingArtist = trackArtist.isEmpty
            ? "Bootie Mashup Radio"
            : trackArtist

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlayingTitle,
            MPMediaItemPropertyArtist: nowPlayingArtist,
            MPMediaItemPropertyAlbumTitle: "Bootie Mashup Radio",
            MPMediaItemPropertyAlbumArtist: "Bootie Mashup Radio",

            // This is a live radio stream. Do not advertise a fake
            // zero-second duration.
            MPNowPlayingInfoPropertyIsLiveStream: NSNumber(value: true),

            MPNowPlayingInfoPropertyMediaType:
                NSNumber(value: MPNowPlayingInfoMediaType.audio.rawValue),

            MPNowPlayingInfoPropertyPlaybackRate:
                NSNumber(value: isPlaying ? 1.0 : 0.0),

            MPNowPlayingInfoPropertyDefaultPlaybackRate:
                NSNumber(value: 1.0)
        ]

        // A live stream does not have a meaningful finite duration.
        // Supplying a fake duration of 0 can cause Watch Now Playing to
        // render an empty/black item.
        if let seconds = player?.currentTime().seconds,
           seconds.isFinite,
           !seconds.isNaN,
           seconds >= 0 {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] =
                NSNumber(value: seconds)
        }

        #if canImport(UIKit)
        if let artwork = makeArtwork() {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        #endif

        return info
    }

    private func makeExternalMetadata() -> [AVMetadataItem] {
        var timed: [AVMetadataItem] = []
        timed.append(Self.metadataItem(identifier: .commonIdentifierTitle, value: trackTitle))
        timed.append(Self.metadataItem(identifier: .commonIdentifierArtist, value: trackArtist))
        timed.append(Self.metadataItem(identifier: .commonIdentifierAlbumName, value: "Bootie Mashup Radio"))
        if let jpeg = artworkJPEG {
            let art = AVMutableMetadataItem()
            art.identifier = .commonIdentifierArtwork
            art.value = jpeg as NSData
            art.dataType = kCMMetadataBaseDataType_JPEG as String
            art.extendedLanguageTag = "und"
            timed.append(art)
        }
        return timed
    }

    #if canImport(UIKit)
    private func makeArtwork() -> MPMediaItemArtwork? {
        guard let source = artworkImage ?? UIImage(named: "background") else {
            return nil
        }

        // Keep the image small and predictable for Watch / Lock Screen.
        let canvas = CGSize(width: 600, height: 600)

        let rendered = UIGraphicsImageRenderer(size: canvas).image { _ in
            let sourceSize = source.size

            guard sourceSize.width > 0,
                  sourceSize.height > 0 else {
                return
            }

            let scale = max(
                canvas.width / sourceSize.width,
                canvas.height / sourceSize.height
            )

            let scaledSize = CGSize(
                width: sourceSize.width * scale,
                height: sourceSize.height * scale
            )

            let origin = CGPoint(
                x: (canvas.width - scaledSize.width) / 2,
                y: (canvas.height - scaledSize.height) / 2
            )

            source.draw(
                in: CGRect(
                    origin: origin,
                    size: scaledSize
                )
            )
        }

        let artworkImage: UIImage

        if let jpeg = rendered.jpegData(compressionQuality: 0.85),
           let decoded = UIImage(data: jpeg) {
            artworkImage = decoded
        } else {
            artworkImage = rendered
        }

        let frozenImage = artworkImage
        // IMPORTANT:
        // Always use the request-handler initializer. The old
        // MPMediaItemArtwork(image:) initializer is deprecated.
        return MPMediaItemArtwork(
            boundsSize: canvas
        ) { requestedSize in

            guard requestedSize.width > 0,
                  requestedSize.height > 0 else {
                return frozenImage
            }

            let requested = CGSize(
                width: min(requestedSize.width, 600),
                height: min(requestedSize.height, 600)
            )

            return UIGraphicsImageRenderer(
                size: requested
            ).image { _ in

                let scale = max(
                    requested.width / frozenImage.size.width,
                    requested.height / frozenImage.size.height
                )

                let scaledSize = CGSize(
                    width: frozenImage.size.width * scale,
                    height: frozenImage.size.height * scale
                )

                let origin = CGPoint(
                    x: (requested.width - scaledSize.width) / 2,
                    y: (requested.height - scaledSize.height) / 2
                )

                frozenImage.draw(
                    in: CGRect(
                        origin: origin,
                        size: scaledSize
                    )
                )
            }
        }
    }
    #endif

    private static func metadataItem(identifier: AVMetadataIdentifier, value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.extendedLanguageTag = "und"
        return item
    }
}

// MARK: - Stream metadata hook (RadioBoss JSON + artwork, not the audio stream)

/// Polls RadioBoss because the Icecast stream carries no tags.
final class StreamMetadataHook {
    var onUpdate: ((RadioBossNowPlaying) -> Void)?
    var onArtwork: ((UIImage?, Data) -> Void)?

    private var timer: Timer?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    func start() {
        stop()
        fetchNow()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.fetchNow()
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func fetchNow() {
        var request = URLRequest(url: AudioPlayerManager.nowPlayingAPIURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        session.dataTask(with: request) { [weak self] data, _, error in
            guard let self, let data, error == nil else { return }
            do {
                let json = try JSONDecoder().decode(RadioBossNowPlaying.self, from: data)
                DispatchQueue.main.async { self.onUpdate?(json) }
            } catch {
                print("Now playing JSON: \(error)")
            }
        }.resume()
    }

    func fetchArtwork(cacheBuster: String) {
        guard let url = URL(string: "\(AudioPlayerManager.artworkURLString)?_=\(cacheBuster)") else { return }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        session.dataTask(with: request) { [weak self] data, _, error in
            guard let self, let data, error == nil else { return }
            #if canImport(UIKit)
            guard let image = UIImage(data: data) else { return }
            DispatchQueue.main.async { self.onArtwork?(image, data) }
            #else
            DispatchQueue.main.async { self.onArtwork?(nil, data) }
            #endif
        }.resume()
    }
}

struct RadioBossNowPlaying: Decodable {
    let nowplaying: String?
    let currenttrack_artist: String?
    let currenttrack_title: String?
    let nexttrack: String?
    let artwork_ts: Int?
}

private extension Optional where Wrapped == String {
    var trimmed: String {
        self?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#if canImport(UIKit)
#else
/// Stub so the hook compiles on non-UIKit (should not happen for iOS/tvOS).
typealias UIImage = NSObject
#endif

