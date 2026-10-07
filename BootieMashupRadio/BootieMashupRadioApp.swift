import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@main
struct BootieMashupRadioApp: App {
    init() {
        #if canImport(UIKit)
        UIApplication.shared.beginReceivingRemoteControlEvents()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
