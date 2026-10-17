# Samply integration

## Components

| Component | Responsibility |
| --- | --- |
| SamplyBackend | Native observable state, session/account changes, navigation tasks, and upload entry point |
| SamplyWebSession | One app-owned WKWebView, sign-in window, authorization pop-ups, and versioned JavaScript calls |
| Resources/SamplyBridge.js | Sole adapter for undocumented web contracts |
| PlaybackController | Transport controls, playback state, MPRemoteCommandCenter / Now Playing |
| SamplyAPI | Official REST requests and error mapping; bounded backoff retries for GET |
| SamplyUploader | Upload tickets, streamed file PUTs, progress, and cancellation |
| MemoryTokenStore | In-process credentials; no Keychain, file, or preferences access |

API `GET /projects` **lists owned projects only**, so it cannot represent the complete Library. The full Library and playback therefore use the authenticated web session. PATs are used only for the official API, primarily original-file uploads in the current UI. The two credentials remain independent; web account changes clear the old PAT.

The web adapter returns explicit Codable snapshots without authentication tokens. Swift passes arguments through `callAsyncJavaScript(arguments:)`; resource IDs are not interpolated into executable scripts. The bridge installs only in the `https://samply.app` top-level document.

## Inspected web contracts

On 2026-10-17, Samply's public build `index.1817c5c9.js` and its LibraryView, useFilesStore, FileView, audio, and sign-in modules were inspected. The adapter accesses the Vue application's Pinia stores:

- `profile-auth-module`: real account UID / anonymous state.
- `library`: web Library items and upload permissions.
- `player`: current share identity, authorized project/player context, and playback options.
- `boxes`: current level, playable files, versions, folders, and processing state.
- `audio-module`: the same loadBox call as official FileView, preserving its player, project, queue, quality, and loudness options. Samply continues to own audio URLs, transcoding, gapless playback, and permissions.
- `audio-shaka-module`: Samply normally synchronizes its media-element clock through `requestAnimationFrame` calls to `opts.ontimeupdate`. Animation frames may stop while the app's WebKit window is hidden. When snapshot polling observes a media-time change, it invokes the same update entry point, preserving Samply's track-relative time and gapless transitions without estimating progress with a native timer or reading streaming URLs.

These are not stable public APIs. The implementation checks for required objects/methods and bounds navigation and selection with deadlines and identity checks. Website updates may require changes to this single adapter. Isolated tests establish local contract handling, not real-account end-to-end Samply compatibility.

Version access follows the web player's configuration: other versions are available only when versions are enabled or the project role is owner/admin/editor. By default, only the stack's current version plays. The app does not change sharing, download, or version permissions or automatically create players.

## Sign-in

The app currently uses its own Samply web sign-in only, with separate Debug and Release WebKit containers. There are no browser extensions, bookmark scripts, session imports, or local receivers, and no inbound-network or local-network permission requests.

Email sign-in has a native link field. `SamplyEmailSignInLink` only converts input to a URL without checking its domain, path, or sign-in parameters; the website handles Outlook / Gmail and other email-provider redirects. `SamplyWebSession.openEmailSignInLink` navigates the existing WebView, preserving the email state stored when Samply sent the email. It does not pre-request or consume a one-time code or call internal authentication SDK exports. Submitted input is cleared immediately and never written to app settings or logs. Samply decides link validity and sign-in success. Navigation failures use fixed messages to avoid exposing URLs containing sign-in codes.

Default-browser sign-in accepts official Samply authorization only. See [AuthenticationDesign.md](AuthenticationDesign.md) for the complete user flow and external dependencies. An official API OAuth result does not establish a web-player session, so the unavailable entry point is not shown.

Handle Samply sessions only. Do not integrate native Apple authorization or read Apple identity, browser profiles, or passwords.

## REST and uploads

The official base URL is `https://samply.app/api/v0`. API sessions do not store cookies or caches and reject redirects to prevent forwarding bearer credentials. GET retries 429/502/503/504 responses within a bounded limit; upload-ticket POST requests are not automatically replayed.

Uploads use `URLSession.upload(for:fromFile:)` from disk with the officially required Content-Type and x-goog-meta-destination/projectid/boxpath headers. Storage sessions carry no PAT or cookies and do not follow redirects. The selected file's security scope lasts until upload completion; size and modification time are checked before PUT begins.

Not implemented: resumable uploads, system background transfers, failed-ticket cleanup, batch uploads, native decoding, offline downloads, live comments, and collaboration editing. Successful PUT confirms original-data submission only; Samply's asynchronous processing may still be pending.

## Verification boundaries

- Unit tests: real URLSession with URLProtocol-simulated API/storage, covering paths, authentication, models, original-file tickets, upload completion, cancellation, errors, retries, and in-memory tokens.
- Node protocol tests: simulate Vue/Pinia contracts confirmed from the public source, covering shared Library content, controls, track selection, navigation, version permissions, stale state, and errors.
- Acceptance does not use Computer Use or UI tests. Real-account end-to-end verification is performed manually by the user following manual verification instructions provided in chat.

## Sources

- [Samply API introduction](https://docs.samply.app/api/introduction.html)
- [Samply Authentication](https://docs.samply.app/api/authentication.html)
- [Samply Projects](https://docs.samply.app/api/projects.html)
- [Samply Files](https://docs.samply.app/api/files.html)
- [Kaset architecture reference](https://github.com/sozercan/kaset/blob/main/docs/architecture.md): persistent WebKit playback with separate native state. The Library album grid and floating player layout are also adapted from Kaset; see [ThirdPartyNotices.md](ThirdPartyNotices.md) for provenance and the MIT license.
