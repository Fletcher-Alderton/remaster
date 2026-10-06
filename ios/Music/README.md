# Music for iOS 12

Native UIKit implementation of the visual prototype in the repository root.

## Generate and build

```sh
cd ios/Music
xcodegen generate
xcodebuild -project Music.xcodeproj -scheme Music \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=Local — iPod-era Preview' build
```

The deployment target is iOS 12.0 and the interface is tuned for the iPod touch
6th-generation 320 × 568 point portrait display. The source interface is
programmatic UIKit; `LaunchScreen.storyboard` is the required static iOS launch
resource.

The app uses Qobuz for catalog browsing and streamed audio playback. Local-file
import, indexing, and playback are not part of the app.
