# Bootie Mashup Radio - iOS & tvOS

Official native iOS and tvOS application for **Bootie Mashup Radio**, streaming the best mashups 24/7.

![Bootie Mashup Radio](BootieMashupRadio/Assets.xcassets/banner320.imageset/banner320.png)

---

## Features

- 🎧 **24/7 High Quality Audio Streaming**: Automatic primary stream connection (`https://c7.radioboss.fm/stream/205`) with automatic seamless failover to secondary stream if needed.
- 📺 **iOS & tvOS Support**: Full support for iPhone, iPad, and Apple TV (tvOS 15.0+).
- 📻 **Live Now Playing & Coming Next Info**: Automatic metadata updates for current track, artist, and coming next track every 5 seconds.
- 🖼️ **Album Artwork Integration**: Real-time album artwork updates fetched directly from the stream feed with smooth fallback graphics.
- 🔊 **Mute / Unmute & Play / Pause Controls**: Simple, sleek touch controls matching the Android application layout.
- 📡 **AirPlay & Bluetooth Support**: Control playback via connected Bluetooth devices (headphones, car audio, Apple Watch) or stream to AirPlay receivers using the built-in route picker.
- 📱 **Lock Screen, Control Center & Media Remote Control**: Full integration with iOS `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` for remote playback control and background media playback.

---

## Compatibility

- **iOS**: iOS 15.0 or later (iPhone, iPad, iPod touch)
- **tvOS**: tvOS 15.0 or later (Apple TV 4K / Apple TV HD)

---

## Installation Guide

### Option 1: Download Pre-built App (Recommended)

1. Go to the **Releases** section on this GitHub repository.
2. Scroll down to assets.
3. Download the appropriate file :
   - Download `BootieMashupRadio-iOS-IPA` for iOS devices.
   - Download `BootieMashupRadio-tvOS-ZIP` for Apple TV devices.
4. Install the IPA on your iPhone or Apple TV using your preferred sideloading method:
   - **AltStore / AltServer**: [altstore.io](https://altstore.io)
   - **Sideloadly**: [sideloadly.io](https://sideloadly.io)
   - **TrollStore** (if supported on your iOS version)

---

### Option 2: Build from Source with Xcode

#### Prerequisites
- A Mac running macOS 12 or later
- Xcode 14.0 or later (with iOS and tvOS SDKs installed)
- An Apple ID (Free or Developer Account)

#### Steps:
1. Clone this repository:
   ```bash
   git clone https://github.com/purplescorpion1/Bootie-Mashup-Radio-IOS.git
   cd Bootie-Mashup-Radio-IOS
   ```
2. Open `BootieMashupRadio.xcodeproj` in Xcode:
   ```bash
   open BootieMashupRadio.xcodeproj
   ```
3. Select your desired target:
   - `BootieMashupRadio` for iPhone / iPad
   - `BootieMashupRadioTV` for Apple TV
4. In Xcode, go to **Signing & Capabilities** under target settings:
   - Check **Automatically manage signing**.
   - Select your personal or developer Apple ID Team.
5. Connect your iPhone or Apple TV via USB / Network.
6. Select your connected device as the destination target and click **Run** (or `Cmd + R`) to compile and install.

---

## License & Credits

Copyright © Bootie Mashup Radio. All rights reserved.
