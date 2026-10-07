import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import AVFoundation

@main
struct BootieMashupRadioApp: App {
    init() {
        // Activate the audio session as early as possible so the system
        // recognises the app as a potential Now Playing source.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true, options: [])
        } catch {
            print("App launch AVAudioSession setup failed: \(error.localizedDescription)")
        }

        #if canImport(UIKit)
        UIApplication.shared.beginReceivingRemoteControlEvents()
        #endif

        // Ensure the shared player manager (and its remote-command wiring)
        // is created at launch rather than lazily on first play.
        _ = AudioPlayerManager.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
