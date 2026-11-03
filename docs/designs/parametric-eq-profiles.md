# Parametric EQ Profiles

*   **Author:** Fletcher (with the Elephant-Goldfish method)
*   **Status:** Approved — revised after Goldfish review
*   **Date:** 2026-10-26

--------------------------------------------------------------------------------

## Overview

This design adds parametric equaliser (PEQ) profiles to the Music app. A profile is a
list of biquad filters written in the Equalizer APO / AutoEQ `ParametricEQ.txt` format.
The user loads one or more profiles, and each profile has its own on/off switch in
Settings. Every switched-on profile contributes its filters to a single chain applied to
Qobuz playback inside the app process.

A **biquad** is a two-pole, two-zero IIR filter section. It costs a handful of
multiply-adds per sample and needs only the previous two inputs and outputs, so the
whole chain can run inline on each audio buffer without extra buffering.

Three parts:

1.  A parser and DSP core that turns profile text into biquad coefficients and applies
    them to decoded buffers. Pure, unit-testable, no AVFoundation dependency.
2.  An audio hook in `QobuzStreamPlayer` that installs an `MTAudioProcessingTap` on each
    `AVPlayerItem`. A **tap** is a C callback AVFoundation invokes with decoded PCM on
    its own audio render thread just before output. `AVPlayer` owns decoding and exposes
    no sample buffers, so a tap is the only supported way to alter streamed audio.
3.  A Settings section that lists profiles with switches, imports a profile from pasted
    text, and shows exactly what was parsed.

## The Problem

The app streams Qobuz audio through one long-lived `AVQueuePlayer` per
`QobuzStreamPlayer` instance (`Sources/Data/QobuzStreamPlayer.swift:43`). There is no
tone control of any kind. Headphone-correction profiles published by AutoEQ are plain
text, and there is no way to load one.

The requested outcome is narrow: load a parametric profile, keep a per-profile switch,
hear the correction. The hard part is not the maths. It is inserting DSP into an
`AVPlayer` that must keep streaming, keep the 30-second gapless preload hand-off, and
keep working from the background with the screen locked.

## Goals

*   Parse the Equalizer APO parametric format: `Preamp:`, `Filter N:`,
    `ON`/`OFF`, `PK`, `LSC`, `HSC`, `LS`, `HS`, `Fc`/Hz, `Gain`/dB, `Q`, `S`,
    `BW Oct`, `#` comments, CRLF line endings, arbitrary whitespace and letter case.
*   Load, name, persist, enable, disable and delete profiles. A toggle takes effect
    within one render buffer without interrupting playback or disturbing the preloaded
    next track.
*   Apply the combined chain per channel, with coefficients for the rate the tap
    actually delivers.
*   Preserve the existing transport invariants: locked-screen playback, gapless advance
    into a preloaded item, interruptions, media-services resets.
*   Report skipped lines instead of dropping them silently.
*   Reduce the risk of digital clipping when profiles are combined.

## Non-Goals

*   `GraphicEQ:`, `Convolution:`, `Copy:`, `Delay:` and every other directive except
    `Preamp:` and `Filter N:`. These land in the skipped-lines list.
*   Filter kinds beyond `PK`, `LSC`, `HSC`, `LS`, `HS`. `LP`, `HP`, `NO`, `BP`, `AP`
    are skipped with a stated reason. The supplied profile needs only `PK` and `LSC`,
    and AutoEQ emits nothing else.
*   Per-channel profiles. `Channel: all` is accepted and ignored; `Channel: L`, `R` or
    any other value refuses the whole profile, because silently folding a one-ear
    correction into both ears is worse than refusing it.
*   Crossfeed, room correction, time alignment.
*   Editing individual filter values in the UI. Profiles are imported as text and
    inspected, not authored, in-app.
*   EQ beyond Qobuz playback. There is no other audio path; downloaded tracks already
    play through the same `QobuzStreamPlayer` (`RootViewController.swift:1030`), so they
    are covered by the same hook.
*   Guaranteeing EQ over AirPlay. See [Limitations](#limitations-and-known-risks).

## Open Questions

*   **Q1 — AirPlay**: whether iOS invokes a post-effects tap while routed to AirPlay,
    and whether a local tap's output would be used at all, cannot be settled without a
    device and a receiver. The UI states that EQ applies on this device.
*   **Q2 — Mid-playback mix attachment**: whether assigning `AVPlayerItem.audioMix` to
    an item that is already rendering takes effect immediately is not documented. The
    design avoids depending on it (mixes are attached before an item becomes current);
    the case only matters when the user enables their very first profile mid-track, and
    the fallback is that it applies from the next item.

Neither blocks implementation. Both are stated as caveats, not assumed away.

## Critical User Journeys (CUJs)

### CUJ 1: Load the supplied 13-filter profile

*   **Given**: signed in to Qobuz, a track playing, Settings open, no EQ profiles yet.
*   **When**: the user taps "Add Profile…", pastes the text below, names it
    "Headphones", and taps Save.

    ```text
    Preamp: -2.0 dB
    Filter 1: ON LSC Fc 60 Hz Gain -3.7 dB Q 0.70
    Filter 2: ON PK Fc 480 Hz Gain 1.1 dB Q 2.00
    Filter 3: ON PK Fc 1600 Hz Gain -0.5 dB Q 1.50
    Filter 4: ON PK Fc 5178 Hz Gain 2.0 dB Q 1.20
    Filter 5: ON PK Fc 12401 Hz Gain -0.3 dB Q 1.90
    Filter 6: OFF PK Fc 9350 Hz Gain -0.3 dB Q 2.90
    Filter 7: ON PK Fc 8032 Hz Gain -0.7 dB Q 7.00
    Filter 8: ON PK Fc 8950 Hz Gain 1.2 dB Q 6.69
    Filter 9: ON PK Fc 3824 Hz Gain -0.5 dB Q 2.25
    Filter 10: ON PK Fc 14791 Hz Gain -0.3 dB Q 7.00
    Filter 11: ON PK Fc 3049 Hz Gain -2.4 dB Q 3.30
    Filter 12: ON PK Fc 11573 Hz Gain -4.0 dB Q 7.78
    Filter 13: ON PK Fc 8928 Hz Gain -6.1 dB Q 4.62
    ```

*   **Then**: a row appears with its switch on and the subtitle
    "13 filters · Preamp −2.0 dB · 1 off"; the detail view lists 13 filters with filter
    6 dimmed and marked OFF; the audible response changes from the next track onwards
    without the current track restarting.

### CUJ 2: Toggle individual profiles

*   **Given**: two profiles loaded, both switches on.
*   **When**: the user switches one off.
*   **Then**: playback continues uninterrupted; the next buffer reflects only the
    remaining profile; the switch state survives relaunch.

### CUJ 3: Turn every profile off

*   **Given**: profiles on and audible.
*   **When**: the user switches the last one off.
*   **Then**: output returns to the unprocessed stream, louder by the removed preamp,
    without a track restart.

### CUJ 4: Reject a bad profile

*   **Given**: the editor is open.
*   **When**: the user pastes text with no recognisable filter line, or a `Channel: L`
    directive.
*   **Then**: an alert names the reason, the editor stays open, and no profile is
    created. When only some lines are unusable, the profile saves with the supported
    filters and the detail view lists the skipped lines verbatim.

### CUJ 4b: Partially unsupported profile

*   **Given**: the editor is open.
*   **When**: the user pastes two `PK` filters plus one `GraphicEQ:` line.
*   **Then**: the profile saves with two filters, its subtitle shows "2 filters · 1
    skipped", and the detail view shows the skipped line.

### CUJ 5: Locked-screen track advance

*   **Given**: a profile enabled, playing with the device locked, the next track already
    preloaded 30 seconds ahead.
*   **When**: the current track ends and playback advances into the preloaded item.
*   **Then**: the preloaded item is equalised from its first buffer, because its mix was
    attached at preload time and never re-attached afterwards.

## Technical Plan (Architecture)

```text
   Settings UI: EQ section
      |  add / toggle / delete
      v
   EQProfileStore ----------------> EQChainRuntime.shared
   (UserDefaults JSON)               (POD parameter buffer
      |                               + generation counter,
      |                                 os_unfair_lock protected)
      +--> EQProfileParser                       |
              |                                  |
              +--> [EQFilter] -> EQBiquadMath     |
                                                 v
   QobuzStreamPlayer.play / preload        EQAudioProcessor
        AVPlayerItem.audioMix                   reads params under lock,
              |                                 coefficients in prepare,
              v                                 cascade per channel
        MTAudioProcessingTap (post-effects)
```

### 1. Model and parser

New file: `Sources/Data/EQProfile.swift`.

```swift
enum EQFilterKind: String, Codable {
    case peaking      = "PK"
    case lowShelfQ    = "LSC"   // shelf shaped by Q
    case highShelfQ   = "HSC"
    case lowShelfSlope  = "LS"  // shelf shaped by slope S
    case highShelfSlope = "HS"
}

struct EQFilter: Codable, Equatable {
    var index: Int          // the N in "Filter N:"
    var isEnabled: Bool     // the ON/OFF token
    var kind: EQFilterKind
    var frequency: Double   // Hz
    var gain: Double        // dB; 0 for kinds that carry no gain
    var q: Double           // > 0 for PK/LSC/HSC, 0 otherwise
    var slope: Double       // > 0 for LS/HS, 0 otherwise
}

struct EQProfile: Codable, Equatable {
    var id: String          // UUID string, assigned by the caller
    var name: String
    var preamp: Double      // dB, 0 when absent
    var filters: [EQFilter]
    var skippedLines: [String]   // verbatim text of unusable lines
    var sourceText: String       // original pasted text
    var isEnabled: Bool
}

struct EQParseResult: Equatable {
    var preamp: Double
    var filters: [EQFilter]
    var skippedLines: [String]
}

enum EQParseError: LocalizedError, Equatable {
    case emptyInput
    case noUsableFilters(skipped: [String])
    case unsupportedChannel(String)
    var errorDescription: String? { ... }
}

enum EQProfileParser {
    static func parse(_ text: String) throws -> EQParseResult
}
```

`id` and `isEnabled` are assigned by the editor, never by the parser, so parsing stays
deterministic. `EQProfile` has no `dateAdded`: nothing sorts or displays it, and
insertion order is the display order.

Line rules, applied after splitting on any newline and stripping everything from the
first `#`:

*   Blank lines are ignored.
*   `preamp:` (case-insensitive) followed by a number, optionally `dB` → the preamp.
*   `filter <n>:` followed by `ON`/`OFF`, a kind token, then key/value pairs. Keys are
    case-insensitive and may appear in any order; `Hz`/`dB`/`Oct` unit tokens are
    ignored. Numbers accept a leading sign and a decimal point.
    *   `fc` → frequency, required.
    *   `gain` → gain, required for `PK`/`LSC`/`HSC`, defaults to 0 otherwise.
    *   `q` → Q, required for `PK`. Defaults to `0.707` for `LSC`/`HSC`.
    *   `s` → slope, required for `LS`/`HS`; defaults to `1.0`.
    *   `bw` → bandwidth in octaves, converted with `q = sqrt(2^bw) / (2^bw - 1)`.
        A `bw` value on a shelf is converted to Q the same way.
*   `channel:` with a value other than `all` throws `.unsupportedChannel(value)`.
*   Any other line, any unknown kind, and any filter line with a missing or
    non-numeric `fc`/`gain`/`q`/`s` is appended to `skippedLines` verbatim.
*   No usable filters and no skipped count → `.emptyInput` for blank text, otherwise
    `.noUsableFilters`.

### 2. Biquad maths

New file: `Sources/Data/EQDSP.swift`.

```swift
struct EQBiquadCoefficients: Equatable {
    var b0: Double; var b1: Double; var b2: Double; var a1: Double; var a2: Double
}

enum EQBiquadMath {
    /// nil when the filter is unusable at this rate (f <= 0, f >= 0.49 * rate, q/s <= 0)
    static func coefficients(for filter: EQFilter, sampleRate: Double) -> EQBiquadCoefficients?
    static func magnitudeDB(_ c: EQBiquadCoefficients, at frequency: Double, sampleRate: Double) -> Double
}
```

Robert Bristow-Johnson audio EQ cookbook, with
`w0 = 2*pi*fc/sampleRate`, `cosw = cos(w0)`, and `A = pow(10, gain/40)`:

*   `PK`: `alpha = sin(w0)/(2*Q)`.
    `b0 = 1 + alpha*A`, `b1 = -2*cosw`, `b2 = 1 - alpha*A`,
    `a0 = 1 + alpha/A`, `a1 = -2*cosw`, `a2 = 1 - alpha/A`.
*   `LSC` / `HSC`: `alpha = sin(w0)/(2*Q)`, then the cookbook shelf forms:
    *   `LSC`: `b0 =    A*((A+1) - (A-1)*cosw + 2*sqrt(A)*alpha)`,
        `b1 =  2*A*((A-1) - (A+1)*cosw)`,
        `b2 =    A*((A+1) - (A-1)*cosw - 2*sqrt(A)*alpha)`,
        `a0 =       (A+1) + (A-1)*cosw + 2*sqrt(A)*alpha`,
        `a1 =   -2*((A-1) + (A+1)*cosw)`,
        `a2 =       (A+1) + (A-1)*cosw - 2*sqrt(A)*alpha`.
    *   `HSC`: `b0 =    A*((A+1) + (A-1)*cosw + 2*sqrt(A)*alpha)`,
        `b1 = -2*A*((A-1) + (A+1)*cosw)`,
        `b2 =    A*((A+1) + (A-1)*cosw - 2*sqrt(A)*alpha)`,
        `a0 =       (A+1) - (A-1)*cosw + 2*sqrt(A)*alpha`,
        `a1 =    2*((A-1) - (A+1)*cosw)`,
        `a2 =       (A+1) - (A-1)*cosw - 2*sqrt(A)*alpha`.
*   `LS` / `HS`: the same shelf forms with the slope form of alpha,
    `alpha = sin(w0)/2 * sqrt((A + 1/A) * (1/S - 1) + 2)`.

Every result is normalised by `a0`. A non-finite coefficient means the filter is
unusable and `coefficients` returns `nil`; the caller records it as skipped.

`magnitudeDB` evaluates `H(z)` at `z = exp(-j*w)` and returns `20*log10(|H|)`.

### 3. Chain composition and headroom

New file: `Sources/Data/EQChainRuntime.swift`.

```swift
struct EQFilterParam {          // POD, copied to the render thread
    var kind: Int32             // EQFilterKind raw index
    var frequency: Double
    var gain: Double
    var q: Double
    var slope: Double
}

let EQMaximumSections = 64

protocol EQParameterSource: AnyObject {
    /// Copies parameters into the caller's preallocated buffer. No allocation.
    func copyParameters(into buffer: UnsafeMutablePointer<EQFilterParam>,
                        count: inout Int, preampDB: inout Double) -> Int32
}

final class EQChainRuntime: EQParameterSource {
    static let shared: EQChainRuntime
    static let installStateDidChange = Notification.Name("MusicEQInstallStateDidChange")

    init()                                   // internal, so tests get isolated instances
    func update(profiles: [EQProfile])       // call after every store mutation
    var isInstalled: Bool { get }            // true when at least one profile is stored
    var installedFilterCount: Int { get }
    /// Peak-response estimate used for the safety trim, computed off the audio thread.
    func peakGainDB(profiles: [EQProfile], sampleRate: Double) -> Double
}
```

Composition, on the main thread only:

1.  Concatenate the enabled filters of every enabled profile, in store order then
    `index` order. Truncate to `EQMaximumSections` and record the overflow.
2.  `rawTrimDB = sum(profile.preamp)`.
3.  Evaluate the combined magnitude response on 256 log-spaced points from 20 Hz to
    `min(20000, sampleRate*0.49)` and take `peakDB = max(values)`. This uses a fixed
    48 kHz reference: the runtime never learns the format the tap will deliver, and the
    peak between 20 Hz and 20 kHz moves by a few tenths of a dB between 44.1 and 96 kHz.
4.  `safetyTrimDB = min(0, -(rawTrimDB + peakDB))`, `preampDB = rawTrimDB + safetyTrimDB`.
5.  `isInstalled` is true whenever at least one profile is stored, even with every
    switch off. The tap then runs a chain of zero sections, which is a preamp-only
    gain, or unity when the preamp is also zero. This keeps per-profile toggles free of
    transport work.

**Clipping.** A positive filter gain raises the signal at those frequencies; the preamp
is broadband attenuation sized by the profile author to offset it. The safety trim
measures the combined *peak response* and attenuates only when the authored preamp is
insufficient. This is an estimate of steady-state gain and does not bound transient
overshoot, so it reduces clipping risk rather than eliminating it. For a well-formed
AutoEQ profile the authored preamp already covers the peak, `safetyTrimDB` is 0, and the
profile is reproduced exactly as authored.

### 4. Handing parameters to the render thread

The render thread must not allocate, must not trigger ARC traffic, and must not hold a
lock for long. Therefore:

*   The runtime owns a fixed-capacity `[EQFilterParam]` plus `count`, `preampDB` and an
    `Int32` generation, all behind an `os_unfair_lock`.
*   Writers build the replacement array outside the lock, then assign and bump the
    generation inside it.
*   `copyParameters` copies at most `EQMaximumSections` POD elements and the scalar
    preamp into the caller's buffer under the lock, then returns the generation. The
    critical section copies a few hundred bytes and does no ARC work, because
    `EQFilterParam` contains only `Int32` and `Double`.
*   The processor compares the returned generation with its own. Unchanged means it
    does nothing. Changed means it recomputes coefficients into preallocated storage.

Coefficient computation on the render thread happens at most once per toggled buffer:
13 sections cost roughly 13 `sin`/`cos`/`sqrt` calls, in the order of 1–2 µs against an
11.6 ms budget at 512 frames and 44.1 kHz. There is no allocation.

The runtime never needs the sample rate. The processor does, and only in `prepare`.

### 5. Sample processing

New file: `Sources/Data/EQDSP.swift` (same file as the maths).

```swift
final class EQAudioProcessor {
    /// Both callbacks run off the render thread, before and after a render cycle.
    func prepare(format: AVAudioFormat, source: EQParameterSource)
    func unprepare()
    /// In-place processing of one render quantum.
    func process(buffers: UnsafeMutablePointer<AudioBufferList>, frameCount: Int)
}
```

A **render quantum** is the block of frames one callback receives, typically 512–1024
frames, so roughly 12–23 ms at 44.1 kHz. That is the real delay the user feels when
flipping a switch.

*   Accepts `Float32`, non-interleaved (the normal case for `AVPlayer`) and interleaved.
    Anything else sets a passthrough flag and leaves the buffer untouched.
*   Per channel, per section: transposed direct form II, two history values. Direct
    form II stores two values instead of four; the transposed arrangement has lower
    round-off for the same transfer function, which is why it is the default for
    real-time code.
*   Storage: coefficient buffer and state buffer are allocated once in `prepare`, sized
    `EQMaximumSections` and `EQMaximumSections * channels * 2`. They are never resized,
    so a profile with more filters than the one present at prepare time cannot overrun
    them; the extra sections are ignored and counted.
*   Inner loop:
    `y = b0*x + z1; z1 = b1*x - a1*y + z2; z2 = b2*x - a2*y`, `Double` throughout,
    `Float` cast once per sample at the end.
*   Coefficients are read into local `Double`s per section to keep the loop tight.
*   Denormal guard: after updating, `if abs(z) < 1e-30 { z = 0 }`. Double denormals
    begin near 1e-308, so this only clears state that has fully decayed and cannot
    stall the render thread on a decaying tail.

### 6. Audio integration

Modified: `Sources/Data/QobuzStreamPlayer.swift`.
New: `Sources/Data/EQAudioTap.swift`.

```swift
enum EQAudioMixFactory {
    static func makeAudioMix(for track: AVAssetTrack,
                             source: EQParameterSource) -> AVAudioMix?
}
```

`makeAudioMix` creates the tap with `kMTAudioProcessingTapCreationFlag_PostEffects`
(with `import MediaToolbox`), stores a retained `EQTapBox` (the processor plus the
parameter source) as client info, and binds it to the track with
`AVMutableAudioMixInputParameters(track:)`. If `MTAudioProcessingTapCreate` fails, the
retained box is released and the function returns `nil`, so the item plays unprocessed.
`eqTapPrepare` receives an `AudioStreamBasicDescription` and builds an `AVAudioFormat`
from it; a construction failure leaves the processor in passthrough.
`eqTapProcess` calls `MTAudioProcessingTapGetSourceAudio` and returns without touching
the buffer when the status is not `noErr`.

**Attach timing.** There is no `async`/`await` in this project, so this uses GCD:

*   For a `fileURL` asset (a downloaded track), tracks load from disk immediately, so
    the mix is attached synchronously before the item is inserted.
*   For a remote asset, `asset.tracks(withMediaType: .audio)` runs on
    `DispatchQueue.global(qos: .userInitiated)` and the mix is assigned back on the main
    queue, guarded by `item === currentItem || item === preloadedItem`.
*   `preload(url:)` has a 30-second lead (`PlaybackController.swift:48`), so the mix is
    in place long before the item becomes current. CUJ 5 holds.
*   `play(url:)` keeps its current immediate-start behaviour, so the very first item of
    a session may render a few buffers before the mix lands. Playback start latency is
    not traded for this, because a metadata round-trip on the start path risks the
    locked-screen behaviour the transport was built around.

**Install-state changes.** `EQChainRuntime.installStateDidChange` is posted when the
stored-profile count crosses zero. Each `QobuzStreamPlayer` observes it with
`NotificationCenter` (the same idiom already used for interruptions at
`QobuzStreamPlayer.swift:80`), and re-attaches a mix to its current and preloaded
items. A notification, not a closure, because two `QobuzStreamPlayer` instances exist
(`PlaybackController.swift:26`, `QobuzStreamTestViewController.swift:8`) and a single
closure would be overwritten by the second one. Per-profile toggles never post it.

### 7. Persistence

New file: `Sources/Data/EQProfile.swift` (store lives beside the model).

```swift
final class EQProfileStore {
    static let shared: EQProfileStore
    init(defaults: UserDefaults = .standard, key: String = "Music.EQ.profiles.v1")
    private(set) var profiles: [EQProfile]
    func add(_ profile: EQProfile)
    func remove(id: String)
    func setEnabled(_ enabled: Bool, id: String)
    var hasProfiles: Bool { get }
}
```

*   JSON array under `Music.EQ.profiles.v1` in `UserDefaults`, matching the existing
    preference style in `QobuzPreferences.swift:5-14`. The `v1` suffix is the schema
    version.
*   Every mutation re-encodes, writes, then calls `EQChainRuntime.shared.update`.
    A failed decode is logged and treated as an empty library.
*   `init` calls `update` immediately, so `EQChainRuntime.isInstalled` is correct on
    first use after launch without any `AppDelegate` priming.

### 8. Settings UI

Modified: `Sources/UI/Screens/SettingsViewController.swift`.
New: `Sources/UI/Components/EQProfileCell.swift`,
`Sources/UI/Screens/EQProfileEditorViewController.swift`,
`Sources/UI/Screens/EQProfileDetailViewController.swift`.

`SettingsViewController` gains `init(..., eqStore: EQProfileStore = .shared)` so tests
inject a suite-scoped store. The existing call site at `RootViewController.swift:441`
needs no change.

**Section layout**, inserted between the Qobuz group and Scrobbling:

*   Section label "Parametric EQ" via the existing `sectionLabel(_:)`.
*   `eqTable`: a non-scrolling `UITableView` styled exactly like `tabsTable` (border,
    corner radius, `backgroundColor = pageBackground`, `separatorColor = separator`),
    `rowHeight = 44`, height constraint `max(44, rows * 44)`.
*   `eqGroup`: the existing `configure(group:)` box holding an "Add Profile…" button
    (existing `style(actionButton:title:)`) and a guidance label.
*   Guidance: "Applies to Qobuz playback on this device. Enabled profiles combine; each
    switch adds its filters and preamp."

Exactly two existing constraints change: `scrobblingSection.topAnchor` moves from
`qobuzGroup.bottomAnchor` to `eqGroup.bottomAnchor` (line 214), and the new
`eqSection`/`eqTable`/`eqGroup` constraints are added in the same
`NSLayoutConstraint.activate` block. `scrobblingGroup.bottomAnchor` keeps terminating
the content chain.

**Second table.** `SettingsViewController` is already the data source and delegate for
`tabsTable`, and `numberOfRowsInSection`/`cellForRowAt`/`canMoveRowAt`/`moveRowAt` are
written for it alone (lines 280–357). Each of those gains a `tableView === eqTable`
branch; `moveRowAt` and `canMoveRowAt` return false/do nothing for `eqTable`. Delete is
`tableView(_:trailingSwipeActionsConfigurationForRowAt:)` with one destructive action.

**Cell.** `EQProfileCell` is a new class rather than a reuse of `SettingsTabCell`:
`SettingsTabCell` hard-codes a drag handle and `selectionStyle = .none`
(`SettingsTabCell.swift:51,54`), and EQ rows must be tappable and must not look
reorderable. It reuses the same fonts, colours and switch metrics.
`configure(name:subtitle:enabled:)`; subtitle format is
`"<n> filter(s) · Preamp <±x.x> dB"`, with `" · <m> skipped"` appended when
`skippedLines` is non-empty and `" · <k> off"` when enabled filters are fewer than
total.

**Empty state.** `numberOfRowsInSection` returns `max(profiles.count, 1)`; the single
placeholder row reads "No profiles loaded" and is not selectable.

**Editor.** A modal `UINavigationController`-wrapped VC: name field, monospaced
paste area, a "Paste" button that inserts `UIPasteboard.general.string`, Cancel and
Save. Save parses; on `EQParseError` it shows a `UIAlertController` with
`errorDescription` and stays open; on success it calls back with a new
`EQProfile(id: UUID().uuidString, ..., isEnabled: true)` and dismisses.

**Detail.** A read-only table: one row per filter formatted
`"<n> · <KIND> <fc> Hz · <gain> dB · Q <q>"` (or `S <s>`), dimmed and suffixed "OFF"
when the filter is disabled, followed by a section listing skipped lines verbatim.

**Refresh.** `refreshEQProfiles()` reloads `eqStore.profiles`, updates the height
constraint and reloads, called from `viewWillAppear` (beside `refreshQobuz()`) and after
every mutation.

Accessibility identifiers: `settings.eq.table`, `settings.eq.add`,
`settings.eq.guidance`, `eq.editor.name`, `eq.editor.text`, `eq.editor.save`,
`eq.editor.cancel`, `eq.detail.table`.

### 9. Wiring

No change to `RootViewController`, `PlaybackControlling`, or `QobuzPlaybackController`.
The store mutates the runtime directly and the runtime notifies players. The Settings
screen owns its own refresh.

### 10. Tests

New file: `Tests/EQTests.swift`, plus additions to `Tests/SettingsTests.swift`.

*   **Parser**: the exact CUJ 1 profile — preamp `-2.0`, 13 filters, filter 1 `LSC`
    60 Hz `Q 0.70`, filter 6 `isEnabled == false`, filter 13 gain `-6.1`; comments,
    CRLF, mixed case, reordered keys; `BW Oct 1.0` → `Q ≈ 1.41421`; `LS … S 1.0`;
    unknown kind and `GraphicEQ:` land in `skippedLines` while other filters parse;
    `Channel: all` is accepted; `Channel: L` throws `.unsupportedChannel`; blank text
    throws `.emptyInput`.
*   **Biquad**: `PK` magnitude at `Fc` equals its gain within 1e-6 dB; `LSC` approaches
    its gain at 20 Hz and 0 dB near 18 kHz; every kind is finite at DC and just below
    Nyquist; poles inside the unit circle for the CUJ 1 filters at 44.1, 48 and 96 kHz;
    a filter at or above Nyquist returns `nil`.
*   **Chain/runtime**: two enabled profiles sum their preamps; a disabled profile
    contributes nothing; `peakGainDB` is ≈ 0 for CUJ 1 and positive for a `+9 dB`
    profile with no preamp so the safety trim becomes negative; an all-`OFF` profile
    yields `count == 0` and unity gain; more than `EQMaximumSections` filters truncate.
*   **Processor**: a sine through a `PK` cut loses exactly its gain (a cut needs no
    headroom trim, so the measured change is the filter's own gain); a bare `+6 dB`
    boost measures as unity because the safety trim absorbs it; a zero-section unity
    chain leaves samples bit-identical; a parameter update between buffers changes the
    output with no NaN, no Inf, and no overrun past the state buffer; stereo planar
    input keeps per-channel state independent.
*   **Store**: round-trip through `UserDefaults(suiteName:)`; `setEnabled` and `remove`
    persist; corrupt JSON yields an empty library.
*   **Tap factory**: a small WAV written to a temporary file with `AVAudioFile` produces
    a non-`nil` `AVAudioMix` whose first input parameter has an `audioTapProcessor`.
    This is the only check that the MediaToolbox plumbing actually links and constructs
    on the target OS.
*   **Settings**: the `settings.eq.add` button exists; with an injected store holding
    one profile, the table shows one row and toggling its switch persists `isEnabled`.

### 11. Files touched

| File | Change |
| :--- | :----- |
| `Sources/Data/EQProfile.swift` | new — model, parser, store, errors |
| `Sources/Data/EQDSP.swift` | new — coefficients, magnitude, processor |
| `Sources/Data/EQChainRuntime.swift` | new — composition, headroom, shared parameters |
| `Sources/Data/EQAudioTap.swift` | new — `MTAudioProcessingTap` callbacks and mix factory |
| `Sources/Data/QobuzStreamPlayer.swift` | modified — attach mixes, observe install state |
| `Sources/UI/Components/EQProfileCell.swift` | new — name, subtitle, switch |
| `Sources/UI/Screens/EQProfileEditorViewController.swift` | new — paste editor |
| `Sources/UI/Screens/EQProfileDetailViewController.swift` | new — parsed inspector |
| `Sources/UI/Screens/SettingsViewController.swift` | modified — EQ section, delegate branches |
| `Tests/EQTests.swift` | new |
| `Tests/SettingsTests.swift` | modified — EQ section assertions |
| `Music.xcodeproj/project.pbxproj` | modified — new files in the app and test target |

**Build system note.** `ios/Music/project.yml` is the XcodeGen source of truth and both
targets use directory globs (`sources: - path: Sources`, `- path: Tests`), so a
regeneration picks new files up automatically. `xcodegen` is not installed on this
machine, so `project.pbxproj` is edited by hand, consistently with the globs, and the
file remains valid for both paths.

## Alternatives Considered

### Alternative A: `AVAudioEngine` with `AVAudioUnitEQ`

*   **Pros**: built-in EQ node, easy live parameter changes, no C callbacks.
*   **Cons**: `AVAudioEngine` cannot consume an `AVPlayerItem`; `AVAudioPlayerNode` needs
    local PCM, so every track would be downloaded and decoded before playback. That
    destroys streaming, the 30-second preload hand-off, and background resilience.
*   **Reason for Rejection**: incompatible with the existing transport.

### Alternative B: A second playback path on `AVAudioEngine` for downloads only

*   **Pros**: clean DSP graph.
*   **Cons**: covers only offline tracks, duplicates queue/preload/lock-screen
    behaviour, and creates two transports to keep in sync.
*   **Reason for Rejection**: duplicate transport, high regression risk.

### Alternative C: Volume automation approximation

*   **Pros**: no DSP at all.
*   **Cons**: cannot shape frequency response.
*   **Reason for Rejection**: does not meet the goal.

### Alternative D: A third-party DSP library

*   **Pros**: less code.
*   **Cons**: the maths is about 100 lines; the careful part is the Equalizer APO
    dialect, which no small library matches closely enough to avoid a wrapper.
*   **Reason for Rejection**: dependency cost exceeds the benefit.

--------------------------------------------------------------------------------

## Non-Functional Requirements

### Performance

A direct-form II section costs about 5 multiplies and 4 adds per sample. At 44.1 kHz
stereo with the 13 sections of CUJ 1 that is roughly 1.1 M sample-sections per second,
about 10 MFLOP/s. The `EQMaximumSections` ceiling of 64 sections at 96 kHz stereo is
about 55 MFLOP/s. Both are well within budget; the ceiling exists to keep a pathological
profile from renting the CPU forever.

No allocation, no logging and no Objective-C message sends inside `process`.

### Reliability

*   Any tap or mix construction failure degrades to unprocessed audio, never to silence
    or a crash.
*   A format the processor does not understand leaves the buffer untouched.
*   A profile that fails to parse never loses the profiles already stored.

### Compatibility

*   iOS 12.0 deployment target (`project.yml:6`): no async/await, no `Task`, no APIs
    newer than iOS 12. `MTAudioProcessingTap` is iOS 6, `os_unfair_lock` is iOS 10.
*   Schema version is in the storage key, so a later format can migrate explicitly.

### Rollout & Rollback

The feature is inert until a profile exists. Deleting every profile stops further mixes
from being attached. Rollback removes the Settings section and the attach call sites;
stored profiles are inert JSON.

--------------------------------------------------------------------------------

## Limitations and Known Risks

*   **AirPlay**: EQ runs inside the app process. On an AirPlay route the tap may never
    run or its output may be discarded, so the correction is not guaranteed. The
    Settings guidance says EQ applies on this device (Open Question 1).
*   **First item of a session**: because the mix is attached asynchronously, the very
    first item after launch or after the first profile is added may render briefly
    unprocessed. Preloaded items and all subsequent items are covered.
*   **Enabling the first profile mid-track**: attaching a mix to an item already
    rendering is not documented to take effect immediately (Open Question 2); it is
    guaranteed from the next item.
*   **Sample rate**: coefficients follow the format the tap reports, which is the
    format AVFoundation delivers after its own processing, not necessarily the stream's
    encoded rate. This is the correct rate for the DSP regardless.
*   **Toggle transient**: a toggled profile takes effect at the next buffer and resets
    biquad state, which can click at high gain. The stored history belongs to the old
    coefficients, so discarding it is the safer of the two options.
*   **Preamp-only profiles**: a profile with a preamp and no filters attenuates; a
    profile with neither does nothing. Both are represented by a zero-section chain.
*   **Clipping**: the safety trim is a steady-state estimate and cannot guarantee the
    absence of transient overshoot.
*   **24/192 streams**: the maths is sample-rate independent, but 192 kHz playback with
    EQ enabled has not been measured on a device (Open Question 2 covers the adjacent
    uncertainty).

--------------------------------------------------------------------------------

## Review Resolution (EGM resolve phase)

Six zero-context Goldfish reviewers audited this document against the live source.
Dispositions:

| # | Finding | Disposition |
| :-- | :--- | :--- |
| 1 | Non-`async` deployment target: async `loadTracks` and `Task` cannot compile at iOS 12.0 | **Accepted** — §6 rewritten to GCD; iOS 12 constraint stated in NFR Compatibility |
| 2 | `project.yml` is XcodeGen and globs `Sources`, so hand-editing `project.pbxproj` conflicts with generation | **Partially accepted** — `xcodegen` is not installed, so the pbxproj is edited by hand and the glob note records both paths |
| 3 | Filter state allocated in `prepare` can be overrun when a later snapshot has more sections | **Accepted** — fixed `EQMaximumSections` capacity; excess truncated and reported |
| 4 | Mix attached after `play()` guarantees an unprocessed burst, contradicting CUJ 5 | **Accepted, scoped** — local files attach synchronously, remote files attach at preload time with 30 s of lead; CUJ 5 narrowed to preloaded items, caveat stated for the first item |
| 5 | `os_unfair_lock` section performs an ARC retain/release on the render thread | **Accepted** — parameter handoff is now a POD copy, no ARC, fixed capacity |
| 6 | `snapshot(sampleRate:)` claims main-thread construction but the rate is only known in `prepare` | **Accepted** — the runtime no longer holds coefficients; the processor computes them in `prepare` and only recomputes on a generation change |
| 7 | Safety trim does not bound time-domain overshoot; the "0 dBFS" claim is false | **Accepted** — claim downgraded to reduced clipping risk, mechanism explained |
| 8 | Empty-section chain drops the preamp | **Accepted** — chain always applies the preamp |
| 9 | `onInstallStateChanged` closure would be overwritten by the second `QobuzStreamPlayer` | **Accepted** — replaced with a `NotificationCenter` broadcast |
| 10 | No launch priming of the runtime, so taps are never installed after relaunch | **Accepted** — `EQProfileStore.init` primes the runtime; no `AppDelegate` change |
| 11 | §9's `settingsController?.refreshEQProfiles()` does not exist | **Accepted** — §9 deleted; the Settings screen owns its own refresh |
| 12 | Renaming the `AVPlayerItem` audio mix mid-render is unproven | **Accepted** — recorded as Open Question 2 and a caveat |
| 13 | `LS`/`HS` are slope-parameterised, not Q-parameterised; aliasing them miscomputes | **Accepted** — separate `LS`/`HS` kinds with the slope form of alpha |
| 14 | `Channel: L`/`R` would be folded into both ears | **Accepted** — any non-`all` value refuses the profile |
| 15 | Persisted `dateAdded`/`sourceText` unused; `replace`/`hasProfiles` superfluous | **Partially accepted** — `dateAdded` and `replace` dropped; `sourceText` kept for inspection |
| 16 | Eight filter kinds and `BW Oct` exceed the request | **Partially accepted** — kinds cut to five; `BW Oct` kept because it is three lines and appears in real AutoEQ output |
| 17 | Second table needs delegate branching; row height and cell reuse claims were wrong | **Accepted** — §8 names the delegate methods, the two changed constraints, and why `SettingsTabCell` is not reused |
| 18 | FLOP figures were wrong by roughly 10× | **Accepted** — recomputed from a stated per-section cost |
| 19 | New `EQProfileCell` / detail screen are unnecessary | **Rejected** — `SettingsTabCell` hard-codes a drag handle and non-selectable style; the detail screen exists so the user can verify what was parsed, which is the request's acceptance test |

### Implementation-time findings

Two defects were found while wiring and verifying the build, both fixed:

1.  `eqAddButton` was added without
    `translatesAutoresizingMaskIntoConstraints = false`, so its frame collapsed to
    zero inside the EQ group. Caught by a layout test that compared real frames; the
    add button now measures 85 × 32 at the group's 10 pt inset.
2.  `EQProfileCell` hid its switch for the empty-state row but did not restore it in
    `prepareForReuse`, so a recycled cell could render a stored profile without a
    switch. The empty state now goes through a dedicated `configureAsPlaceholder`.

A third change followed from the tests: the interleaved path clamps the buffer's
`mNumberChannels` to the prepared channel count, because the per-channel state buffer
is sized from the format and must never be indexed past it.

