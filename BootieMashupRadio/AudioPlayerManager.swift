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
/// The stream carries **no ICY / timed metadata and no artwork**, so all
/// Lock Screen / Control Center / AirPlay / CarPlay / Apple Watch Now Playing
/// data is injected from the RadioBoss JSON + artwork endpoints.
///
/// Design notes (why Watch used to show a blank "Now Playing"):
/// 1. AVPlayer auto-publishes its own (empty) Now Playing info on iOS 16+.
///    Writing a second, conflicting `AVPlayerItem.nowPlayingInfo` as well as
///    `MPNowPlayingInfoCenter` made the two fight. We now use ONE path:
///    `MPNowPlayingInfoCenter.default()` for iOS, `externalMetadata` for AirPlay.
/// 2. Info was published before the player was actually playing, with a
///    rate of 0, so the system treated the app as not playing. We now publish
///    from the real `timeControlStatus`.
/// 3. Artwork was fetched but a failed/non-image response silently left no art.
/// 4. A brief stall swapped streams and leaked notification observers.
public final class AudioPlayerManager: ObservableObject {
    public static let shared = AudioPlayerManager()

    public static let primaryStreamURL = URL(string: "https://c7.radioboss.fm/stream/205")!
    public static let fallbackStreamURL = URL(string: "https://c7.radioboss.fm:8205/stream")!
    public static let nowPlayingAPIURL = URL(string: "https://c7.radioboss.fm/w/nowplayinginfo?u=205")!
    public static let artworkURLString = "https://c7.radioboss.fm/w/artwork/205.jpg"

    private static let stationName = "Bootie Mashup Radio"

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
    private var itemStatusObservation: NSKeyValueObservation?
    private var itemObservers: [NSObjectProtocol] = []
    private var currentStreamURL: URL = AudioPlayerManager.primaryStreamURL
    private var lastArtworkToken: String = ""
    private var artworkJPEG: Data?
    private var cachedArtwork: MPMediaItemArtwork?
    private var userWantsPlayback = false
    private var stallWorkItem: DispatchWorkItem?

    /// Boxed: `MPNowPlayingSession` is iOS/tvOS 16+.
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
            self.cachedArtwork = Self.makeMediaArtwork(from: image)
            #endif
            self.artworkJPEG = jpeg
            self.publishNowPlaying()
        }
        // Make sure the system has *something* sensible before the first poll.
        #if canImport(UIKit)
        if let fallback = UIImage(named: "background") {
            cachedArtwork = Self.makeMediaArtwork(from: fallback)
        }
        #endif
    }

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
            self.setupPlayer(with: url)
            if self.userWantsPlayback {
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
            command.removeTarget(nil)
            command.isEnabled = false
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
        userWantsPlayback = true
        configureAudioSession()
        if player == nil {
            setupPlayer(with: currentStreamURL)
        }
        player?.playImmediately(atRate: 1.0)
        isPlaying = true
        becomeNowPlayingApp()
        publishNowPlaying()
        metadataHook.start()
    }

    public func pause() {
        userWantsPlayback = false
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
        stallWorkItem?.cancel()
        stallWorkItem = nil
        timeControlStatusObservation?.invalidate()
        timeControlStatusObservation = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        itemObservers.forEach { NotificationCenter.default.removeObserver($0) }
        itemObservers.removeAll()
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
        // Seed metadata before playback starts so the very first Now Playing
        // snapshot sent to Watch / AirPlay already has title + artwork.
        item.externalMetadata = makeExternalMetadata()

        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.automaticallyWaitsToMinimizeStalling = true
        newPlayer.isMuted = isMuted
        // Audio-only: video external playback would steal Now Playing.
        newPlayer.allowsExternalPlayback = false
        self.player = newPlayer

        attachNowPlayingSession(to: newPlayer)

        timeControlStatusObservation = newPlayer.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] observed, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                switch observed.timeControlStatus {
                case .playing:
                    self.stallWorkItem?.cancel()
                    self.isPlaying = true
                    self.becomeNowPlayingApp()
                case .paused:
                    self.isPlaying = false
                case .waitingToPlayAtSpecifiedRate:
                    break
                @unknown default:
                    break
                }
                self.publishNowPlaying()
            }
        }

        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            guard observed.status == .failed else { return }
            DispatchQueue.main.async { self?.failover() }
        }

        let center = NotificationCenter.default
        itemObservers.append(center.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { [weak self] _ in
            self?.handleStall()
        })
        itemObservers.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.failover()
        })
    }

    private func attachNowPlayingSession(to player: AVPlayer) {
        // tvOS only. On iOS a MPNowPlayingSession with auto-publish off
        // becomes the system source and leaves the Watch blank.
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
            (nowPlayingSessionBox as? MPNowPlayingSession)?.becomeActiveIfPossible { _ in }
        }
        #endif
        #if canImport(UIKit)
        UIApplication.shared.beginReceivingRemoteControlEvents()
        #endif
    }

    /// A stall is usually transient on a live stream — only fail over if it persists.
    private func handleStall() {
        stallWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.userWantsPlayback,
                  self.player?.timeControlStatus != .playing else { return }
            self.failover()
        }
        stallWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    private func failover() {
        currentStreamURL = (currentStreamURL == Self.primaryStreamURL)
            ? Self.fallbackStreamURL
            : Self.primaryStreamURL
        setupPlayer(with: currentStreamURL)
        if userWantsPlayback {
            player?.playImmediately(atRate: 1.0)
            isPlaying = true
        }
        publishNowPlaying()
    }

    // MARK: - RadioBoss hook (the stream itself has none)

    public func startMetadataPolling() { metadataHook.start() }
    public func stopMetadataPolling() { metadataHook.stop() }
    public func fetchMetadata() { metadataHook.fetchNow() }

    public func fetchArtwork() {
        metadataHook.fetchArtwork(cacheBuster: String(Int(Date().timeIntervalSince1970)))
    }

    private func applyRadioBossPayload(_ json: RadioBossNowPlaying) {
        let nowPlaying = json.nowplaying.trimmed
        var artist = json.currenttrack_artist.trimmed
        var title = json.currenttrack_title.trimmed
        let nextTrack = json.nexttrack.trimmed

        if (artist.isEmpty || title.isEmpty), nowPlaying.contains(" - ") {
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
            displayText = Self.stationName
        }

        let finalArtist = artist.isEmpty ? Self.stationName : artist
        let finalTitle = title.isEmpty ? displayText : title
        let artworkToken = json.artwork_ts ?? nowPlaying

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

    // MARK: - Publish to Watch / Lock Screen / Control Center / AirPlay

    public func updateNowPlayingInfo() { publishNowPlaying() }

    private func publishNowPlaying() {
        let info = makeNowPlayingDictionary()

        // AirPlay receivers / systems reading AVFoundation tags.
        // NOTE: deliberately NOT setting AVPlayerItem.nowPlayingInfo — it
        // conflicts with MPNowPlayingInfoCenter and blanks the Watch.
        player?.currentItem?.externalMetadata = makeExternalMetadata()

        #if os(tvOS)
        if #available(tvOS 16.0, *),
           let session = nowPlayingSessionBox as? MPNowPlayingSession {
            session.nowPlayingInfoCenter.nowPlayingInfo = info
        }
        #endif

        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused

        #if DEBUG
        print("NowPlaying ->", info[MPMediaItemPropertyTitle] ?? "nil",
              "|", info[MPMediaItemPropertyArtist] ?? "nil",
              "| artwork:", info[MPMediaItemPropertyArtwork] != nil,
              "| rate:", info[MPNowPlayingInfoPropertyPlaybackRate] ?? "nil")
        #endif
    }

    private func makeNowPlayingDictionary() -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: songName.isEmpty ? trackTitle : songName,
            MPMediaItemPropertyArtist: trackArtist,
            MPMediaItemPropertyAlbumTitle: Self.stationName,
            MPMediaItemPropertyAlbumArtist: Self.stationName,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            MPNowPlayingInfoPropertyServiceIdentifier: Bundle.main.bundleIdentifier ?? "com.bootiemashup.radio",
            MPNowPlayingInfoPropertyExternalContentIdentifier: "bootiemashup-205"
        ]
        if let artwork = cachedArtwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        return info
    }

    private func makeExternalMetadata() -> [AVMetadataItem] {
        var items: [AVMetadataItem] = [
            Self.metadataItem(identifier: .commonIdentifierTitle, value: songName.isEmpty ? trackTitle : songName),
            Self.metadataItem(identifier: .commonIdentifierArtist, value: trackArtist),
            Self.metadataItem(identifier: .commonIdentifierAlbumName, value: Self.stationName)
        ]
        if let jpeg = artworkJPEG {
            let art = AVMutableMetadataItem()
            art.identifier = .commonIdentifierArtwork
            art.value = jpeg as NSData
            art.dataType = kCMMetadataBaseDataType_JPEG as String
            art.extendedLanguageTag = "und"
            items.append(art)
        }
        return items
    }

    #if canImport(UIKit)
    /// Builds artwork once per image. The request handler must be cheap and
    /// thread-safe: it is called by the system on arbitrary queues, repeatedly,
    /// for Lock Screen, Watch and AirPlay at different sizes.
    private static func makeMediaArtwork(from source: UIImage?) -> MPMediaItemArtwork? {
        guard let source, source.size.width > 0, source.size.height > 0 else { return nil }

        // Square, JPEG-backed, bitmap-based image (a bare CGImage-less UIImage
        // from a renderer can fail to transfer to the Watch).
        let side: CGFloat = 600
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let canvas = CGSize(width: side, height: side)
        let rendered = UIGraphicsImageRenderer(size: canvas, format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: canvas))
            let scale = max(side / source.size.width, side / source.size.height)
            let size = CGSize(width: source.size.width * scale, height: source.size.height * scale)
            let origin = CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2)
            source.draw(in: CGRect(origin: origin, size: size))
        }
        let frozen: UIImage = rendered.jpegData(compressionQuality: 0.85).flatMap(UIImage.init(data:)) ?? rendered

        return MPMediaItemArtwork(boundsSize: canvas) { _ in frozen }
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

final class StreamMetadataHook {
    var onUpdate: ((RadioBossNowPlaying) -> Void)?
    var onArtwork: ((UIImage?, Data) -> Void)?

    private var timer: Timer?
    private var artworkInFlight = false
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

    /// Many hosts (RadioBoss included) serve an HTML page instead of JSON to
    /// requests that don't look like a browser (default CFNetwork User-Agent,
    /// no Referer) or that come from a datacentre / emulator IP.
    private static let browserUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private func makeRequest(url: URL, accept: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(Self.browserUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://c7.radioboss.fm/", forHTTPHeaderField: "Referer")
        request.setValue("en-GB,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        return request
    }

    func fetchNow() {
        let request = makeRequest(url: AudioPlayerManager.nowPlayingAPIURL, accept: "application/json, text/plain, */*")

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                print("Now playing request failed: \(error.localizedDescription)")
                return
            }
            guard let data else { return }

            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? -1
            let type = http?.value(forHTTPHeaderField: "Content-Type") ?? "?"

            do {
                let json = try JSONDecoder().decode(RadioBossNowPlaying.self, from: data)
                DispatchQueue.main.async { self.onUpdate?(json) }
            } catch {
                let body = String(decoding: data.prefix(300), as: UTF8.self)
                    .replacingOccurrences(of: "\n", with: " ")
                print("Now playing: not JSON. HTTP \(status), \(type), final URL \(http?.url?.absoluteString ?? "?")")
                print("Now playing body starts: \(body)")
            }
        }.resume()
    }

    func fetchArtwork(cacheBuster: String) {
        guard !artworkInFlight else { return }
        let encoded = cacheBuster.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "0"
        guard let url = URL(string: "\(AudioPlayerManager.artworkURLString)?_=\(encoded)") else { return }
        let request = makeRequest(url: url, accept: "image/jpeg,image/*;q=0.8,*/*;q=0.5")
        artworkInFlight = true

        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async { self?.artworkInFlight = false }
            guard let self, let data, error == nil else { return }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                print("Artwork HTTP \(http.statusCode)")
                return
            }
            #if canImport(UIKit)
            guard let image = UIImage(data: data) else {
                print("Artwork response was not an image")
                return
            }
            DispatchQueue.main.async { self.onArtwork?(image, data) }
            #else
            DispatchQueue.main.async { self.onArtwork?(nil, data) }
            #endif
        }.resume()
    }
}

/// Tolerant decoder: RadioBoss fields may arrive as String, Int or Double,
/// and a single odd field must not make the whole payload fail.
struct RadioBossNowPlaying: Decodable {
    let nowplaying: String?
    let currenttrack_artist: String?
    let currenttrack_title: String?
    let nexttrack: String?
    let artwork_ts: String?

    private enum CodingKeys: String, CodingKey {
        case nowplaying, currenttrack_artist, currenttrack_title, nexttrack, artwork_ts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func flexible(_ key: CodingKeys) -> String? {
            if let s = try? c.decodeIfPresent(String.self, forKey: key) { return s }
            if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return String(i) }
            if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return String(Int(d)) }
            return nil
        }
        nowplaying = flexible(.nowplaying)
        currenttrack_artist = flexible(.currenttrack_artist)
        currenttrack_title = flexible(.currenttrack_title)
        nexttrack = flexible(.nexttrack)
        artwork_ts = flexible(.artwork_ts)
    }
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

#if !canImport(UIKit)
/// Stub so the hook compiles on non-UIKit (should not happen for iOS/tvOS).
typealias UIImage = NSObject
#endif
