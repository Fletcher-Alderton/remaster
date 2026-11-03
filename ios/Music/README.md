# Music for iOS 12

Native UIKit implementation of the Qobuz-backed music player for the iPod touch.
See the [repository README](../../README.md) for the overview, screenshots, and demo.

## Generate and build

```sh
cd ios/Music
xcodegen generate
xcodebuild -project Music.xcodeproj -scheme Music \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16' build
```

Or from the repository root, `./run-simulator.sh` picks a small-screen simulator, builds,
installs, and launches.

The deployment target is iOS 12.0 and the interface is tuned for the iPod touch
6th-generation 320 × 568 point portrait display. The source interface is
programmatic UIKit; `LaunchScreen.storyboard` is the required static iOS launch
resource.

The app uses Qobuz for catalog browsing and streamed audio playback. Local-file
import, indexing, and playback are not part of the app.

## Install on the iPod touch

Xcode cannot deploy to the test device (iOS 12.5.8 has no Developer Disk Image), and the
app installed there uses a suffixed bundle id. Follow
[`.agents/skills/install-to-ipod/SKILL.md`](../../.agents/skills/install-to-ipod/SKILL.md)
rather than `xcodebuild -destination` against the device — it covers the build command,
the Qobuz credential injection, the entitlement trap in re-signing, and `ideviceinstaller`.
