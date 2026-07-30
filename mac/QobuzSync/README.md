# Qobuz Sync for macOS

Qobuz Sync watches for a USB-connected iPod, copies changed music and artwork
from `~/Music/Qobuz` into the iOS Music app's Documents directory, imports its
append-only playback history, and submits eligible plays to Last.fm.

## Requirements

- macOS 13 or later
- `libimobiledevice` (`brew install libimobiledevice`)
- The iPod Music app installed with bundle identifier
  `com.fletcher.MusicPrototype`
- A Last.fm API account (API key and shared secret) for scrobbling

## Build

```sh
cd mac/QobuzSync
xcodegen generate
xcodebuild -project QobuzSync.xcodeproj -scheme QobuzSync build
```

The app is intentionally not sandboxed because it needs to run
`idevice_id`/`afcclient` and read a user-selected music folder.

On the first connection it compares remote byte sizes before creating its sync
manifest, so an existing manually copied library is not retransferred. Later
connections use local size/modification-time fingerprints and never delete
music from the iPod.

Playback records are always retained in
`~/Library/Application Support/iPod Qobuz Sync/playback-history.json`. Last.fm
credentials are stored in Keychain; eligible cached plays are submitted in
batches of up to 50 after a successful sync.
