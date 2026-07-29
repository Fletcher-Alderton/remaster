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

Audio playback is intentionally simulated. Imported files are copied into the
application-support directory and indexed with AVFoundation.

## What is implemented

- Configurable one-to-six-tab library with drag reordering and persistent settings.
- Tracks, albums, artists, playlists, genres, album details, profiles, queue, and Settings.
- Horizontal swipes switch library tabs and open Settings past the final tab.
- Tab navigation only begins at the left or right screen edge. Song rows use
  horizontal threshold gestures: swipe left to add to Queue or, with a full
  swipe, Play Next; swipe right to like or, with a full swipe, show the More
  placeholder. Actions use icon-only reveals and confirmation toasts.
- Vertical navigation follows a consistent stack: swipe down from details or Now
  Playing to return, swipe up from Now Playing to open Queue, and swipe down from
  Queue to return to Now Playing. Scrollable screens only dismiss when at the top.
- Pull-down search/filter controls on library screens.
- Silent playback simulation, seeking, play/pause, likes, queue changes, waveform progress,
  and the playing/paused artwork states.
- Multi-file document import, background AVFoundation metadata indexing, duplicate checks,
  versioned JSON persistence, and cached/downsampled artwork.
- Unit and UI test targets in the `Music` scheme.

The installed Xcode currently has only an iOS 26 simulator runtime, so the project
compiles with an iOS 12.0 deployment target but final runtime compatibility still
needs to be confirmed on the physical iPod touch 6.
