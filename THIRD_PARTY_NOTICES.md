# Third-Party Notices

This project is distributed under the GNU General Public License, version 3.0.
See [`LICENSE`](LICENSE) for the full text.

## Qobine

The Qobuz streaming protocol implemented in
`ios/Music/Sources/Data/QobuzStreamingClient.swift` is a Swift port of the
protocol used by [Qobine](https://github.com/SofusA/qobine), including
web-player app-ID/secret discovery, request signing, and the signed `/file/url`
stream-URL flow.

- Project: Qobine — `https://github.com/SofusA/qobine`
- Copyright: the Qobine contributors
- License: GNU General Public License, version 3.0

A verbatim copy of the Qobine GPL-3.0 license text is included in this
repository as [`QOBINE_GPL-3.0.txt`](QOBINE_GPL-3.0.txt) and is bundled into the
app resources alongside this notice.

## Qobuz service

This app is an unofficial client. It is not affiliated with, endorsed by, or
supported by Qobuz. Qobuz catalog data, artwork, and audio streams are the
property of their respective rights holders and are provided by Qobuz under a
paid Qobuz subscription. You are responsible for complying with the Qobuz terms
of service.

The Qobuz endpoints used here are undocumented and may change without notice.

## Apple frameworks

The app links only against Apple system frameworks (UIKit, AVFoundation,
Network, and Foundation). No third-party binary dependencies are vendored.
