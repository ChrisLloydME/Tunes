# Tunes

Tunes is a native macOS client for browsing albums and listening to music from Samply. SwiftUI and AppKit provide the Library, album pages, and playback controls, while a persistent WKWebView uses Samply's own authentication and streaming player.

**Status: the connection layer and native interface are implemented. Email sign-in has been manually verified by the user. Playback, seeking, shared content, project creation with artwork and uploaded files, and uploads still need manual verification. Official authorization through the default browser is not yet available.**

## Run

Open `Tunes.xcodeproj` in Xcode, select the Tunes scheme, Debug configuration, and My Mac destination, then run.

- Debug bundle identifier: `com.lloydME.Tunes.beta`.
- Release bundle identifier: `com.lloydME.Tunes`.
- Debug and Release use separate WebKit website data stores.
- The minimum supported system is macOS 26.
- Personal access tokens are saved in a local plaintext file with restricted permissions, excluded from backups, and restored only for the matching Samply web account. Application code does not access the Keychain.

Click **Sign In to Samply** to open a sign-in sheet inside the current Tunes window. Close it with the close button or Escape; successful authentication dismisses it automatically. **Open in Samply** continues to open the independent Samply window. Both presentations share the background player's WKWebView. Reopening the sign-in sheet while signed out returns to the sign-in entry page; opening a pasted email link preserves that link's navigation. The independent player window retains its current page. The session is stored in the WebKit container for the corresponding build configuration.

For email sign-in, request the email from that window, copy the complete link from the email's sign-in button, and click **Paste Sign-In Link** in Tunes. Tunes reads the clipboard only when you click this button and opens the link immediately. For manual entry, expand **Enter link manually** in settings, or click the options button in the Samply window's floating glass capsule. Paste the link into the field and click **Continue Sign-In**. These controls are available in connection settings and the top of the sign-in window. The link opens unchanged in the existing Samply session so Samply can complete authentication. Redirect links from Outlook, Gmail, and other email providers are passed through unchanged, without inspecting their domain, path, or parameters.

The planned browser sign-in flow uses official authorization: Tunes starts authorization, the user confirms in the default browser, and the browser returns to Tunes. This entry point will become available only after Samply registers Tunes as a client and confirms a supported route to a complete Library and player session. See [Authentication design and integration requirements](Docs/AuthenticationDesign.md). The previous bookmark, script, and local receiver approaches have been removed.

## Code layout and architecture

- `Tunes/App`: app entry point, scenes, navigation shell, and `SamplyBackend` coordination.
- `Tunes/Features`: Library, album/folder browsing, playback, connection settings, and About UI.
- `Tunes/Samply`: WebKit/bridge integration, official REST/upload integration, authentication helpers, and shared errors.
- `Tunes/Resources`: the versioned JavaScript adapter and bundled third-party license.
- `TunesTests` and `Scripts`: Swift unit/network tests and Node bridge protocol tests.

These directories belong to one app target. See [Architecture and code navigation](Docs/Architecture.md) for dependencies, state ownership, key flows, and where to make changes; [Samply integration details](Docs/SamplyBackend.md) covers the external contracts.

## Implemented features

- Web account status, a persistent sign-in window, and authorization pop-ups.
- Email sign-in links opened in the existing WebKit session, including email-provider redirects.
- Web Library browsing, including owned projects and shared players.
- A Library sidebar with the signed-in Samply avatar and display name, and a Kaset-based album grid with artwork, title and artist search, and project details.
- Album detail pages adapted from Kaset, with artwork, artist, track count and duration, a Play action, numbered tracks, and folder browsing.
- Track versions in track menus, uploads in album menus, and playback bar components reused from Kaset.
- Track selection and streaming through Samply's own `audio-module.loadBox`, with play, pause, seek, volume, and previous/next controls.
- AAC and lossless options, with format and availability determined by Samply; quality changes preserve playback position.
- macOS Now Playing integration and media keys.
- Official REST integration for project creation, owned projects, project files, folders, stacks, signed download URL queries, and original-file upload tickets.
- Native project creation from Library using the documented `POST /projects` request, with optional artwork and optional files added after creation, followed by an automatic complete web Library refresh. The creation sheet returns to Library without opening the new project.
- Project artwork selection from Files or Photos with local validation and downsampling, assigned through Samply's authorized web upload path rather than an invented REST field.
- Original-file uploads directly from disk using PUT, preserving required `x-goog-meta-*` headers and Content-Type, with progress, cancellation, and error states. Files added after creation use an ordered, awaitable queue with per-file outcomes, surfaced in the sheet or a Library notice.
- Cleanup of native state, saved tokens, upload tasks, and the corresponding WebKit session when accounts change or the user signs out.

## Local signing

Tunes is currently built for local development and personal use with the owner's free Apple developer account (Personal Team). Debug, Release, and test targets all use automatic signing with `Apple Development` and the existing team `YM5G2M8PV9`. Release selects optimized code; it does not imply Developer ID distribution or notarization. Neither Developer ID signing nor notarization is part of this workflow.

Keep this signing policy for both Xcode and command-line builds. Do not override it with ad hoc signing (`CODE_SIGN_IDENTITY=-`), `CODE_SIGNING_ALLOWED=NO`, a different team, or a replacement certificate to make a build pass. Missing, expired, or inaccessible signing credentials are a build prerequisite failure, not permission to change identity. Report the failure and let the owner manage the existing Personal Team in Xcode. Do not automatically provision, create, revoke, import, or export certificates or modify Apple account credentials.

Xcode and Apple's signing tools may use the existing signing identity through their normal credential handling. Tunes application code must never access Keychain. Builds and hosted unit tests must use a temporary Derived Data directory and must not replace an installed app. Hosted tests may start their test host; UI tests and visual inspection remain prohibited. A change from an earlier ad hoc build can still cause macOS to request confirmation once; this policy does not guarantee the absence of future system prompts.

Debug remains `com.lloydME.Tunes.beta`; Release remains `com.lloydME.Tunes`, with separate app and WebKit storage.

References: [Apple developer account and Personal Team](https://developer.apple.com/help/account/basics/about-your-developer-account), [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/).

## Verification

Automated verification uses builds, unit tests, and protocol tests only. Repository documentation, comments, test descriptions, and app-owned text are maintained in English; user-provided names retain their original text.

```sh
xcodebuild -project Tunes.xcodeproj -scheme Tunes -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/TunesDerivedData \
  -only-testing:TunesTests -skip-testing:TunesUITests test
node --test Scripts/test-samply-bridge.mjs
```

Tests use fixture credentials in memory or temporary directories, plus simulated network and web objects. They do not sign in to real accounts, create real Samply projects, assign live artwork, or upload files to cloud storage. Manual verification instructions are provided in chat only. See [Samply backend](Docs/SamplyBackend.md) for architecture and outstanding work.
