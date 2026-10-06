Qobuz streaming spike notice
============================

The Swift Qobuz streaming client in this application is a port/adaptation of
streaming protocol implementation from SofusA/qobine, primarily
qobuz-client/src/client.rs and qobuz-client/src/qobuz_models.rs.

Upstream project: https://github.com/SofusA/qobine
Upstream license: GNU General Public License, version 3 (GPL-3.0)
Upstream copyright: Copyright (C) Qobine contributors

The port was adapted for this iOS app on 2026-07-11. The corresponding upstream
license text is available at https://github.com/SofusA/qobine/blob/main/LICENSE
and must be included with any distribution of this adapted code. This notice is
not legal advice. Review GPL-3.0 distribution and source-availability duties
before conveying this application.

This spike implements only the Qobuz OAuth code exchange, web-player app ID and
regional signing-secret discovery, signed MP3 file-URL request, and AVPlayer
smoke-test UI. The included QOBINE_GPL-3.0.txt is the complete corresponding
license text. Qobuz may change these undocumented interfaces; account/service
terms and playback authorization are separate from the source-code license.
