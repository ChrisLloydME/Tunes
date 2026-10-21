# Samply integration

See [Architecture.md](Architecture.md) for the overall directory layout, state ownership, and call flows. This document focuses on Samply integration contracts. The coordinator lives in `Tunes/App/SamplyBackend.swift`; web and REST implementations live in `Tunes/Samply/Web/` and `Tunes/Samply/REST/` respectively.

## Components

| Component | Responsibility |
| --- | --- |
| SamplyBackend | Native observable state, session/account changes, navigation tasks, project-creation ownership, and upload entry point |
| SamplyWebSession | One app-owned WKWebView, sign-in window, authorization pop-ups, and versioned JavaScript calls |
| Resources/SamplyBridge.js | Sole adapter for undocumented web contracts |
| PlaybackController | Transport controls, playback state, MPRemoteCommandCenter / Now Playing |
| SamplyAPI | Official REST requests and error mapping; project creation; bounded backoff retries for GET |
| ProjectCreationCoordinator | Single POST /projects operation, confirmed-result retention, artwork/file stages, and Library-only refresh |
| SamplyUploader | Upload tickets, streamed file PUTs, visible single-file progress, and the awaitable ordered uploads used by creation |
| FileTokenStore | Account-bound plaintext credentials in Application Support; 0700 directory, 0600 file, excluded from backups; no Keychain or preferences access |
| MemoryTokenStore | In-process credentials for isolated tests |

API `GET /projects` **lists owned projects only**, so it cannot represent the complete Library. The full Library and playback therefore use the authenticated web session. PATs are used only for the official API: project creation, token validation, and original-file uploads. The two credentials remain independent; web account changes clear the old PAT.

The web adapter returns explicit Codable snapshots without authentication tokens. Swift passes arguments through `callAsyncJavaScript(arguments:)`; resource IDs are not interpolated into executable scripts. The bridge installs only in the `https://samply.app` top-level document.

## Inspected web contracts

Samply's public build `index.1817c5c9.js` and its LibraryView, useFilesStore, FileView, player, audio, and sign-in modules were inspected on 2026-10-17 and rechecked on 2026-10-20. The adapter accesses the Vue application's Pinia stores:

- `profile-auth-module`: real account UID / anonymous state.
- `library`: web Library items and upload permissions.
- `player`: current share identity, authorized project/player context, and playback options.
- `boxes`: current level, playable files, versions, folders, and processing state.
- `audio-module`: the same loadBox call as official FileView, preserving its player, project, queue, quality, and loudness options. Samply continues to own audio URLs, transcoding, gapless playback, and permissions.
- `audio-shaka-module`: Samply normally synchronizes its media-element clock through `requestAnimationFrame` calls to `opts.ontimeupdate`. Animation frames may stop while the app's WebKit window is hidden. When snapshot polling observes a media-time change, it invokes the same update entry point, preserving Samply's track-relative time and gapless transitions without estimating progress with a native timer or reading streaming URLs.

Track readiness requires both `player.playerBoxesLoading === false` and `boxes.loadingBoxes === false`, matching share/folder identities, and view models for the current level. `boxes.loadingBoxes` may become false immediately after selecting player mode, before the `playerBoxes` subscription or request returns; checking only that flag would misreport an initial empty array as an empty album. The album page displays empty content only after confirmed readiness. Its loading indicator appears after 350 milliseconds, so fast loads show tracks directly.

The public player route is `/p/:shareid`, but an external player link can carry a different path identity plus a `token` query containing the share identity. The player view resolves that token and rewrites the route to the live share ID. The adapter now sends the documented `playerUrl` path and token together, waits for the resolved player share and project identity, and accepts an empty box array only after both loading flags and the view-model array are ready. The previous readiness check required the input path identity to equal the live share ID, which could reject a newly propagated or tokenized project link.

The public source also shows why an empty project is representable without a dummy file: the project-owned player subscription sets `playerBoxesLoading = false` and publishes an empty `playerBoxes` array; the files store then sets `loadingBoxes = false` for player mode, and its current-level view-model computed property returns an empty array. Tunes therefore renders a normal empty album after a confirmed read rather than treating emptiness as loading failure. `WebSnapshot.hasLoadedBoxes` additionally checks the expected project ID whenever one is available, so a route match cannot accept stale content from another project.

These are not stable public APIs. The implementation checks for required objects/methods and bounds navigation and selection with deadlines and identity checks. Website updates may require changes to this single adapter. Isolated tests establish local contract handling, not real-account end-to-end Samply compatibility.

Samply's official Projects API documents project `artwork` as read-only and lists no artwork write field for project creation or update. Tunes therefore sends no invented REST artwork field. Public project-settings source uses the website's upload store with `writeback: "project"`, `isSystem: true`, and a system upload filtered from visible project files; that is the authorized artwork contract used by Samply itself, not an ordinary visible project file. The adapter constructs the image as a browser `File` from bounded base64 data, checks that the account is the owner or an admin/editor, waits for the upload callback, then server-reads the project document and confirms that its `artwork` value changed. If the contract, upload store, project read, or confirmation is unavailable, the adapter returns an explicit unsupported or submitted/uncertain result. No PAT is passed to JavaScript.

Toolbar and menu actions share the current page target: Library, album, or folder. Refresh uses the adapter's `refreshPage` to read data without reloading the WebView, resetting the player store, or invoking audio operations, preserving the current track, position, and queue. The existing list remains visible during requests. Library refresh reuses this build's Firestore `getDocsFromServer` to read the current user's unarchived history, including shared projects. Owned/editable albums reread project boxes; read-only shared players use Samply's `getSecurePlayerBoxContent`. These read-only exports are tied to public build `index.1817c5c9.js`; incompatible builds or permissions fail directly without reading authentication SDKs, tokens, or passwords or trying alternative access paths. Password-protected shared content may require checking access in the existing Samply window. Results are discarded if the page or account changes before completion. `navigatePage` uses the existing Vue router to open the Library, album, or folder, then shows the same Samply window.

Errors occupy only an SF Symbol warning icon in the toolbar. Click it for details, retry, or the corresponding Samply page. After status-read failures, polling uses 250 milliseconds for the first 10 seconds before returning to 700 milliseconds; errors still appear only after 5 seconds of continuous failure. Transient operation errors trigger read-only recovery for the current page, backing off from 250 milliseconds to at most 2 seconds and cancelling on page changes or recovery. Recovery never replays play, pause, seek, or upload operations and never reloads the WebView. Explicit rejections, permission errors, invalid arguments, and known contract changes are not retried as transient errors. Healthy snapshots clear stale transient playback errors and resolved player errors.

Version access follows the web player's configuration: other versions are available only when versions are enabled or the project role is owner/admin/editor. By default, only the stack's current version plays. The app does not change sharing, download, or version permissions. Creating a project does invoke Samply's documented server-side side effect: `POST /projects` also creates a project-scoped player using the account's default player options. Tunes does not send player-option overrides and does not make a separate player-creation request.

## Sign-in

The app currently uses its own Samply web sign-in only, with separate Debug and Release WebKit containers. There are no browser extensions, bookmark scripts, session imports, or local receivers, and no inbound-network or local-network permission requests.

Email sign-in has a native link field. `SamplyEmailSignInLink` only converts input to a URL without checking its domain, path, or sign-in parameters; the website handles Outlook / Gmail and other email-provider redirects. `SamplyWebSession.openEmailSignInLink` navigates the existing WebView, preserving the email state stored when Samply sent the email. It does not pre-request or consume a one-time code or call internal authentication SDK exports. Submitted input is cleared immediately and never written to app settings or logs. Samply decides link validity and sign-in success. Navigation failures use fixed messages to avoid exposing URLs containing sign-in codes.

Default-browser sign-in accepts official Samply authorization only. See [AuthenticationDesign.md](AuthenticationDesign.md) for the complete user flow and external dependencies. An official API OAuth result does not establish a web-player session, so the unavailable entry point is not shown.

Handle Samply sessions only. Do not integrate native Apple authorization or read Apple identity, browser profiles, or passwords.

## REST, project creation, and uploads

The official base URL is `https://samply.app/api/v0`. API sessions do not store cookies or caches and reject redirects to prevent forwarding bearer credentials. GET retries 429/502/503/504 responses within a bounded limit; POST requests for project creation and upload tickets are not automatically replayed.

Project creation sends `POST /projects` with a JSON body containing only `name`. The documented response is a project object plus `playerUrl`. As a documented server-side side effect, Samply also creates a project-scoped player using the account's default player options and includes all files currently in the project. Tunes does not send upload, sharing, download, version, collaborator, or upload-portal settings and does not make a separate player-creation request.

Artwork and files added after creation are optional and staged independently. Artwork is validated and downsampled natively, then assigned through the adapter contract described above; no REST artwork field is sent. Files retain their selection order and are uploaded one at a time through the existing upload-ticket POST and streamed storage PUT path. Uploads start from the confirmed project ID without waiting for album or player navigation, and completed files are retained when a later file fails. The creation sheet exposes per-file progress, cancellation, retry for definite failures, and an explicit uncertain outcome for ambiguous ticket or PUT failures. A successful PUT means Samply received the original bytes, not that asynchronous processing has finished.

The POST is never automatically retried. A timeout, connection loss, cancellation, 5xx response, or malformed success response is treated as ambiguous because Samply may already have created the project. The creation sheet explains that possibility and directs the user to refresh the complete Library before another attempt.

After a confirmed creation, `ProjectCreationCoordinator` refreshes the complete authenticated web Library through the adapter's `refreshPage` path, including shared projects, rather than replacing it with `GET /projects`. Creation stays on Library: it does not automatically open the new project. The confirmed project and its `playerUrl` path plus share token are retained for any later explicit open, and the refreshed Library item is the fallback identity. A confirmed result survives later refresh failures and no second Create action is offered. Account and operation identity are captured before the request; sign-out or account changes discard stale completions. Creation never reloads the WebView or resets playback. Files selected on the post-creation file step upload from the confirmed project ID, and the sheet returns to Library when the user starts or finishes that step.

Uploads use `URLSession.upload(for:fromFile:)` from disk with the officially required Content-Type and x-goog-meta-destination/projectid/boxpath headers. Storage sessions carry no PAT or cookies and do not follow redirects. The selected file's security scope lasts until upload completion; size and modification time are checked before PUT begins.

Not implemented: project deletion, resumable uploads, system background transfers, failed-ticket cleanup, general batch uploads outside the creation sheet, native decoding, offline downloads, live comments, and collaboration editing. Successful PUT confirms original-data submission only; Samply's asynchronous processing may still be pending.

## Verification boundaries

- Unit tests: real URLSession with URLProtocol-simulated API/storage, covering paths, authentication, models, project creation, original-file tickets, upload completion, cancellation, errors, retries, and file-backed token restoration, permissions, account isolation, and removal using temporary directories. Isolated coordinator tests cover blank names, duplicate submissions, complete-Library refresh, Unicode names, playerUrl token routing, project identity, empty results, refresh failure and explicit opening, ordered and partial file uploads, cancellation, artwork outcomes, ambiguous mutations, and stale account completions. Artwork tests cover downsampling, bounded inputs, stale selection invalidation, and absence of temporary copies.
- Node protocol tests: simulate Vue/Pinia contracts confirmed from the public source, covering shared Library content, controls, track selection, tokenized empty-project navigation, project identity, artwork writeback capability, version permissions, stale state, and errors.
- Acceptance does not use Computer Use or UI tests. Real-account end-to-end verification is performed manually by the user with instructions provided in chat.

## Sources

- [Samply API introduction](https://docs.samply.app/api/introduction.html)
- [Samply Authentication](https://docs.samply.app/api/authentication.html)
- [Samply Projects](https://docs.samply.app/api/projects.html)
- [Samply Files](https://docs.samply.app/api/files.html)
- [Kaset architecture reference](https://github.com/sozercan/kaset/blob/main/docs/architecture.md): persistent WebKit playback with separate native state. The Library album grid and floating player layout are also adapted from Kaset; see [ThirdPartyNotices.md](ThirdPartyNotices.md) for provenance and the MIT license.

## Profile display cache

`SamplyProfileCache` stores only account display metadata and avatar image bytes in the app's UserDefaults domain. Debug and Release bundle identifiers keep these caches separate. The sidebar can show this metadata during session restoration; it never establishes authentication or enables playback. Confirmed sign-out and explicit sign-out clear the cache. Account or avatar URL changes discard old image data. Default avatars use Samply's name initials and UID-based color algorithm. No credentials enter this cache.
