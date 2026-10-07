import SwiftUI
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

@main
struct BootieMashupRadioApp: App {
    init() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            print("App launch AVAudioSession: \(error.localizedDescription)")
        }

        #if canImport(UIKit)
        UIApplication.shared.beginReceivingRemoteControlEvents()
        #endif

        _ = AudioPlayerManager.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
