# Audio Path Diagnostics and Sample-Rate Request

*   **Author:** Fletcher (with the Elephant-Goldfish method)
*   **Status:** Approved — revised after Goldfish review
*   **Date:** 2026-10-26

--------------------------------------------------------------------------------

## Overview

This design makes the app's audio path observable and lets the user request a sample
rate.

Two things are added to Settings:

1.  **A report.** What the stream actually is, what the equaliser actually runs at, and
    what the audio session actually took — four short lines, measured, not inferred.
2.  **A sample-rate request.** A control that asks `AVAudioSession` for 44.1, 48, 88.2,
    96 or 192 kHz, or requests nothing.

**Bit depth cannot be set.** `AVAudioSession` declares `setPreferredSampleRate` and no
bit-depth member at all, so output depth is chosen by iOS and the route. This design
reports bit depth and never claims to control it.

**Rate is a request, not a setting.** `setPreferredSampleRate` asks; `session.sampleRate`
reports what the route took. The report shows both so a refusal is visible instead of
implied.

## The Problem

The app streams FLAC through `AVPlayer`, equalises it in a `MTAudioProcessingTap`, and
tells the user nothing about the format either side of that tap. Three questions are
unanswerable from inside the app:

*   What format did Qobuz actually deliver for this track?
*   What rate does the biquad cascade actually run at?
*   Is the route resampling, or is the equaliser working at the native rate?

The current Settings text concatenates an observed-session sentence
(`QobuzStreamPlayer.swift:21`) that disclaims bit depth but conflates three different
rates: the stream's, the tap's, and the session's. A user asking "is the EQ applied at
the file's native rate" deserves a measured answer.

Terminology used throughout:

*   **Stream rate** — the rate in the returned Qobuz stream description.
*   **Processing rate** — the rate of the buffers the equaliser callback receives.
*   **Session rate** — `AVAudioSession.sampleRate`, the app-to-hardware I/O rate.
*   **Route** — the current output path (speaker, headset, USB DAC, AirPlay) and the
    rates it supports.

## Goals

*   Report the returned stream's bit depth, rate and codec for the playing item.
*   Report the rate, channel count and sample format the equaliser is actually invoked
    with.
*   Report the session rate and whether a requested rate is in use.
*   State a comparison verdict: same rate as the source, converted, or unknown.
*   Distinguish equaliser bypassed (no profiles), idle (profiles all switched off),
    active, and unavailable (tap creation failed).
*   Let the user request a rate and see the outcome without a promise.
*   Refresh automatically on route change, interruption and track change.
*   Show "unknown" rather than a guess when a value is unavailable.

## Non-Goals

*   Setting or guaranteeing output bit depth. No public API exists.
*   Clearing a sample-rate request. `AVAudioSession` exposes no reset for it; see
    [Limitations and Known Risks](#limitations-and-known-risks).
*   Reconfiguring the audio session mid-playback. The request is applied when the
    session activates, so a change takes effect at the next playback start.
*   Bit-perfect output. Incompatible with `AVPlayer` and with equalisation.
*   Parsing compressed format descriptions for bit depth, which commonly carry
    `mBitsPerChannel == 0`.
*   Per-track history, logging, or export.
*   Reporting DAC or hardware precision.

## Open Questions

*   **Q1 — Does the tap see the native rate when the session matches it?** AVFoundation
    may insert a converter that reports a different processing format even when the
    rates agree. The report answers this on hardware; the design does not assume it.
*   **Q2 — Does iOS retain a sample-rate request across session deactivation?**
    Undocumented. If it does, "Auto" cannot restore the route's preference until the app
    relaunches. The report shows the outcome either way, and the UI says a change applies
    from the next playback start.
*   **Q3 — AirPlay.** The remote device picks its own rate; the report will show the
    mismatch rather than hide it.

## Critical User Journeys (CUJs)

### CUJ 1: Read the path for a hi-res track

*   **Given**: a 24-bit / 96 kHz FLAC playing, one profile enabled, a route limited to
    48 kHz, the automatic option selected.
*   **When**: the user opens Settings.
*   **Then**: the Audio Path section reads:

    ```text
    Source: 24-bit / 96.0 kHz · flac
    EQ: 32-bit float / 48.0 kHz · 2 ch
    Converted 2:1 before the EQ (96.0 → 48.0 kHz).
    Sample rate: automatic (session 48.0 kHz).
    Output bit depth is chosen by iOS. Audio is float-processed and is not bit-perfect while EQ is active.
    ```

### CUJ 2: Request a rate

*   **Given**: the same track, automatic selected.
*   **When**: the user selects 48 kHz.
*   **Then**: the option persists and the line reads
    "Sample rate: 48.0 kHz requested. Applies from the next playback start." until the
    session next activates, after which it reads
    "Sample rate: 48.0 kHz requested and in use."

### CUJ 3: Request a rate the route refuses

*   **Given**: a route that only runs at 44.1 kHz.
*   **When**: the user selects 192 kHz and playback restarts.
*   **Then**: the control stays on 192 and the report reads
    "Sample rate: 192.0 kHz requested; session is 44.1 kHz." No promise is implied.

### CUJ 4: No equaliser, and idle equaliser

*   **Given**: no profiles stored.
*   **When**: the user opens Settings while a track plays.
*   **Then**: the source line is populated, the EQ line reads "EQ: bypassed (no
    profiles)", and no verdict is shown.

*   **Given**: two profiles stored, both switched off.
*   **Then**: the EQ line reads "EQ: idle (all profiles off)".

### CUJ 5: Route change

*   **Given**: a USB DAC unplugged while playing.
*   **When**: the route falls back to the speaker.
*   **Then**: within the next run loop the report refreshes and shows the new session
    rate. The stored request is unchanged and applies at the next playback start.

## Technical Plan (Architecture)

```text
  QobuzTrackURL (returned stream: bitDepth, samplingRate, mimeType)
        |
        v
  AudioPathMonitor.shared <---- MTAudioProcessingTap prepare (ASBD)
        |        ^                       |
        |        |                       +--> EQActivity (bypassed/idle/active/unavailable)
        |        |                                from EQChainRuntime
        |        +---- AVAudioSession.sampleRate (activation, route change, interruption)
        |        +---- AudioPathPreferences.option
        v
  Settings > Audio Path  --(segmented control)-->  AudioPathPreferences
                                                          |
                                                          v
                                          AVAudioSession.setPreferredSampleRate
                                            (applied at session activation)
```

### 1. Model and formatting

New file: `Sources/Data/AudioPath.swift`.

```swift
struct StreamFormatSummary: Equatable {
    var sampleRateHz: Double     // samplingRate * 1000
    var bitDepth: Int            // 0 when the response did not say
    var codec: String?           // "flac", "mp3", ...
    static func from(_ stream: QobuzTrackURL) -> StreamFormatSummary
}

struct TapFormatSummary: Equatable {
    var sampleRate: Double
    var channels: Int
    var bitsPerChannel: Int
    var isFloat: Bool
    static func from(_ description: AudioStreamBasicDescription) -> TapFormatSummary
}

enum EQActivity: Equatable {
    case bypassed      // no profiles stored
    case idle          // profiles stored, every filter switched off
    case starting      // installed, tap prepared, format not reported yet
    case active        // a tap is running with at least one filter
    case unavailable   // profiles stored, but no tap could be created
}

struct AudioPathReport: Equatable {
    var source: StreamFormatSummary?
    var processing: TapFormatSummary?
    var activity: EQActivity
    var sessionSampleRate: Double       // 0 while the session is inactive
    var requestedOption: AudioSampleRateOption
    /// The option that was in force at the last session activation.
    var appliedOption: AudioSampleRateOption
}

enum AudioPathFormatting {
    static let rateTolerance: Double = 1.0

    static func sourceLine(_ report: AudioPathReport) -> String
    static func equaliserLine(_ report: AudioPathReport) -> String
    static func verdictLine(_ report: AudioPathReport) -> String
    static func sampleRateLine(_ report: AudioPathReport) -> String
    static let bitDepthCaveat: String
}
```

Formatting rules, all pure functions:

*   `sourceLine`
    *   no source: `"Source: unavailable (nothing has played yet)"`
    *   with depth and codec: `"Source: 24-bit / 96.0 kHz · flac"`
    *   depth 0 omits the segment; no codec omits the codec segment.
    *   Rate is kHz to one decimal: `String(format: "%.1f", hz / 1000)`.
*   `equaliserLine`
    *   `.bypassed`: `"EQ: bypassed (no profiles)"`
    *   `.idle`: `"EQ: idle (all profiles off)"`
    *   `.unavailable`: `"EQ: unavailable (the tap could not be created)"`
    *   `.starting`: `"EQ: starting…"`
    *   `.active`: `"EQ: 32-bit float / 48.0 kHz · 2 ch"`, or `"EQ: 48.0 kHz · 2 ch"`
        when the tap format is not float.
*   `verdictLine` returns `""` unless `activity == .active`.
    *   source or processing missing: `"EQ rate cannot be compared yet."`
    *   `abs(source - processing) <= rateTolerance`:
        `"EQ runs at the source rate (48.0 kHz)."`
    *   processing lower: `"Converted 2:1 before the EQ (96.0 → 48.0 kHz)."` The ratio is
        `source / processing`, rendered with `%.0f` when integral within 0.05, else
        `%.1f`.
    *   processing higher: `"EQ runs above the source rate (48.0 → 96.0 kHz)."`
*   `sampleRateLine`
    *   session inactive (`sessionSampleRate == 0`): `"Session inactive."`
    *   automatic: `"Sample rate: automatic (session 48.0 kHz)."`
    *   a fixed option is stored, but the session has not activated since it was chosen
        (`requestedOption != appliedOption`):
        `"Sample rate: 48.0 kHz requested. Applies from the next playback start."`
    *   requested and in use (within `rateTolerance`):
        `"Sample rate: 48.0 kHz requested and in use."`
    *   requested, session differs:
        `"Sample rate: 192.0 kHz requested; session is 44.1 kHz."`
*   `bitDepthCaveat` is fixed:
    `"Output bit depth is chosen by iOS. Audio is float-processed and is not bit-perfect while EQ is active."`

### 2. Sample-rate request

Same file.

```swift
enum AudioSampleRateOption: Int, CaseIterable {
    case automatic, hz44100, hz48000, hz88200, hz96000, hz192000
    var hertz: Double?          // nil for automatic
    var title: String           // "Auto", "44.1", "48", "88.2", "96", "192"
    var detail: String          // "Automatic", "44.1 kHz", ...
}

final class AudioPathPreferences {
    static let shared: AudioPathPreferences
    init(defaults: UserDefaults = .standard, key: String = "Music.audio.sampleRateOption")
    var option: AudioSampleRateOption { get set }
    /// Requests the rate. Returns false when nothing was requested or the call threw.
    @discardableResult
    func apply(to session: AVAudioSession) -> Bool
}
```

*   Stored as the option's raw `Int`, following `QobuzPreferences`
    (`QobuzPreferences.swift:11-14`), which uses `integer(forKey:)` and a raw value. An
    unknown stored value reads as `.automatic`.
*   `apply` is called from `activateSessionIfNeeded()` before `setActive(true)`, and from
    the Settings control as a convenience for the next activation. Swift imports the
    setter as `throws`, so it is a `do`/`catch` returning `false` on error and logging
    like `QobuzStreamPlayer.swift:196`.
*   `.automatic` requests nothing and returns `false`.

### 3. Monitoring

New file: `Sources/Data/AudioPathMonitor.swift`.

```swift
final class AudioPathMonitor {
    static let shared: AudioPathMonitor
    static let didChange = Notification.Name("MusicAudioPathDidChange")

    /// Lock-protected copy. Safe from any thread.
    func snapshot() -> AudioPathReport

    func updateSource(_ summary: StreamFormatSummary?)      // main thread
    func updateProcessing(_ summary: TapFormatSummary?)     // tap prepare/unprepare
    func refreshSession(_ session: AVAudioSession)          // main thread
    /// Records the option that was in force at the last activation.
    func noteAppliedOption(_ option: AudioSampleRateOption)
    /// Profiles stored, filters enabled, and whether a tap could be created.
    func updateEqualiser(installed: Bool, filterCount: Int, tapAvailable: Bool)
}
```

*   Stored fields sit behind one `os_unfair_lock`. `snapshot()` copies a value type under
    the lock and returns it. No UIKit, no allocation on the render path.
*   `didChange` is posted with `DispatchQueue.main.async` when the mutation did not
    happen on the main thread, and synchronously when it did.
*   The monitor's `init` seeds from `AudioPathPreferences.shared` and
    `EQChainRuntime.shared`, and observes `AVAudioSession.routeChangeNotification`,
    `AVAudioSession.interruptionNotification`,
    `AVAudioSession.mediaServicesWereResetNotification` and
    `EQChainRuntime.installStateDidChange`. Route, interruption and reset all call
    `refreshSession`; the install-state notification clears `processing` when the
    equaliser goes away.
*   `activity` is derived from `installed`, `filterCount`, `tapAvailable` and whether a
    processing format has been reported:
    not installed → `.bypassed`; zero filters → `.idle`; no tap → `.unavailable`;
    otherwise `.starting` or `.active`.

### 4. Capture points

**Source.** The returned stream is already carried everywhere it is needed:
`QobuzTrackURL` (`QobuzStreamingClient.swift:158`) holds `bitDepth`, `samplingRate`
(kHz) and `mimeType`. `QobuzPlaybackController` invokes `onStreamResolved` from a single
place for the offline, live and preloaded-promotion paths
(`PlaybackController.swift:276`, `:300`, `:430`). Those three call sites are refactored
into one private `publishResolvedStream(_:quality:stream:)` which also calls
`AudioPathMonitor.shared.updateSource(StreamFormatSummary.from(stream))`.

This replaces the design's earlier plan to parse `AVAssetTrack.formatDescriptions`: a
compressed FLAC description reports `mBitsPerChannel == 0`, so it cannot produce the
24-bit figure the user is asking about, while the API response can.

**Processing.** `eqTapPrepare` already builds an `AVAudioFormat` from the callback's
`processingFormat` (`EQAudioTap.swift:35-38`). It additionally calls
`AudioPathMonitor.shared.updateProcessing(TapFormatSummary.from(processingFormat.pointee))`.
`eqTapUnprepare` calls `updateProcessing(nil)`.

**Session.** `activateSessionIfNeeded()` applies the stored option before
`setActive(true)`, then calls `noteAppliedOption(option)` and `refreshSession(session)`
after it succeeds. `stop()` does not deactivate the session, so no other call site is
needed.

**Tap availability.** `EQAudioMixFactory.makeAudioMix` returns `nil` on failure; the
player passes that outcome to the monitor so `.unavailable` is reachable rather than
theoretical.

### 5. Settings UI

Modified: `Sources/UI/Screens/SettingsViewController.swift`.

A new section, `Audio Path`, between `Qobuz Account & Audio Quality` and `Parametric EQ`:

*   `audioPathSection` via the existing `sectionLabel(_:)`.
*   `audioPathGroup` via the existing `configure(group:)`.
*   `sampleRateControl`: `UISegmentedControl` over `AudioSampleRateOption.allCases`,
    `accessibilityIdentifier = "settings.audioPath.sampleRate"`. Selecting an option
    stores it, applies it, and refreshes.
*   Five labels in one vertical stack, 10 pt secondary text: source, equaliser, verdict,
    sample rate, caveat. Identifiers `settings.audioPath.source`, `.equaliser`,
    `.verdict`, `.sampleRate`, `.caveat`. The verdict label hides itself when its text is
    empty.
*   Refresh points: `refreshAudioPath()` from `viewWillAppear`, from
    `AudioPathMonitor.didChange` (observer stored in `audioPathObserver`, removed in
    `deinit` beside `audioRouteObserver` at line 16), and after the segmented control
    changes.
*   The existing concatenation of `QobuzStreamPlayer.observedAudioSessionDescription`
    into `qualityGuidance` (`SettingsViewController.swift:80`) is removed: the new
    section reports the same facts better, and two contradictory session sentences must
    not both be on screen. The now-unused static is deleted.

Exactly two existing constraints change: `eqSection.topAnchor` attaches to
`audioPathGroup.bottomAnchor` instead of `qobuzGroup.bottomAnchor`, and the new section
and group constraints are added to the existing `NSLayoutConstraint.activate` block:

```text
audioPathSection.leading  = tabsSection.leading
audioPathSection.top      = qobuzGroup.bottom + 18
audioPathGroup.leading    = tabsTable.leading
audioPathGroup.trailing   = tabsTable.trailing
audioPathGroup.top        = audioPathSection.bottom + 6
sampleRateControl.leading  = audioPathGroup.leading + 8
sampleRateControl.trailing = audioPathGroup.trailing - 8
sampleRateControl.top      = audioPathGroup.top + 8
sampleRateControl.height   = 36
labels.leading  = audioPathGroup.leading + 10
labels.trailing = audioPathGroup.trailing - 10
labels.top      = sampleRateControl.bottom + 8
labels.bottom   = audioPathGroup.bottom - 12
```

### 6. Tests

New file: `Tests/AudioPathTests.swift`:

*   **Formatting**: the exact strings for CUJ 1; equal-rate verdict; converted verdict
    with integral and fractional ratios; upsampled verdict; unknown source; inactive
    session; automatic; requested-and-in-use; requested-pending; requested-refused;
    verdict empty when not active.
*   **Stream summary**: `StreamFormatSummary.from(stream)` converts `samplingRate` kHz to
    Hz, keeps `bitDepth`, maps a `mime_type` of `audio/flac` to `flac`.
*   **Tap summary**: a 24-bit integer non-interleaved ASBD → `bitsPerChannel == 24`,
    `isFloat == false`; a float32 ASBD → float, 32 bits; `mBitsPerChannel == 0` → 0.
*   **Preferences**: round-trip each option through `UserDefaults(suiteName:)`; an
    unknown stored raw value reads as `.automatic`; `apply` returns false for
    `.automatic`.
*   **Monitor**: `updateSource`/`updateProcessing`/`refreshSession` produce a snapshot
    matching the inputs and each post `didChange`; `updateProcessing(nil)` returns the
    line to `.starting`; `updateEqualiser(installed: true, filterCount: 0, ...)` yields
    `.idle`.
*   **Settings UI**: the segmented control exists, reflects the stored option, and
    selecting one persists it; the five labels exist and the caveat is non-empty.

No test asserts real session behaviour: the simulator does not honour sample-rate
requests meaningfully, and the outcome is device-dependent by design.

### 7. Files touched

| File | Change |
| :--- | :----- |
| `Sources/Data/AudioPath.swift` | new — summaries, report, formatting, options, preferences |
| `Sources/Data/AudioPathMonitor.swift` | new — capture, publication, activity |
| `Sources/Data/EQAudioTap.swift` | modified — report the tap's ASBD and tap availability |
| `Sources/Data/PlaybackController.swift` | modified — one publish path that also updates the monitor |
| `Sources/Data/QobuzStreamPlayer.swift` | modified — apply the request at activation, refresh the session, delete the old static |
| `Sources/UI/Screens/SettingsViewController.swift` | modified — Audio Path section, observer, one re-anchored constraint |
| `Tests/AudioPathTests.swift` | new |
| `Music.xcodeproj/project.pbxproj` | modified — two new sources, one new test |

`QobuzStreamTestViewController` keeps its own "Actual stream" label; it is a diagnostic
screen, not part of this feature.

## Alternatives Considered

### Alternative A: Infer the source format from the selected quality

*   **Pros**: no new capture code.
*   **Cons**: the quality setting is what was requested, not delivered; a track may be
    44.1 kHz while Hi-Res 192 is selected. Reporting it as fact is the exact failure this
    feature corrects.
*   **Reason for Rejection**: reports a wish as a measurement.

### Alternative B: Parse `AVAssetTrack.formatDescriptions` for bit depth

*   **Pros**: measures the file rather than trusting the API.
*   **Cons**: a compressed FLAC description reports `mBitsPerChannel == 0`, so it yields
    no bit depth at all; it also requires a `readyToPlay` hook that misfires for preloaded
    items.
*   **Reason for Rejection**: produces less information than the response already in
    hand, at higher complexity.

### Alternative C: Force the session rate to the stream rate automatically

*   **Pros**: makes the native-rate case the default.
*   **Cons**: the stream rate is only known after resolution, so the session would be
    reconfigured on every track change; on routes that cannot do 96 or 192 kHz that is a
    guaranteed reconfigure per track.
*   **Reason for Rejection**: unpredictable interruptions; the report gives the same
    information without surprising the user.

### Alternative D: Apply the rate request live, mid-playback

*   **Pros**: the change is audible immediately.
*   **Cons**: `setPreferredSampleRate` during playback can reconfigure the route and
    interrupt audio; the app's interruption handler only clears `sessionActive`
    (`QobuzStreamPlayer.swift:73-79`) and has no `.ended` branch, so recovery is not
    guaranteed.
*   **Reason for Rejection**: applying at activation reaches the same end state with no
    interruption path to harden.

--------------------------------------------------------------------------------

## Non-Functional Requirements

### Honesty

*   Every line is either a measured value or an explicit unavailable state.
*   No line claims bit-perfect output. The caveat is fixed text.
*   A refused rate is reported as refused and the control is never silently rewritten.

### Performance

*   Five short strings per refresh, driven by notifications rather than polling.
*   No work on the render callback. `prepare`/`unprepare` take a short lock, write two
    scalars, and post on the main queue.

### Compatibility

*   iOS 12.0 (`project.yml:10`): `setPreferredSampleRate` is iOS 6, block
    `NotificationCenter` observers are iOS 4, `AVAudioSession.sampleRate` is iOS 6.
*   `session.sampleRate` is 0 while inactive; `sampleRateLine` has an explicit inactive
    branch so nothing renders "0.0 kHz".

### Rollout & Rollback

The report only reads state. The request is one stored integer whose default,
`.automatic`, requests nothing — identical to today's behaviour. Removing the section
restores the previous behaviour with no data migration.

--------------------------------------------------------------------------------

## Limitations and Known Risks

*   **Bit depth is reported, not controlled.** No public API sets it.
*   **"Auto" cannot clear a previous request.** `AVAudioSession` exposes no reset; the
    previous preference may persist until the app relaunches (Open Question 2). The
    report shows the session's actual rate so this is visible rather than hidden.
*   **The rate applies at the next playback start**, so the control's effect is not
    immediate by design.
*   **Equal rates do not prove nothing was converted.** A converter can preserve the
    nominal rate while changing depth or layout.
*   **The source figure is what Qobuz reported**, not what the file contains if the API
    misreports it.
*   **One processing slot.** One tap per item and one playing item, so a second tap's
    `prepare`/`unprepare` can overwrite the reported format during a hand-off.
*   **AirPlay decides its own rate**; the report shows the mismatch.
*   **One item at a time.** The report describes the current item, not history.

--------------------------------------------------------------------------------

## Review Resolution (EGM resolve phase)

Six zero-context Goldfish reviewers audited this document against the live source and
the iOS 26.5 SDK headers. Dispositions:

| # | Finding | Disposition |
| :-- | :--- | :--- |
| 1 | The spec claims `QobuzStreamPlayer` already has a route-change handler and re-applies the rate; it has none (only `SettingsViewController.swift:68`) | **Accepted** — the player has no such observer; the monitor observes route changes itself, and the request is only applied at activation |
| 2 | Applying a rate mid-playback can interrupt audio, and the interruption observer has no `.ended` branch, so playback may not resume | **Accepted** — the request is applied only in `activateSessionIfNeeded()`; live reconfiguration rejected as Alternative D |
| 3 | Comparing `session.sampleRate` with the request cannot reliably prove refusal (async update, valid only when active) | **Accepted** — the line reports both values ("requested; session is X") instead of judging, plus explicit inactive and pending branches |
| 4 | `.automatic` cannot undo a previous request | **Accepted** — recorded as a limitation and Open Question 2; the report shows the real session rate |
| 5 | `sampleRateLine` has no inactive branch although the NFR promises one | **Accepted** — explicit inactive branch and a decision table over option, requested rate and session rate |
| 6 | Source capture inside the `item === currentItem` gate misses preloaded items and goes stale on stop | **Accepted** — source now comes from the resolved stream, which already fires for offline, live and promoted-preload paths |
| 7 | Reading `formatDescriptions` at `readyToPlay` assumes a key is loaded, may block, and yields no bit depth for FLAC | **Accepted** — removed entirely; the API response supplies bit depth |
| 8 | `updateProcessing` has no item identity, so one tap's unprepare can clear another's format | **Accepted, bounded** — one tap per item and one playing item; recorded as a limitation |
| 9 | `prepare` is not guaranteed to run off the render thread, so a lock, lazy singleton and main-queue hop in it are unsafe | **Accepted** — no allocation, two scalars under a short lock, notification posted asynchronously |
| 10 | "Converted by AVFoundation" and "runs at the source rate" assert cause the rates cannot prove | **Accepted** — wording describes rates; the limitation states equal rates prove nothing about internal conversion |
| 11 | Notification storms and an unremoved observer token | **Accepted** — one observer property removed in `deinit`; refresh is notification-driven, not polling |
| 12 | `AudioPathPreferences` needs an injection point for the `UserDefaults(suiteName:)` test | **Accepted** — `init(defaults:key:)` |
| 13 | `applyPreference` has no error handling, thread rule or single home | **Accepted** — one type (`AudioPathPreferences`), `do`/`catch` returning false, main thread, applied at activation |
| 14 | `private(set) var report` cannot take a lock; no read API | **Accepted** — `snapshot()` copies under the lock; fields private |
| 15 | Only one constraint specified; the section would be unlayoutable | **Accepted** — the full constraint list is written out |
| 16 | Old `observedAudioSessionDescription` would print a second, contradictory session line | **Accepted** — removed and the static deleted |
| 17 | `setPreferredSampleRate` is `throws` in Swift, not `-> Bool` | **Accepted** — `do`/`catch` |
| 18 | `AudioFormatSummary.from(description, ...)` passes a pointer where a value is required | **Accepted** — obsolete; now `TapFormatSummary.from(processingFormat.pointee)` |
| 19 | Persistence precedent is wrong: `QobuzPreferences` stores an `Int` raw value, not a double with a 0 sentinel | **Accepted** — raw `Int` option; unknown value reads as `.automatic` |
| 20 | All-off profiles would display an active EQ line | **Accepted** — `EQActivity.idle` added |
| 21 | The fixed caveat claims float processing even when EQ is bypassed | **Accepted** — the caveat says "while EQ is active" |
| 22 | Monitor/singleton, four lines, a preference enum and a control are over-engineered | **Partially accepted** — source capture and ASBD parsing cut (finding 7); a report and a request are the two things the user asked for, so both stay |
| 23 | The sample-rate control cannot be guaranteed, so do not ship it | **Rejected** — the user asked to attempt it; shipping it with an honest report and activation-time application is the accurate answer, and the report is useful even when the request is refused |


### Implementation-time findings

Three defects were found while building and verifying this, all fixed:

1.  **Re-entrant notification loop.** `publish()` posted synchronously on the main
    thread, the Settings observer refreshed, the refresh mutated the monitor and posted
    again. It recursed until the stack overflowed and the test host crashed on launch.
    Publishing is now always asynchronous, and the UI's equaliser refresh runs with
    `publish: false`.
2.  **`snapshot()` leaked a private type.** The first draft returned the internal state
    struct, which the compiler rejected; it now builds and returns `AudioPathReport`.
3.  **`AudioPathPreferences.shared` mutates global state in tests.** The Settings test
    selects 48 kHz through the real shared preferences and resets to `.automatic`
    afterwards, so the choice does not leak into other tests.

Verified layout, measured from a rendered 320 pt-wide Settings screen: the segmented
control sits at x=22, y=470, 276 × 37; the five labels stack beneath it from y=514 to
y=580; the Parametric EQ table begins at y=626. Nothing overlaps and every element stays
inside the 14 pt content inset.
