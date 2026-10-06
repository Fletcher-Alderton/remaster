# Qobuz-Only Music App — Feature Checklist

This document tracks the requested product scope against the current iOS implementation. It is an implementation audit, not a claim that live Qobuz endpoints have been verified end to end.

## Status key

- **Implemented** — the core behavior is present in the current code.
- **Partial** — some meaningful behavior exists, but the full product requirement is not met or is not verified.
- **Not implemented** — no supporting implementation was found in the current source tree.

## Feature status

| Status | Feature | Current implementation / remaining work |
|---|---|---|
| **Implemented** | Make Qobuz the app’s sole music source | The app’s catalog and playback paths are Qobuz-backed. The local track/library models, indexing/import store, document picker, fixture-backed library screens, and queue-only local fallback have been removed. Settings no longer exposes local import. Tab configuration accepts only current tab IDs; startup filters old `tracks`, `playlists`, and `genres` IDs from saved preferences and persists the cleaned configuration. |
| **Partial** | Qobuz discovery page | `QobuzCatalogViewController` loads featured new releases and featured artists. The current page is limited to those featured lists; broader editorial discovery (curated playlists, genres, recommendations, pagination, etc.) is not evident. |
| **Partial** | Search Qobuz | Search calls Qobuz album, artist, and track endpoints and renders grouped results. Search runs on submit; debouncing, pagination, richer filters, and resilient handling of partial endpoint failures need follow-up. There is also a separate, short-lived track-search cache, but that is not audio caching. |
| **Partial** | Browse Qobuz albums | The Albums tab is connected to Qobuz, but it displays featured albums rather than a full/paginated catalog or the user’s Qobuz library. |
| **Partial** | Album pages and details | Album selection fetches album metadata and tracks, and the existing album detail view supports track selection, play, shuffle, and queue actions. No add-to-library or download action is present. |
| **Partial** | Browse artists and artist pages | The Artists tab shows featured artists. Artist detail requests include biography and albums, and the profile page presents the artist and album cards. It is not a complete/paginated artist browse or user library. |
| **Implemented** | Qobuz account sign-in and sign-out | OAuth sign-in is presented in an authentication session; credentials are stored in Keychain on device (simulator may be session-only), and sign-out removes them. The implementation does not show richer account/subscription management. Live sign-in is not covered by the checked-in unit tests. |
| **Partial** | Account and audio-quality settings | Settings exposes MP3, CD, Hi-Res 96, and Hi-Res 192 choices, and persists the selected format. Stream requests use that format and the player reports returned format metadata. Actual device output/resampling and lossless fidelity are not verified. |
| **Implemented** | Shared in-app player for Qobuz playback | Catalog track/album playback uses a common queue controller and `QobuzStreamPlayer`; the mini-player, full player, and queue view control the same playback state. Queue and player behavior is integrated in the app. This does not imply lock-screen/Control Center controls or persistent playback restoration. |
| **Partial** | Queue playback and queue actions | Qobuz queues support play, pause, seek, next/previous, enqueue, and play-next flows. Queue state is represented/persisted by app state, but startup currently clears the active playback backend’s queue; durable playback restoration is therefore not complete. |
| **Partial** | Lossless and Hi-Res playback | The app offers Qobuz CD/Hi-Res stream formats and sends the selected format ID when resolving a stream. This is a format-selection path, not proof of bit-perfect output; device route constraints, actual decoded stream quality, and lossless acceptance testing remain. |
| **Not implemented** | Gapless playback | Playback uses a single `AVPlayer` item. At track end it stops the current item, advances the queue, resolves the next URL, and creates another player item. There is no gapless queue/preparation or cross-track continuity implementation. |
| **Not implemented** | Proactively prefetch/cache upcoming queue audio | No audio download/prefetch pipeline or upcoming-track stream cache was found. The existing Qobuz search cache holds track metadata briefly; artwork caches are image-only and do not cache playable audio. |
| **Not implemented** | Automatic downloads for items added to the library | No Qobuz-library add workflow, automatic-download preference, or download manager was found. The app’s current likes are local app state, not a demonstrated Qobuz library, and do not trigger downloads. |
| **Not implemented** | Manual track/album downloads | No audio download task, persistent downloaded-file index, download UI, or offline playback path was found. |
| **Not implemented** | Offline-ready library/download management | The legacy local-file library has been removed. Qobuz tracks are not stored as managed offline downloads; a Qobuz-specific downloaded library and its storage controls still need to be built. |

## Suggested completion order

1. **Define the Qobuz library model:** decide what “added to library” means (Qobuz favorites/collection vs. app-local saved items), then implement add/remove and sync state.
2. **Build one download subsystem:** persistent download records, storage location, progress/errors/retries, cancellation/deletion, and offline playback. Add manual download actions first, then the automatic-download preference/trigger.
3. **Add queue prefetch:** resolve and cache the next eligible queue item(s), with limits, quality-aware cache keys, cancellation on queue changes, and cellular/storage policy.
4. **Implement gapless transitions:** prepare the next playable item before the current item ends and test consecutive album tracks, buffering, skips, queue edits, and stream-resolution failures.
5. **Complete catalog/library browsing:** pagination and the desired Qobuz editorial sections, plus the user’s saved albums/artists/tracks if those are in scope.
6. **Verify playback quality on devices:** test available Qobuz formats against actual stream metadata and device/audio-route behavior; clearly distinguish requested from delivered quality.
7. **Add automated coverage:** test download lifecycle, persistence/offline playback, automatic-download triggers, prefetch cancellation, and gapless transitions; keep live-Qobuz tests separately configurable.

## Audit notes

- Evidence comes from the current Swift source and checked-in tests. Relevant implementation areas include `ios/Music/Sources/Data/QobuzStreamingClient.swift`, `QobuzCatalogModels.swift`, `QobuzCatalogMapper.swift`, `PlaybackController.swift`, `QobuzStreamPlayer.swift`, `QobuzPreferences.swift`, `ios/Music/Sources/UI/Screens/QobuzCatalogViewController.swift`, `QobuzAccountViewController.swift`, and `ios/Music/Sources/RootViewController.swift`.
- Existing tests cover portions of catalog decoding/mapping, stream request configuration, queue state, and migration of legacy local tab preferences; they do not establish that live authentication/catalog requests work or validate download, lossless, or gapless behavior.
- The stream client identifies its signing/streaming protocol as ported from Qobine under GPL-3.0. Confirm required source/license notices before distribution. In the current working tree, `QOBINE_GPL-3.0.txt` and `THIRD_PARTY_NOTICES.md` are marked deleted; this checklist does not restore or modify them.
