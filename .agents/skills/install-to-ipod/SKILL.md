---
name: install-to-ipod
description: Build, sign and install the Music iOS app onto the connected iPod touch (iOS 12.5.8) with the Qobuz credentials baked in. Use when asked to install, sideload, deploy or update the app on the physical iPod, or when Xcode claims it cannot use the device because of a missing Developer Disk Image.
---

# Install the Music app on the iPod touch

This repo's app targets iOS 12.0 and is tested on an iPod touch 6th generation. Xcode 26
cannot deploy to it, so device installation uses `ideviceinstaller` from libimobiledevice
instead. This skill is the whole procedure, including the three traps that silently
produce a broken or duplicate install.

Everything below was verified on 2026-10-27 against the real device.

## When to use

*   "Install it on the iPod", "sideload it", "update the app on the iPod".
*   Xcode reports `Could not locate Developer Disk Image for this device`.
*   `xcrun devicectl` fails with `does not support acquiring a usage assertion`.
*   You need a build that is already signed in to Qobuz on first launch.

## Hard facts

| | |
| :--- | :--- |
| Device | iPod touch 6th gen (`iPod7,1`), iOS 12.5.8 |
| Legacy UDID | `<device-udid>` — from `idevice_id -l` |
| CoreDevice id | `<coredevice-udid>` — from `xcrun devicectl list devices` (unusable on iOS 12) |
| **Installed bundle id** | **`com.fletcher.MusicPrototype.<TEAM_ID>`** — not the project's `com.fletcher.MusicPrototype` |
| Team | `<TEAM_ID>` — your own Apple Developer team id |
| Signing identity | `Apple Development: <you@example.com> (<CERT_ID>)` |
| Toolchain | Xcode 26.x, SDK `iphoneos26.5`, deployment target 12.0 |

Two consequences that drive the whole procedure:

1.  **Xcode cannot run or debug on iOS 12.5.8.** There is no Developer Disk Image for it.
    That blocks *launching*, not *installing*. Do not abandon the install because Xcode
    or `idevicedebug` complains about the DDI.
2.  **The app on the device uses a suffixed bundle id** because it was first installed
    through Splice, which registered `com.fletcher.MusicPrototype.<TEAM_ID>` as an
    explicit App ID. Installing the unsuffixed id creates a **second** app and orphans
    the existing Keychain credentials.

## Preflight

`/opt/homebrew/bin` is not on the default `PATH` for non-interactive shells, so plain
`which ideviceinstaller` reports nothing even though it is installed. Always export it
first, or every check below will look like a missing dependency.

```sh
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH

which ideviceinstaller idevice_id ideviceinfo idevicesyslog idevicecrashreport
idevice_id -l                                  # expect 40c00a8d…
ideviceinfo -k ProductVersion                  # expect 12.5.8
ideviceinstaller list | grep -i music          # expect the suffixed bundle id
```

If `idevice_id -l` is empty: the iPod is unplugged, locked, or has not been trusted.
Ask the user to unlock it, plug it in, and tap **Trust This Computer**. Pairing records
live in `/var/db/lockdown`; if that directory is empty, trusting has not happened.

## Procedure

### 1. Confirm the bundle id to replace

Never assume. Read it from the device:

```sh
ideviceinstaller list | grep -i music
```

*   Non-empty → use that exact id, so the new build replaces the app in place and keeps
    its Keychain entry, downloaded tracks and settings.
*   Empty → the app is not installed yet. Use `com.fletcher.MusicPrototype.<TEAM_ID>` to
    stay consistent with previous installs, or the project's own id for a clean first
    install.

### 2. Build for the device

```sh
cd /Users/fletcher/code/prod/remaster

xcodebuild \
  -project ios/Music/Music.xcodeproj \
  -scheme Music \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/Music-Device-Build \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=<TEAM_ID> \
  CODE_SIGN_STYLE=Automatic \
  PRODUCT_BUNDLE_IDENTIFIER=com.fletcher.MusicPrototype.<TEAM_ID> \
  build
```

Wait for `BUILD SUCCEEDED`. `-allowProvisioningUpdates` lets Xcode mint or refresh the
profile; it needs a signed-in Apple ID in Xcode and network access.

**Ignore these lines.** They are expected and do not affect installation:

```
An error occurred whilst preparing device for development
Could not locate Developer Disk Image for this device
== Underlying device preparation errors ==
```

### 3. Verify the build before touching the device

```sh
APP=/tmp/Music-Device-Build/Build/Products/Release-iphoneos/Music.app

/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Info.plist"

security cms -D -i "$APP/embedded.mobileprovision" > /tmp/prof.plist
/usr/libexec/PlistBuddy -c "Print ProvisionedDevices" /tmp/prof.plist \
  | grep -c <device-udid>     # must print 1
/usr/libexec/PlistBuddy -c "Print ExpirationDate" /tmp/prof.plist
```

If the device count is `0`, stop: the profile does not cover this iPod and the install
will fail. The likely cause is that the iPod is not registered in the developer portal.
The prior session solved that by registering through Splice; Xcode cannot do it for a
device it refuses to prepare.

### 4. Bake in the Qobuz credentials

The app imports `QobuzPersonalCredentials.json` from its own bundle at launch, once per
`importID` (`QobuzPersonalCredentialImport`, `Sources/Data/QobuzStreamingClient.swift`).
The file is git-ignored and is **not** in the project's Resources build phase, so a plain
build has no credentials.

```sh
cp ios/Music/QobuzPersonalCredentials.json "$APP/"
```

If that file is missing, ask the user to run the sign-in helper, which owns the OAuth
flow and writes the file. Do not ask them for a token in chat:

```sh
python3 tools/qobuz-signin.py
```

### 5. Re-sign with the build's generated entitlements

The copy in step 4 invalidated the signature, so sign again. **Use the `.xcent` file, not
`ios/Music/Music.entitlements`.**

```sh
XCENT=/tmp/Music-Device-Build/Build/Intermediates.noindex/Music.build/Release-iphoneos/Music.build/Music.app.xcent
IDENT=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')

codesign --force --sign "$IDENT" --entitlements "$XCENT" --timestamp=none "$APP"
codesign --verify --deep --strict "$APP" && echo SIGNATURE_OK

codesign -d --entitlements :- "$APP" | grep -A2 application-identifier
```

The last command must show real values, not build variables:

```
application-identifier : <TEAM_ID>.com.fletcher.MusicPrototype.<TEAM_ID>
keychain-access-groups : <TEAM_ID>.com.fletcher.MusicPrototype.<TEAM_ID>
get-task-allow         : true
```

### 6. Install

```sh
ideviceinstaller install "$APP"
```

Expect a progress run ending in `Install: Complete`. On success the app is replaced in
place; on failure `ideviceinstaller` prints the device's own error text.

### 7. Verify

```sh
ideviceinstaller list | grep -i music
```

Check for a fresh crash from the new build:

```sh
rm -rf /tmp/ipod-crashes && mkdir -p /tmp/ipod-crashes
idevicecrashreport -u <device-udid> /tmp/ipod-crashes
find /tmp/ipod-crashes -iname "Music*" -newermt "-10 minutes" | head
```

`idevicecrashreport` pulls the device's crash logs without a Developer Disk Image, so it
is the only automated way to tell whether the new build crashes on launch.

**You cannot launch the app from the command line.** `idevicedebug run <bundle-id>` fails
with *"Please make sure to mount the developer disk image first"*, and `xcrun devicectl`
does not support iOS 12 (`pairingState: unsupported`). Ask the user to tap the app icon,
then optionally stream its log:

```sh
idevicesyslog -p Music
```

## Traps, and why each step exists

| Trap | Symptom | Why |
| :--- | :--- | :--- |
| Using the project's bundle id | Two Music icons; Qobuz signed out | iOS treats a different CFBundleIdentifier as a different app; Keychain access groups do not carry across |
| Re-signing with `Music.entitlements` | Signature verifies, app fails to use Keychain | That file still contains `$(AppIdentifierPrefix)` and `$(PRODUCT_BUNDLE_IDENTIFIER)`; `codesign` embeds the literal strings. The `.xcent` has them expanded |
| Forgetting `export PATH=/opt/homebrew/bin:$PATH` | `ideviceinstaller: command not found` | Non-interactive shells do not inherit the Homebrew prefix |
| Trusting Xcode's DDI error | Concluding the device is unsupported | The DDI gates launch and debug only; installation works |
| Deleting the app to "refresh" signing | Lost downloads, lost sign-in | Replacing in place preserves the container and Keychain |
| Running `xcrun devicectl` | `does not support acquiring a usage assertion` | CoreDevice targets iOS 17+; this device is iOS 12 |

## Re-installing after signing expires

Free-account development signing expires after 7 days. Re-run steps 2–7; step 3 prints the
new expiry date.

Do not uninstall first. The container holds the offline downloads and the Keychain holds
the Qobuz session.

## Common errors

| Error | Cause | Fix |
| :--- | :--- | :--- |
| `Could not locate Developer Disk Image` (during build) | iOS 12.5.8 has no DDI for Xcode 26 | Ignore; it does not block installation |
| `Could not start com.apple.debugserver!` | Same missing DDI | Do not try to launch programmatically; the user taps the icon |
| `Install: Failed` with a device error code | Profile does not include the UDID, or entitlements mismatch | Re-check step 3 and confirm step 5 used the `.xcent` |
| `idevice_id -l` prints nothing | Locked, unplugged, or untrusted | Unlock, reconnect, tap **Trust This Computer** |
| Profile for the suffixed id cannot be created | The explicit App ID is missing from the portal | The Splice-registered id `com.fletcher.MusicPrototype.<TEAM_ID>` should already exist; otherwise install under the project id instead |

## Do not

*   Do not use `xcrun simctl` for this device — that is the simulator only.
*   Do not hand-edit `Music.xcodeproj/project.pbxproj` to add credentials as a resource.
    Copy them into the built `.app` (step 4) so the project stays clean for other clones,
    and never commit `QobuzPersonalCredentials.json`.
*   Do not put Apple account credentials or tokens in chat. The sign-in helper and the
    bundle import both avoid that.
*   Do not assume the bundle id from `project.yml`; always read it off the device first.
