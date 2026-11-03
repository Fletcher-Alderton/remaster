# Qobuz iPod App — Next Update Requirements

**Status:** Requirements with user-confirmed decisions and approved delivery sequence; not an implementation or completion checklist.  
**Target:** Personal-use iPod touch (6th generation), iOS 12.5.8.  
**Scope:** Artist/catalog improvements, album redesign, saved-library behavior, navigation, discovery, parametric EQ, and true-black dark mode.

## 1. Goals and constraints

- Preserve working Qobuz authentication, streaming, downloads, queue behavior, and Control Center AirPlay routing.
- Optimize the experience for the iPod's **320 × 568 pt / 640 × 1136 px (2×)** portrait screen and 1 GB RAM.
- Keep the interface compact, readable, responsive, and visually consistent. Avoid redundant labels, unnecessary transitions, and controls that crowd the screen.
- Use real Qobuz catalog/library data. Do not substitute app-local likes for Qobuz saved-track membership.
- Keep current display-sized artwork selection, downsampling, caching, visible-only loading, and stale-response protection across new content sections.
- Do not add an in-app AirPlay picker; routing remains available through Apple's Control Center.
- This document requests behavior, not a particular unverified Qobuz endpoint or an assumed audio-processing implementation.

## 2. Design references

### Reference A — Album page

[Album-page reference](file:///Users/fletcher/Downloads/IMG_863146FA55DD-1.jpeg)

Local path: `/Users/fletcher/Downloads/IMG_863146FA55DD-1.jpeg`

Use this image as the visual source of truth for the redesigned album page, adapted to the existing app's style and the iPod screen. Text extraction identifies an album title, artist names, genre/year, download state, Play and Shuffle controls, and a numbered track list with a star on one track.

### Reference B — Album overflow menu

[Album-menu reference](file:///Users/fletcher/Downloads/IMG_5BC13F28A53B-1.jpeg)

Local path: `/Users/fletcher/Downloads/IMG_5BC13F28A53B-1.jpeg`

Text extraction identifies these actions:

1. Remove…
2. Add to a Playlist…
3. Play Next
4. Play Later
5. Share Album…
6. Love
7. Dislike
8. Cancel

Also include the requested album-radio action, even though it is not listed in the extracted reference text.

**Inspection limitation:** Both image files exist and their text was extracted, but their visual layout could not be inspected in this session. Exact artwork placement, spacing, iconography, type sizes, colors, and menu treatment must be checked against the actual images during implementation. Do not treat OCR as a complete visual specification. The references are external local files, not copied into this repository.

## 3. Artist pages

### ART-01 — Separate release types

- Display **Albums** and **EPs** as distinct, clearly titled sections rather than one merged release list.
- Preserve Qobuz release-type metadata through fetching, pagination, and presentation mapping.
- Do not classify releases solely by title text or track count when Qobuz provides a release type.
- Display **Singles**, **Live Releases**, and **Compilations** in their own separate sections as well. Do not merge these into Albums or EPs.
- Deduplicate releases by Qobuz ID within each section and retain successfully loaded sections if another request fails.
- Omit truly empty sections. Distinguish empty results from failed loading.

### ART-02 — Artwork on artist-page tracks

- Every track row on an artist page, including top tracks, shows its album cover beside the track metadata.
- Use a stable placeholder for missing/failed artwork, with no layout jump.
- Load artwork only for visible or imminently visible content; reused rows must never display a previous track's cover.
- Keep title, saved-track indicator, download indicator, and interaction targets readable at 320 pt width.

### ART-03 — Qobuz artist playlists

- Add a section for playlists Qobuz associates with the artist.
- Show playlist artwork, name, and useful attribution when supplied by Qobuz.
- Opening a playlist displays its actual tracks and supports the existing playlist playback behavior.
- These are Qobuz-provided artist-associated playlists, not fabricated playlists or an arbitrary search for the artist's name.
- Verify the endpoint/schema and association semantics before implementation. Missing support must not be disguised as an empty successful response.

### ART-04 — Related artists

- Show a **Related Artists** section at the bottom of the artist page.
- Use Qobuz's related/similar-artist data, with portrait, name, and navigation to that artist's page.
- Deduplicate entries and exclude the current artist.
- A failed related-artists request must not prevent the main artist page from working.

**Acceptance:** An artist with albums, EPs, top tracks, playlists, and related artists displays all five content groups with correct artwork and working navigation. Partial failures preserve the rest of the page.

## 4. Track and album radio

### RAD-01 — Track radio

- Long-pressing a song exposes **Start Track Radio**, alongside existing track actions.
- Make it available wherever the shared song menu is used: saved Tracks, album/artist/playlist details, search, discovery where applicable, and Queue.
- Seed recommendations with the selected Qobuz track ID and use Qobuz's recommendation/radio results, not local random selection.

### RAD-02 — Album radio

- Long-pressing an album and opening its overflow menu expose **Start Album Radio**.
- Seed recommendations from the selected album using a verified Qobuz-supported mechanism. Album suggestions alone must not be presented as a playable radio queue without resolving their tracks and defining the seed behavior.

### RAD-03 — Queue and failure behavior

- Resolve a valid, playable radio queue before replacing the current queue or interrupting playback.
- Preserve Qobuz result ordering and apply the app's streamability restrictions.
- Show bounded loading/error feedback. Empty or failed results retain the existing queue and playback.
- Avoid duplicate requests from repeated taps while radio is loading.
- Proposed initial behavior: an explicit radio action replaces the queue with the returned playable results and starts playback; it is not an implicit Play Next action.
- **Decision deferred by the user:** continuous replenishment, seed inclusion, and recommendation repetition rules remain unresolved. Retain radio in the requested scope, but confirm these details before implementing its queue behavior; do not claim endless radio if only a finite queue is implemented.

**Acceptance:** Track/album seeds produce the expected Qobuz-derived queue; cancellation, empty results, and request failures never destroy the working queue.

## 5. Album page redesign

### ALB-01 — Compact reference-driven layout

- Redesign the page to match the intent of Reference A: a sleek album header, clear title/artist/genre/year hierarchy, compact playback controls, and a readable track list.
- Add a three-dot overflow control that opens the Reference B-style album actions.
- Keep Play, Shuffle, library state, and download state understandable without duplicating secondary controls across the header and track rows.
- Support long titles, multiple artists, multi-disc albums, missing metadata, and both themes without clipping or overlapping controls.
- Retain primary-album-artist navigation and per-track performer navigation.

### ALB-02 — Overflow actions

| Action | Required behavior |
|---|---|
| Add to Library / Remove… | Reflect the actual Qobuz album-save state. Confirm destructive removal where appropriate and only commit UI state after API success. Keep library removal distinct from deleting downloaded files. |
| Add to a Playlist… | **UI placeholder only for this update.** Show the menu row, but do not create a playlist or mutate playlist membership. Disable it or show a clear “Coming soon” message; never show false success. |
| Play Next | Insert the applicable album track sequence immediately after the current queue position without interrupting the current song. |
| Play Later | Append the applicable album track sequence to the queue. |
| Share Album… | Present the native share sheet using a canonical, non-secret Qobuz album link. |
| Love | Use Qobuz preference APIs, not an app-local substitute. Do not silently equate this with saving an album. Verify the supported operation and reflect confirmed server state. |
| Dislike | Use Qobuz preference APIs, distinct from library removal. Verify the supported operation and relationship/mutual exclusivity with Love. |
| Start Album Radio | Start the Qobuz-derived album radio defined above. |
| Cancel | Close the menu without any side effect. |

Only **Add to a Playlist…** is intentionally fake. Do not silently turn other unsupported actions into placeholders; resolve their backend semantics or identify them as blocked.

### ALB-03 — Per-track download icons

- Replace downloaded-track counters used as status indicators with an icon on each downloaded track.
- Saved/favorited and downloaded are different states: the saved-track star must not double as the download icon.
- Distinguish downloaded, downloading, failed, and not-downloaded states without relying only on color.
- Keep actionable download progress/error feedback where needed; removing the counter must not remove retry/cancel/delete functionality.
- Aggregate album download state may remain in the header, but should not redundantly repeat a downloaded-track count.

### ALB-04 — Single quality summary

- Show audio-quality information **once at the top of the album page**.
- Remove duplicate quality text and the redundant **“CD requested”** presentation from the album page.
- Distinguish album availability from requested stream quality and actual output. Do not label requested quality as measured delivered quality.
- Use one concise summary that can update if the selected stream setting changes; detailed explanations may remain in Settings.
- Do not remove useful returned-stream quality reporting from Now Playing merely to deduplicate album-page labels.

**Acceptance:** The album page and overflow menu are visually reviewed against both references on the actual iPod; all non-placeholder menu actions work, downloaded tracks have icons, and only one album quality summary appears.

## 6. Saved tracks represented in Albums

### LIB-01 — Membership and grouping

- The saved Albums tab includes:
  - Albums explicitly saved in the Qobuz library.
  - Albums containing one or more individually saved Qobuz tracks, even if the album itself is not saved.
- Group by stable Qobuz album ID, not title/artist text. Show a single album entry when both conditions apply.
- An album with only one saved track still appears in Albums.
- Opening an entry shows the full album track list in disc/track order.
- Mark individually saved tracks with a small **star**, including when their containing album is already saved.
- For an album represented only by saved tracks, visually dim tracks not individually saved, but keep them selectable and legible. Dimming means “not saved,” not “unavailable.”
- Actual non-streamable/unavailable tracks remain separately identified and cannot be made playable by this rule.
- **User confirmed:** an explicitly saved album is treated as a complete saved album for playback, even if its individual tracks are not separately starred.

### LIB-02 — Exact playback rules

For a **partially saved album** (album not explicitly saved, only some tracks saved):

| User action | New playback sequence |
|---|---|
| Tap a saved/starred track | That track, then only later saved tracks, in album order. |
| Tap the album Play button | All saved tracks in album order, starting at the first saved track. |
| Tap a dimmed, unsaved track | That track and every later playable album track, whether saved or unsaved. |

- Never include tracks preceding the selected track.
- Use the complete, unfiltered album order to calculate the suffix; UI filtering must not accidentally change album playback semantics.
- Queue selection is based on the entry's library context, not merely whether a track happens to appear in the global saved-track set.
- **User-confirmed consistency rule:** Shuffle shuffles the same eligible set as album Play; album Play Next/Play Later use that same eligible set without shuffling. On ordinary catalog/full-album pages, existing complete-album behavior remains.
- Removing saved tracks or an album updates grouping and eligibility after confirmed Qobuz success; keep the entry if another membership reason still applies.

**Required regression example:** Album order is `A, B, C, D, E`; only `B` and `D` are saved and the album itself is not saved.

- Album Play → `B, D`.
- Tap `B` → `B, D`.
- Tap `D` → `D`.
- Tap dimmed `C` → `C, D, E`.
- Tap dimmed `A` → `A, B, C, D, E`.
- Never duplicate `D` just because it is also a saved track.

### LIB-03 — Recently Added ordering

- Adding a track from an album already represented in the user's library moves that album to the top of the **Recently Added** order.
- Adding another track must not create another copy of the album entry.
- Update recency only after a successful library mutation; failed operations must not reorder the library.
- Persist this ordering across relaunches. Preserve A–Z/Z–A sorting when explicitly selected.
- **User confirmed:** “recents” means **Recently Added**, not Recently Played. Sort albums newest-first by their latest save activity: use the maximum of the album's explicit save timestamp (when present) and the save timestamps of its currently saved tracks. A newly saved track therefore bumps an existing album entry above older entries.
- Use each track's library-save timestamp, not its release date, last playback time, or position in an unrelated API response. Obtain Qobuz save timestamps where available so changes made on other devices are included.
- Verify timestamp availability and semantics in Qobuz responses. Persist successful in-app save times as a fallback, clearly distinguish unknown dates, and use deterministic tie-breaking. Do not invent historical timestamps for previously saved tracks. If Qobuz does not expose the necessary history, record that limitation before claiming cross-device recency is complete.
- Recompute the latest save timestamp when membership changes, using the remaining saved tracks and explicit album-save state.

## 7. Playback presentation and persistent mini-player

### NAV-01 — Album → Now Playing transition

- Pressing Play on an album presents Now Playing directly, with a single transition.
- Do not first dismiss/collapse the album page and then animate a separate player opening.
- Preserve the album page underneath Now Playing, including scroll position, loaded content, and relevant selection state.
- Swiping down from Now Playing returns to that same album page, not the library root.
- Apply the same preservation principle when starting album-track playback.

### NAV-02 — Mini-player availability

- When a current track exists, show the mini-player consistently across library, Discover, Search, artist, album, playlist, and Queue pages.
- Do not show a second mini-player on full-screen Now Playing.
- Hide it on Settings, while the user is typing/using the keyboard, and while a presented menu or sheet genuinely needs that space.
- Restore it immediately when the keyboard/menu closes or the user leaves Settings; preserve the same current track/progress/playback state.
- Mere search-field focus without a keyboard must not permanently hide the mini-player.
- Reserve layout space so it does not obscure the final row, scroll controls, or primary actions.
- Hiding/showing the mini-player must never pause audio, replace the queue, or reset underlying navigation.

### NAV-03 — Now Playing song-change animation

- Add a brief, clear transition when the current song changes while Now Playing is visible, making the change apparent through artwork and track-metadata animation.
- Cover next/previous actions, swipe-to-change gestures, automatic advancement, and selecting a different queue track. Use directional motion for next/previous where the direction is known.
- Animate actual track/queue-position changes, not elapsed-time updates, pause/resume, or a late artwork download for the same song.
- Keep playback uninterrupted and controls responsive. Rapid skips must settle on the latest selected song without stale artwork, metadata, or overlapping animations.
- Respect Reduce Motion with a subtle fade or non-motion alternative.
- This is an in-place player-content transition, not dismissal/reopening of Now Playing or the album beneath it.

**Acceptance:** Album Play opens Now Playing once; swipe-down restores the album. The mini-player remains visible on all eligible pages and reliably returns after menus and typing. Song changes have a visible, responsive transition that preserves playback and correctly handles rapid skips and Reduce Motion.

## 8. Refresh messaging and Search cleanup

### REF-01 — Quiet automatic library refresh

- Do not display **“Refreshing your Qobuz library”** during automatic/background refresh, tab return, or ordinary content hydration.
- Retain useful first-load empty-state feedback and actionable failure feedback; quiet refresh must not produce a blank, unexplained screen.
- Show refresh-in-progress feedback only for an explicit user refresh.
- Preserve the pull-down search/tools reveal interaction: the first pull reveals search/sort options; an additional deliberate pull at the top performs refresh.
- Keep the explicit Refresh control, if retained, equivalent to the deliberate pull-to-refresh action.
- Trigger at most one refresh while another is in flight. Keep visible library content and the user's filter/sort during refresh or failure.

### SRCH-01 — Remove redundant explanatory text

- Remove **“Search the Qobuz catalog”** from Search.
- Remove **“Qobuz editorial discover”** from Discover.
- Preserve useful search placeholders, section headings, empty states, and accessible labels; remove redundant page copy rather than necessary instructions.

## 9. Discover redesign

### DSC-01 — Mixed vertical/horizontal browsing

- Use a vertically scrolling Discover page containing clearly titled sections with horizontally scrolling cards/rails where appropriate.
- Make new releases, editorial selections, playlists, and artist content easy to distinguish and reach without one long undifferentiated list.
- Keep existing genre/tag filtering and supported discovery categories accessible.
- Cards show readable title/artist or attribution and correctly sized artwork.
- Where a rail is truncated, provide a clear way to browse the full section or load more without requiring endless sideways swipes.
- Horizontal rail gestures must not accidentally trigger tab-edge navigation; vertical gestures must still scroll the page naturally.
- Preserve scroll positions across detail navigation and when returning from Now Playing.
- Show partial content when one section fails, with local retry rather than a full-page failure where possible.
- Use bounded pagination, reusable cells, and visible-only image loading appropriate for the iPod's memory limit.

**Acceptance:** Users can navigate both axes comfortably on the iPod, open cards, return to the same position, reach filters, and browse with the mini-player visible without content obstruction.

## 10. Parametric EQ, AutoEq search, and profile import

### EQ-01 — Real parametric equalizer

- Add an enable/bypass switch, preamp, and editable parametric bands with center frequency, gain, Q/bandwidth, filter type, and per-band enable state.
- Support at least the peaking and low/high-shelf filters needed by common AutoEq parametric profiles.
- **User intent:** support all AutoEq parametric profiles rather than impose an arbitrary band limit. “31 bands” was a tentative suggestion, not a confirmed maximum or a request to replace PEQ with a 31-band graphic equalizer.
- Inventory the supported AutoEq parametric profile catalog/schema to establish the largest actual filter count and required filter types. Use a variable-length band model and size the processing path to support that verified range on the iPod; do not silently truncate profiles.
- Do not assume AutoEq has one permanent universal maximum. Validate complete profiles at import/application time, report any explicit processing limit before changing the active profile, and resolve performance constraints with the user rather than claiming unsupported profiles work.
- Validate parameter ranges and reject unstable/non-finite filter values. Explain unsupported filters rather than silently dropping them.
- Provide a flat/reset action and clipping/headroom guidance. AutoEq preamp values must be imported and respected.
- Changes apply audibly during playback without restarting the track or replacing the queue.
- Persist the selected profile, edits, and bypass state across relaunches.
- EQ must affect real audio, including supported downloaded-audio playback; a controls-only UI does not satisfy this requirement.

### EQ-02 — AutoEq profile search

- Search AutoEq's headphone/IEM profile catalog by model name and show enough source/measurement information to distinguish similarly named results.
- Allow previewing filter parameters/preamp before applying a profile.
- Applying a result updates the actual PEQ configuration and clearly identifies the active profile.
- Cache successfully downloaded profiles for offline reuse; handle network failures and no-results states.
- Do not assume every AutoEq result is parametric. Prefer a compatible parametric profile and clearly identify unsupported result formats.
- Verify the distribution source, update mechanism, attribution/license requirements, and exact profile schema before implementation.

### EQ-03 — PEQ profile import

- Import profiles using the native document picker on iOS 12.
- Baseline format: common Equalizer APO/AutoEq **parametric text** with `Preamp` and supported `Filter` entries. Additional formats may be added only with an explicit parser and tests.
- Validate the entire profile before changing the active EQ. A malformed/unsupported import must leave the previous profile intact.
- Show imported profile name, preamp, band count, and any unsupported elements before applying.
- Allow imported profiles to be selected, renamed, and removed without deleting unrelated documents.
- Do not treat a graphic-EQ frequency/gain list or convolution impulse response as equivalent to a PEQ profile.

### EQ-04 — Playback feasibility and AirPlay compatibility gate

- The current transport uses `AVPlayer`; arbitrary realtime PEQ is not a simple session flag. Investigate and prove a suitable processing path before committing to a transport redesign.
- Preserve seek, pause/resume, queue transitions, downloads, background playback, and working Qobuz stream formats.
- Verify whether the chosen AirPlay route transmits locally processed audio or bypasses the local DSP path.
- Do not claim EQ is active on AirPlay if the route bypasses processing. Report a route limitation clearly and resolve the supported behavior explicitly.
- Validate CPU, memory, stability, clipping, and battery impact on the actual iPod touch 6, not just a modern simulator.

**Acceptance:** An audible/measurable band change, flat bypass, valid AutoEq profile, valid imported profile, malformed import, relaunch persistence, and supported-route playback all pass. AirPlay/EQ limitations are documented and surfaced accurately.

## 11. True-black dark mode

### THM-01 — App-wide consistency

- Use **RGB `#000000`** for the main dark backgrounds, including navigation/detail surfaces, library, Search, Discover, Queue, full player, mini-player background, Settings, and app-owned modal/menu surfaces.
- Retain appropriate contrasting text, icons, separators, and control fills. True black does not require making every disabled control or artwork placeholder black.
- Remove unintended light/gray page backgrounds, white flashes during transitions, and mismatched cells/headers in dark mode.
- Reapply colors when the theme changes, including visible/reused cells and already presented screens.
- Preserve a correct light theme and existing manual/automatic theme selection on iOS 12.
- System-owned share sheets, document pickers, and other OS UI must use supported iOS 12 appearance capabilities; do not promise unsupported full recoloring of system/browser surfaces.
- Saved-track dimming, download icons, menus, quality labels, and keyboard transitions remain legible and accessible in both themes.

**Acceptance:** Review every app-owned screen and relevant loading/empty/error/menu state in both themes on the iPod, including live theme switching. Main dark surfaces resolve to `#000000` and transitions show no unintended light backgrounds.

## 12. Sources of truth and likely ownership

| Area | Source of truth | Current implementation areas to assess |
|---|---|---|
| Artist sections, playlists, related artists, radio | Verified Qobuz responses and stable IDs | `QobuzStreamingClient.swift`, `QobuzCatalogModels.swift`, `QobuzCatalogMapper.swift` |
| Album/detail layout, menus, track indicators | Reference images plus requirements above | `UI/Screens/DetailViewControllers.swift`, `ScreenModels.swift`, `ScreenViews.swift` |
| Saved/partial albums and recent ordering | Qobuz saved albums/tracks plus explicitly local recency metadata | Catalog models/client, `AppState.swift`, `RootViewController.swift`, `QobuzCatalogViewController.swift` |
| Playback eligibility and transitions | Explicit ordered queue policy and shared playback state | `PlaybackController.swift`, `RootViewController.swift`, `PlayerViewController.swift` |
| Persistent mini-player | Shared current-track/playback state and presentation/keyboard state | `RootViewController.swift`, `MiniPlayerView.swift`, detail/catalog presentation |
| Download icons | Persistent download records, not queue/library counts | `QobuzDownloadManager.swift`, detail/track-row views |
| PEQ | Actual audio-processing configuration and validated profile data | `QobuzStreamPlayer.swift`, playback layer, Settings, new scoped EQ modules as needed |
| Theme | Shared theme tokens and current appearance mode | `UI/Theme.swift` and all app-owned surfaces |
| Image delivery | Existing display-sized shared artwork pipeline | `ArtworkImagePipeline.swift` |

`QOBUZ_FEATURES.md` is an older implementation audit, not the source of truth for whether these new requirements are complete. Some entries there predate the working download, AirPlay, personal-authentication, and artwork changes. Reconcile it against the live implementation when execution begins rather than overwriting it based on this proposal.

## 13. Confirmed decisions and remaining implementation gates

1. **Release grouping — confirmed:** separate Albums, EPs, Singles, Live Releases, and Compilations sections.
2. **References — confirmed by user:** the two linked images are the correct design references. The user has reviewed them; implementation still requires direct visual inspection for layout fidelity.
3. **Love/Dislike — confirmed:** use Qobuz preference APIs. Endpoint availability, returned state, and mutual-exclusivity semantics still require verification; do not substitute local preferences.
4. **Radio — deferred:** leave finite versus continuously replenished queues, seed inclusion, and repetition rules undecided for now. Confirm them before implementing dependent playback behavior.
5. **Partial-library policy — confirmed:** the full-album interpretation, saved-track suffix examples, Shuffle/Play Next/Play Later eligible sets, and membership-removal rules above are approved.
6. **Recency — confirmed:** Recently Added, ordered by latest album/track save activity, including the most recently saved track within each album. Verify Qobuz timestamp support and document any cross-device limitation.
7. **EQ capacity — intent confirmed, capacity to verify:** support the full range of AutoEq parametric profiles, using their actual largest filter count rather than treating the tentative 31-band suggestion as a fixed limit. Verify filter types, schemas, iOS 12 DSP performance, and AirPlay behavior. Graphic EQ and convolution formats remain distinct from PEQ.

The product decisions above supersede earlier tentative interpretations. Remaining API, timestamp, and DSP gates must be investigated rather than silently assumed resolved.

## 14. Approved delivery sequence and verification

The user approved steps 1–6 below. This records agreement with the delivery plan; it does not mark any of these features implemented or verified.

1. **Verify APIs and model semantics:** release types, artist playlists/related artists, radio, Love/Dislike, saved-track/album membership, and recency. Build representative fixtures without real credentials.
2. **Implement library grouping and queue policies:** test the exact A–E partial-album example, multi-disc ordering, duplicates, removal, and persistence before wiring new controls.
3. **Redesign album/artist screens:** references, overflow actions, icons, one quality summary, and new artist sections; preserve navigation and current playback.
4. **Unify presentation and theme:** retained album under Now Playing, global mini-player rules, keyboard/menu restoration, quiet refresh, Search cleanup, and true-black surfaces.
5. **Redesign Discover:** vertical sections, horizontal rails, filters, pagination, and gesture conflict handling.
6. **Prototype EQ processing first, then build profile UX:** verify real DSP and AirPlay behavior, followed by editing, AutoEq search, import, persistence, and device performance.

### Release acceptance checklist

- [ ] All requirements above are implemented, or explicitly marked deferred with user agreement; no placeholder except the approved playlist-add row.
- [ ] Focused unit tests cover model decoding, API failures, queue eligibility/order, saved-state updates, download icon state, recency, profile parsing, and theme transitions.
- [ ] UI tests exercise album Play → Now Playing → swipe-down, song-change animations (including rapid skips and Reduce Motion), overflow actions, mini-player exceptions/restoration, pull-to-reveal versus refresh, and nested Discover scrolling.
- [ ] Album page/menu reviewed against both actual reference images at 320 × 568 pt.
- [ ] Regression checks preserve working authentication, library, downloads, streaming, queue restoration, image loading, and Control Center AirPlay.
- [ ] Live Qobuz integration verified separately from mock tests for artist content, radio, library mutations, and quality availability.
- [ ] Physical iPod verification covers background/locked playback, AirPlay transitions, long lists, offline/download behavior, PEQ performance, and both themes.
- [ ] New failures are reconciled; no unsupported endpoint, unimplemented DSP, or simulator-only result is described as device-verified.
