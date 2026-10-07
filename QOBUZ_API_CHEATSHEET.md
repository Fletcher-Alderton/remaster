# Qobuz API Request Cheat Sheet (Qobine Reference)

This document records the Qobuz-facing requests found in `qobine/qobine/qobuz-client` and the player code that calls it. Treat Qobine as an implementation reference, not an official or stable Qobuz API specification: these endpoints are undocumented and may change.

## Important catalog lesson

Qobine does **not** call `artist/getFeatured` or `album/getFeatured`.

- Discovery is loaded from `GET /discover/index` (and genre playlists from `GET /discover/playlists`).
- Grouped catalog search is `GET /catalog/search`.
- An artist detail page is `GET /artist/page`.

This directly explains the reported `Invalid Method given (getFeatured)` response: Qobuz does not expose that method in Qobine’s request set. Do not infer a supported endpoint just from the `artist/...` naming pattern.

## Hosts and common request construction

- API base: `https://www.qobuz.com/api.json/0.2/`
- Web player base: `https://play.qobuz.com`
- Artwork artist host: `https://static.qobuz.com`
- API GET calls put parameters in the URL query string.
- API form POST calls use `reqwest` `.form(...)` (URL-encoded form fields).
- API JSON POST calls use `.json(...)` (JSON request body).
- Responses are checked for HTTP success and then deserialized as JSON into Qobine’s Rust models.
- The API client uses a cookie-enabled `reqwest::Client`.

### Common API headers

`client_headers()` sets these headers on normal API requests:

| Header | Value / rule |
|---|---|
| `X-App-Id` | Current Qobuz web-player app ID. |
| `X-User-Auth-Token` | User token for ordinary Qobuz tokens. |
| `Authorization` | `Bearer <token>` instead of `X-User-Auth-Token` when Qobine detects a delegated JWT (three `.` characters). |
| `Access-Control-Request-Headers` | `x-app-id,x-user-auth-token`. |
| `Accept-Language` | `en,en-US;q=0.8,ko;q=0.6,zh;q=0.4,zh-CN;q=0.2`. |
| `X-Session-Id` | Added to the session-based `/file/url` stream request only. |

OAuth code exchange has the app ID header but no user token yet. Do not copy Qobine’s debug logging of credential values; never log auth tokens, OAuth codes, or signed URLs.

## Web player bootstrap and OAuth

| Step | Request | How Qobine uses it |
|---|---|---|
| Discover OAuth app ID and stream secrets | `GET https://play.qobuz.com/login` | Extracts the current versioned `/resources/.../bundle.js` path from the login HTML. |
| Read web-player configuration | `GET https://play.qobuz.com{bundle-path}` | Parses the current app ID and per-timezone streaming secrets from the JavaScript bundle. The bundle path changes with web-player releases. Qobine caches the parsed configuration and refreshes it when the bundle changes. |
| Start browser login | Open `https://www.qobuz.com/signin/oauth?ext_app_id={app_id}&redirect_url=http://localhost:{port}` | A temporary localhost listener receives the authorization redirect. Qobine accepts the `code_autorisation` value returned by the browser flow. This is browser navigation, not a normal API JSON call. |
| Exchange OAuth code | `GET /oauth/callback?code={code}&private_key={oauth-private-key}` | Adds `X-App-Id`; no user token is available yet. Response supplies `token` (or `user_auth_token`) and `user_id`. Qobine keeps the private-key value in source; this cheat sheet intentionally does not reproduce it. |

The source uses the current web-player bundle rather than treating an app ID or stream secret as permanent. Do not hardcode captured bundle secrets in the app.

## Catalog, discovery, artists, and search

| Purpose | Method and path | Parameters/body used by Qobine |
|---|---|---|
| Discovery/editorial sections | `GET /discover/index` | `genre_ids={genre-id}`. Qobine sends an empty string when no genre is selected. The response contains editorial containers such as new releases, Qobuzissims, ideal discography, album of the week, most streamed, press awards, playlists, and playlist tags. |
| Genre list | `GET /genre/list` | No query parameters. |
| Playlists for genre/tags | `GET /discover/playlists` | `genre_ids={id-or-empty}`, `tags={tag-or-empty}`, `offset=0`, `limit=20`. |
| Search all result types | `GET /catalog/search` | `query={search-text}`, `limit={limit}`. Response groups albums, artists, playlists, and tracks. Qobine player calls it with limit `20`. |
| Album detail and tracks | `GET /album/get` | `album_id={album-id}`, `extra=track_ids`, `offset=0`, `limit=500`. |
| Artist detail | `GET /artist/page` | `artist_id={artist-id}`, `app_id={app-id}`, `sort=relevant`. Includes artist profile information, portrait metadata, biography, and top tracks. |
| Artist releases | `GET /artist/getReleasesList` | `artist_id={artist-id}`, `limit={limit}` (default `100`), `release_type={album-or-epSingle-or-live-or-compilation}`, `sort=release_date`, `offset=0`, `track_size=1`. Qobine requests albums, EPs/singles, live releases, and compilations separately. |
| Similar artists | `GET /artist/getSimilarArtists` | `artist_id={artist-id}`, `limit={limit}` (default `10`), `offset=0`. |
| Suggested albums | `GET /album/suggest` | `album_id={album-id}`. |

The `release_type` alternatives above are separate calls, not a combined value: use one of `album`, `epSingle`, `live`, or `compilation` per request.

### Notes for the iOS app

- Qobine uses one grouped `catalog/search` call, while the current iOS client fans out to `album/search`, `artist/search`, and `track/search`.
- Qobine's discovery request is `discover/index`, not `album/getFeatured` / `artist/getFeatured`. It returns editorial containers rather than a standalone featured-artist endpoint. The iOS app's current approach of deriving artists from featured album artists avoids the unsupported call, but `discover/index` is the stronger reference for a fuller discovery page.
- Qobine loads artist profiles with `artist/page` and separately requests release categories and similar artists. That response supplies portrait `hash`/`format` metadata; Qobine builds the portrait URL as described below.

## Tracks and recommendations

| Purpose | Method and path | Parameters/body used by Qobine |
|---|---|---|
| Track detail | `GET /track/get` | `track_id={track-id}`. |
| Fetch tracks by IDs | `POST /track/getList` | JSON body `{ "tracks_id": [ ... ] }`. Qobine chunks IDs into batches of at most 50 and concatenates returned `tracks.items`. |
| Dynamic track suggestion | `POST /dynamic/suggest` | JSON body described below. Before posting, Qobine fetches details for up to the last five queue IDs using `/track/get`. |

Dynamic suggestion JSON shape:

```json
{
  "limit": 50,
  "listened_tracks_ids": [123, 456],
  "track_to_analysed": [
    {
      "track_id": 456,
      "artist_id": 42,
      "genre_id": 7,
      "label_id": 9
    }
  ]
}
```

`artist_id`, `genre_id`, and `label_id` are optional fields; `track_id` is required. The analyzed list is built from the last five queue tracks, while `listened_tracks_ids` contains the full queue passed to the method.

## User favorites and playlists

| Purpose | Method and path | Parameters/body used by Qobine |
|---|---|---|
| Read favorites | `GET /favorite/getUserFavorites` | `limit={limit}`; the player requests `1000`. Response groups albums, artists, and tracks. |
| Add favorite track | `POST /favorite/create` | Form `track_ids={track-id}`. |
| Remove favorite track | `POST /favorite/delete` | Form `track_ids={track-id}`. |
| Add/remove favorite album | `POST /favorite/create` or `/favorite/delete` | Form `album_ids={album-id}`. |
| Add/remove favorite artist | `POST /favorite/create` or `/favorite/delete` | Form `artist_ids={artist-id}`. |
| Add/remove favorite playlist (subscribe/unsubscribe) | `POST /playlist/subscribe` or `/playlist/unsubscribe` | Form `playlist_id={playlist-id}`. |
| List user playlists | `GET /playlist/getUserPlaylists` | `limit=500`, `extra=tracks`, `offset=0`. |
| Read playlist | `GET /playlist/get` | `limit=500`, `extra=tracks`, `playlist_id={playlist-id}`, `offset=0`. |
| Create playlist | `POST /playlist/create` | Form `name`, `is_collaborative`, `is_public`, and `description`. Qobine forces `is_collaborative=false` for a private playlist. |
| Delete playlist | `POST /playlist/delete` | Form `playlist_id={playlist-id}`. |
| Add playlist tracks | `POST /playlist/addTracks` | Form `playlist_id={playlist-id}`, `track_ids={comma-separated-track-ids}`. |
| Delete playlist tracks | `POST /playlist/deleteTracks` | Form `playlist_id={playlist-id}`, `playlist_track_ids={comma-separated-playlist-track-ids}`. These are playlist-entry IDs, not catalog track IDs. |
| Reorder playlist track | `POST /playlist/updateTracksPosition` | Form `playlist_id={playlist-id}`, `playlist_track_ids={playlist-entry-id}`, `insert_before={index}`. |

## Playback URL resolution and stream requests

Qobine has two stream-URL paths. Both use the selected Qobuz format ID: MP3 `5`, CD `6`, Hi-Res 96 `7`, Hi-Res 192 `27`.

### Session-based segmented stream

1. When its cached session is absent or expired, Qobine makes:

   `POST /session/start`

   URL-encoded form fields:

   ```text
   profile=qbz-1
   request_ts={unix-timestamp}
   request_sig={md5-signature}
   ```

   The signature helper sorts the supplied parameters by name, concatenates each `key + value`, then hashes `sessionstart + concatenated-args + timestamp + RNG_INIT` with MD5. The response contains `session_id`, `expires_at`, and optionally `infos`.

2. Resolve a stream URL:

   `GET /file/url?request_ts=...&request_sig=...&track_id=...&format_id=...&intent=stream`

   Also sends `X-Session-Id`. Its signature uses method name `fileurl` and the sorted `format_id`, `intent`, and `track_id` parameters with the same timestamp/`RNG_INIT` algorithm.

3. The response contains a `url_template` and segment metadata (and may contain an encryption key/blob). Qobine substitutes segment indices into the template and downloads audio segments with direct HTTP GETs, starting by fetching segment `0` to parse the initialization data. These are media requests to the returned URL, not calls to the Qobuz JSON API.

### File-based stream URL

`GET /track/getFileUrl?request_ts=...&request_sig=...&track_id=...&format_id=...&intent=stream`

This uses `X-App-Id` and the user token, but no `X-Session-Id`. Qobine computes the MD5 from the method/parameter string plus timestamp and the active web-player secret; its source assembles the string as:

```text
trackgetFileUrlformat_id{format-id}intentstreamtrack_id{track-id}{unix-timestamp}{active-secret}
```

Qobine probes the discovered per-timezone secrets against a known MP3 track and keeps the first secret that returns a valid URL. The response supplies a direct media URL, format metadata, and optionally a blob. It then opens that URL as an HTTP stream (with range/partial reads handled by its streaming library) and caches completed stream bytes locally.

### Playback reporting

| Purpose | Method and path | Body |
|---|---|---|
| Report stream start | `POST /track/reportStreamingStart` | URL-encoded form field `events` containing a JSON array with `track_id`, UTC epoch `date`, `user_id`, and `format_id`. |
| Report stream end | `POST /track/reportStreamingEndJson` | JSON `{ "events": [...], "renderer_context": { "software_version": "..." } }`. Each event has `blob`, `track_context_uuid`, `start_stream`, `online`, `local`, and `duration`. Qobine expects a JSON response with `status="success"`. |

## Qobuz Connect token requests

These are also posted to the API base, using the ordinary authenticated form POST builder:

| Purpose | Method and path | Form body |
|---|---|---|
| Create Connect token | `POST /qws/createToken` | `jwt=jwt_qws` |
| Refresh delegated API token | `POST /qws/refreshToken` | `jwt=jwt_api`; response wraps `jwt_api` with a JWT and expiry. |

A delegated token is sent as `Authorization: Bearer ...` by Qobine; an ordinary user token uses `X-User-Auth-Token`.

## Artwork URL construction

Artwork is not fetched from a `getFeatured` endpoint. Catalog responses provide album/artist image fields, and Qobine maps them as follows:

- Album and ordinary artist search results: use the image URLs returned in the catalog payload (`small`, `large`, etc.); those are direct static-image URLs.
- Artist-page portrait: response gives `hash` and `format`; Qobine constructs `https://static.qobuz.com/images/artists/covers/large/{hash}.{format}`.
- The artwork GET itself is a direct unauthenticated static-image request, separate from the authenticated JSON API calls.

## Endpoint checklist (paths declared by Qobine)

All API paths below are under `https://www.qobuz.com/api.json/0.2/` unless stated otherwise. This list is derived from the `Endpoint` enum and the additional QWS/OAuth/web-player request code in Qobine:

```text
album/get
album/suggest
artist/page
artist/getReleasesList
artist/getSimilarArtists
catalog/search
discover/index
discover/playlists
dynamic/suggest
favorite/create
favorite/delete
favorite/getUserFavorites
file/url
genre/list
oauth/callback
playlist/addTracks
playlist/create
playlist/delete
playlist/deleteTracks
playlist/get
playlist/getUserPlaylists
playlist/subscribe
playlist/unsubscribe
playlist/updateTracksPosition
qws/createToken
qws/refreshToken
session/start
track/get
track/getFileUrl
track/getList
track/reportStreamingEndJson
track/reportStreamingStart
```

`/login` and the versioned web-player bundle are on `play.qobuz.com`; OAuth browser sign-in is on `www.qobuz.com/signin/oauth`; artwork and resolved audio use static/media URLs returned or constructed as described above.

## Source pointers in Qobine

- Request paths, parameter construction, headers, serialization, OAuth, web-player bundle parsing, and signatures: `qobine/qobine/qobuz-client/src/client.rs`
- API data types: `qobine/qobine/qobuz-client/src/qobuz_models/`
- Direct segment GET helper: `qobine/qobine/qobuz-client/src/stream.rs`
- Direct file-based media streaming: `qobine/qobine/qobuz-client/src/stream/file_based.rs`
- Artist-page and album/search image mapping: `qobine/qobine/controls-module/src/models/mapper.rs`
- Player workflows that compose album/search/artist/favorites/recommendation requests: `qobine/qobine/player-module/src/client.rs`
