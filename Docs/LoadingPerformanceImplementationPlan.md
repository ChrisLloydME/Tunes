# Loading performance and correctness implementation plan

Date: 2026-10-23. Application baseline: `7cefa55`. This is an implementation handoff, not a record of completed fixes.

## Objective and authority

Fix the previously reviewed one P1 and three P2 issues, then reduce startup-to-Library and album/folder navigation latency. The user reports these flows are substantially slower than the website. Measure authoritative content readiness separately from preview display and artwork completion.

This is the execution plan for the next implementing Agent. [LoadingLatencyDiagnosis.md](LoadingLatencyDiagnosis.md) preserves the supporting diagnosis and fixture evidence. If older proposals differ, use this plan and the latest human instructions, while preserving `AGENTS.md` requirements.

The implementing Agent runs through **Xcode Code Intelligence**. Discover and use Xcode's built-in build/test tools first. Do not assume the authoring chat's tool availability is the implementing Agent's tool availability. This authoring session exposed no Xcode build/test tool; that is not justification for the next Agent to choose shell builds.

The user permits real-account verification through ordinary user behavior. Existing Debug login state may be usable; do not assume it exists or is valid. This permission does not authorize stress tests, parallel real-account traffic, repeated sign-in, credential/session extraction, or destructive remote actions. Existing restrictions on UI automation remain applicable. Exact human verification procedures belong in chat, not repository checklists.

## Coverage and execution order

| Stage | Issue or finding | Required outcome | Dependencies |
| --- | --- | --- | --- |
| A0 | Validation prerequisites and missing latency baseline | Discover Xcode tools, confirm identity/isolation, preserve synthetic baseline | None |
| A1 | **P1:** native cancellation leaves JS requests active | Cancelled reads cannot overwrite newer web or native content | A0 |
| A2 | **P2:** REST GET deadline does not bound an active transfer | One absolute GET budget, including active requests and retry waits | A1 |
| A3 | **P2:** image callback backlog bypasses the byte bound | Bound retained response data before MainActor handoff | A2 |
| A4 | **P2:** value mutation still triggers Observation | Equal content produces no content notification | A3 |
| A5 | Missing route/data/publication phase timing | Bounded, correlated loading traces and distinct page metrics | A4 |
| A6 | Library readiness invisible to runtime; navigation gate and 2.1 s sweep | Prompt first Library publication through a scoped read | A5 |
| A7 | Album browse still returns the whole Library and always enters router path | Page-sized response and validated current-page fast path | A6 |
| A8 | Visited albums/folders are discarded | Bounded memory preview cache with fresh action validation | A7 |
| A9 | Repeated album derivation and clock-driven list invalidation | Content revision presentation; independent playback presentation | A8 |

Implement stages serially in reviewable increments. Run the focused checks after each increment and continue when they pass; a stage boundary is not a request for new user approval. Do not combine unfinished cancellation, DTO, cache, and UI-state changes into one large patch. Preserve existing user changes and untracked diagnosis files. Do not roll back someone else's work to obtain a clean baseline.

## Rules shared by every stage

- Read `AGENTS.md`, `README.md`, `Docs/Architecture.md`, `Docs/SamplyBackend.md`, and `Docs/AuthenticationDesign.md` first. Reconcile source anchors if the checkout changed.
- Keep one persistent WebKit player, the existing Samply authorization flow, shared-inclusive Library, hidden-window clock sampling, version/access restrictions, and account/session/selection guards. No download-based streaming fallback or native replacement player.
- Preserve PAT file storage, 0700 directory/0600 file permissions, backup exclusion, matching-account restoration, and deletion on sign-out/account change/removal. No application Keychain access, PATs in JavaScript/preferences/logs, or browser-profile/session imports. Open pasted email links unchanged and never log/persist them.
- Preserve project creation/upload phase uncertainty, credential revision binding, and no automatic POST/ticket/PUT replay. A timeout/cancellation cannot prove that remote work was undone.
- Keep WebKit/AppKit/observable state on MainActor. The project uses default MainActor isolation; an inherited `Task {}` does not move CPU or buffering work off that actor. Use explicit isolation and Sendable values, not unchecked annotations to silence diagnostics.
- Keep code, comments, repository documentation, test descriptions, and app-owned copy in English. Preserve user names verbatim.
- No new server, database, package hierarchy, generic Repository framework, guessed Samply exports, undocumented authentication calls, or sharing/download/version changes. Add small helpers where they make ownership and tests clearer.
- Tests of failure, cancellation, burst traffic, byte limits, and timeouts use fixtures only. Never reproduce adversarial cases against the logged-in account.

## A0 — Establish the permitted validation path and baseline

**Deliverable:** a short handoff record of tool capabilities, selected targets, source revision, baseline fixtures, and prerequisites. Do not add a repository manual-testing checklist.

1. Discover available Xcode Code Intelligence tools and read their schemas. Identify the open project/workspace, the Tunes scheme, Debug configuration, and macOS destination. Locate built-in build and hosted-unit-test selection tools.
2. Confirm automatic `Apple Development` signing and team `YM5G2M8PV9` for app/test targets. Debug is `com.lloydME.Tunes.beta`; Release is `com.lloydME.Tunes`. Preserve the separate WebKit store identifiers. Never rename a bundle or change identity to recover login state.
3. Use temporary Derived Data and do not replace an installed application. Run hosted `TunesTests` only; explicitly exclude `TunesUITests`. Do not invoke an all-tests tool unless its supported filtering guarantees UI tests are excluded. Do not launch the app interactively through an Agent tool or capture screenshots for validation.
4. If a built-in tool cannot satisfy a required constraint, such as safe test selection or temporary Derived Data, state the exact limitation before a command-line fallback. Do not bypass capable built-in tools, invoke repository build scripts instead, or request extra shell permissions for an equivalent build/test. Keep all signing restrictions in any fallback.
5. The previous authoring-chat hosted test attempt failed before compilation because the environment could not find the team's development signing certificate/private key. Check prerequisites in the implementing Xcode environment rather than assuming the same result. Missing/inaccessible credentials are reported; do not provision, create, revoke, import, or export certificates or modify Apple credentials. Never use ad-hoc signing or disable signing.
6. Preserve the existing hosted-test startup guard. Swift tests use injected transports, MemoryTokenStore/temporary token files, fake time, and simulated network objects. If a test needs a WebView, use an isolated/nonpersistent test store where practical; do not navigate a production Debug website store or clear the user's existing store. A cached login is not a unit-test fixture.
7. Run `Scripts/test-samply-bridge.mjs` and preserve `Scripts/diagnose-loading-latency.mjs` results. Run Node through an available suitable tool; if Xcode provides no Node/protocol runner, state that specific limitation before using `node --test Scripts/test-samply-bridge.mjs` and `node Scripts/diagnose-loading-latency.mjs`. This is distinct from choosing a shell app build.

**Known synthetic baseline:** Library loading → ready leaves runtime state unchanged; a 1,000-item Library/100-box browse maps 1,000 unrelated Library items and returns 229,378 bytes, versus 229,336 before the upgrade. The 5 ms synthetic readiness probe observed about 95 ms extra delay from 100 ms sampling in one run. These are not live-account latency numbers.

**Exit:** tool path and safety constraints are established; the existing fixture baseline is understood; build/test prerequisite failures are not mislabeled as source failures or passes. If hosted validation remains blocked, continue independent source/fixture work and explicitly leave the hosted acceptance gate open.

## A1 — Cancel the page operation, not just the native waiter

**Files:** `Tunes/Samply/Web/SamplyWebSession.swift`, `Tunes/Resources/SamplyBridge.js`, the shared-read helpers in `Tunes/App/SamplyBackend.swift`; bridge/coordinator/Node tests.

**Current defect:** `finishInvocation` calls `notifySuperseded` for `.timedOut` only. Normal cancellation removes the native continuation while an outstanding `refreshPage` can still replace `refreshedLibrary` or box documents. A later native snapshot can re-import that obsolete content.

Implement in this order:

1. Add a fixture regression: start read A, cancel A, finish newer read B, then finish A. Assert both the web store/next snapshot and native content retain B. The existing test that only completes an obsolete native transport callback is insufficient because it cannot observe JS mutations.
2. Expire the request ID for ordinary cancellation as well as timeout, while the request still belongs to the same live document. Do not send an old document's cancellation into a replacement document. Native continuation and deadline cleanup remain exactly once. Adjust existing "no extra request" assertions to distinguish one protocol `cancel` notification from a replayed business command; the browse/refresh operation itself must still occur only once.
3. Verify guards after asynchronous import/read/router boundaries and immediately before applying content. Expiry suppresses late results; it does not undo an already-started router/audio/server action. Keep automatic recovery read-only.
4. Preserve coalescing: cancelling one waiter releases only that waiter; cancelling the final waiter expires the shared operation. Recheck caller cancellation after a shared await before applying its result. A cancelled caller must not commit success because another caller kept the shared task alive.
5. Keep request lifecycle bookkeeping bounded without reactivating an unresolved expired operation when old IDs are evicted. Prefer lifecycle/deadline-scoped state; do not introduce an unbounded cancelled-ID log.

**Acceptance fixtures:** cancelled A late after successful B; A → B → A; one waiter cancelled while another succeeds; final waiter cancelled; success/cancellation/deadline races; old document callback; cancelled play load later completes without an automatic second load. No stale error may overwrite a newer success.

**Rollback boundary:** native expiry and JS guards are one coherent change. Do not ship mismatched semantics or disable cancellation to hide failures.

## A2 — Enforce an absolute REST GET deadline

**Files:** `Tunes/Samply/REST/SamplyAPI.swift`, `SamplyRESTRetryPolicy.swift`, and `TunesTests/SamplyAPIRetryTests.swift`.

**Current defect:** setting `URLRequest.timeoutInterval` limits inactivity, not total transfer duration. A response that keeps delivering data can exceed the caller's deadline; the session's resource timeout remains 60 seconds and success is returned without a final budget check.

1. Add a delayed/chunked URLProtocol or transport fixture that exceeds the caller's budget while continuing to deliver data. It must demonstrate prompt failure and actual task cancellation, not merely assert the configured timeout value.
2. Use an operation-wide monotonic deadline that can settle the GET waiter and cancel its active URLSession task. Include every attempt and backoff wait. Do not rely only on a check after `data(for:)` returns; that cannot release an overdue active request. An exactly-once callback/continuation boundary is acceptable. Avoid a structured race that still waits for a noncooperative child on exit.
3. Recompute remaining time before each attempt/wait, never round a small remainder upward into another full attempt, and reject an overdue success. Propagate caller cancellation promptly and cancel deadline work on normal completion.
4. Preserve three maximum GET attempts, the 429/502/503/504 status allowlist, explicit transient transport classification, and numeric/date `Retry-After`. Never shorten the server-requested cooldown. If it will not fit, return the typed HTTP error and its delay.
5. Keep POST/ticket/PUT replay and timeout/uncertainty semantics unchanged. Keep cookie/cache isolation, host checks, no credential forwarding on redirects, and captured credentials. Do not recreate a new URLSession for each retry as a shortcut.

**Acceptance fixtures:** continuously arriving chunks; never-completing task; success just before/after deadline; cancellation during request/backoff; server delay longer than budget; exhausted attempts; terminal 401/403/decode/certificate failures; project/ticket POST still happens at most once; upload-phase outcomes unchanged.

## A3 — Bound image data before actor handoff

**Files:** `Tunes/Samply/Web/BoundedHTTPDataLoader.swift`, `TunesTests/BoundedHTTPDataLoaderTests.swift`; touch artwork/profile callers only if the interface requires it.

**Current defect:** each chunk is captured into a separate MainActor task before the byte check runs. A slow consumer can accumulate an arbitrarily large callback backlog relative to the configured limit. The code also appends before checking and accepts further queued chunks after marking the response oversized.

1. Add a multi-chunk fixture with delayed consumer handoff and counters for retained buffer bytes/pending deliveries. A final `.tooLarge` assertion alone is insufficient. Use a controlled handoff seam rather than busy-waiting or blocking the main thread.
2. Keep receive buffering and remaining-capacity checks on a controlled serial delegate/worker path. Do not enqueue one unbounded Data-capturing MainActor task per chunk. Hand off a bounded terminal result to MainActor.
3. Check whether a chunk fits before appending. Once oversized/cancelled/finished, reject further chunks without accumulating them. Cancel the data task and settle the continuation exactly once. Content-Length may enable early rejection but is not trusted as the byte bound.
4. Preserve 8 MiB artwork and 2 MiB avatar limits, existing request/resource timeouts, HTTPS/cookie/PAT isolation, redirect policy, and typed outcomes. The bound is on application-retained response data, not a claim that total process RSS or the network stack can never allocate another byte.
5. Keep ordinary artwork coalescing/cancellation and the four-transfer limit working. No real oversized response, burst, or hostile image test is performed against Samply.

**Acceptance fixtures:** unknown or false Content-Length; large single chunk; many small chunks; data/completion/cancellation races; delayed handoff; multiple transfers; non-200 response; retained data stays within the configured bound, including after terminal failure. Existing avatar cooldown and artwork tests remain passing.

## A4 — Put equality before the observable mutation boundary

**Files:** `Tunes/Samply/Web/SamplyContentAcceptance.swift`, `Tunes/App/SamplyBackend.swift`, `TunesTests/StateAcceptanceTests.swift`.

**Current defect:** calling a mutating method on the observed value-type `content` enters its generated `_modify` accessor. Observation emits willSet/didSet even when the inner equality guard returns early. Assignment counters do not measure this notification.

1. Add `withObservationTracking` coverage for actual Library and boxes observation through the backend/production content owner. Re-arm tracking for independent cases; checking a helper's integer counters is not enough.
2. Either compare before entering the observed property's mutation accessor or introduce a small reference content owner with independently observed Library and box fields, assigned only on change. Keep diagnostics counters observation-ignored. Do not merely add Equatable to the outer struct and assume mutating access becomes silent.
3. Preserve full-field equality, order, empty-loaded versus loading state, account/route guards, and creation's in-place identity updates. Ensure monitor, scoped reads, explicit refreshes, and creation callbacks use the same acceptance semantics.
4. Library observers must not fire for an equal Library or a boxes-only change; box observers must not fire for an equal level or Library-only change. Actual field changes still notify.

**Acceptance fixtures:** identical input has zero further notifications; rename/artwork/access/processing/version/order changes notify appropriately; account clear notifies; ready empty albums stay representable. This is the foundation for A9, not a general backend rewrite.

## A5 — Trace the user-visible critical path

**Files:** `Tunes/Samply/Web/SamplyDiagnostics.swift`, `SamplyWebSession.swift`, `Tunes/App/SamplyBackend.swift`, `Tunes/Resources/SamplyBridge.js`; focused diagnostics tests.

1. Keep existing bounded aggregate counters and add opt-in Debug operation traces with a maximum of 128 operations and a small fixed maximum number of stages per operation. Retain command/category and operation correlation. Provide sanitized, developer-readable output; do not collect all application or WebKit logs.
2. Startup stages: requested, document committed/finished, adapter usable, authentication resolved, web Library ready, payload decoded, native content published. Navigation stages: selected, bridge started, router settled, matching boxes ready, response built, decoded, published. Include cache/current-page hit/miss later.
3. Record fixed categories, opaque local operation IDs, counts, bytes, outcomes, and durations only. No account/resource names or IDs, URLs, headers, PATs, email links, bodies, or arbitrary exception strings. Do not put real page identifiers into signpost names or export files.
4. Use monotonic time within each process. Correlate JS and native intervals via the local operation ID; do not subtract raw JS `performance.now()` from native uptime. Native model publication is not proof of a drawn frame or audible playback.
5. Fixtures distinguish delayed routing from delayed data readiness and native post-ready overhead. Use 5 warmups/30 measurements for synthetic timing only, with informational wall-clock median/p95 and deterministic count/byte gates. Do not repeat real-account navigation 30 times to populate a percentile.

**Exit:** the implementing Agent can explain which interval dominates a trace. No claim of faster startup is based solely on smaller background snapshots. A normal-use real sample can be inconclusive; report the sample count and missing intervals.

## A6 — Publish first Library content promptly

**Files:** `Tunes/Resources/SamplyBridge.js`, `Tunes/Samply/Web/SamplyWebModels.swift`, `SamplyWebSession.swift`, `SamplyPollSchedule.swift`, `SamplyTiming.swift`, `Tunes/App/SamplyBackend.swift`, and focused tests. Make the DTO, scheduler, and acceptance changes in separate substeps.

1. Add explicit Library readiness to runtime state and its invalidation identity. If account/route stay unchanged and Library becomes ready just after a complete read, schedule one immediate Library read. A false → true transition must not wait for the 2.1-second content sweep.
2. Add an additive `librarySnapshot` command and `WebLibrarySnapshot` carrying version, authentication/account, readiness, Library items, and only necessary capability evidence. It maps no boxes and samples no unrelated playback. Existing full snapshots and creation's complete server refresh keep their contracts.
3. Update all command integration points: Swift/JS dispatch, Codable decoding/version validation, feature readiness/error mapping, diagnostics category, and the deadline policy. Classify `librarySnapshot` as a status read with the existing five-second native bound. Old fixtures/runtime payloads without the new optional readiness field remain decodable; absence is not proof of ready or signed out.
4. Store accepted Library readiness tied to the current account/session. Do not keep `backend.libraryReady` dependent solely on `web.snapshot` after moving to scoped reads, and do not construct fake full snapshots with empty boxes to reuse old code.
5. Separate allowed-document identity and adapter/store readiness from `webView.isLoading`. Permit a guarded read when the current main document is Samply and the adapter is actually usable, even before unrelated navigation completion. Keep generation/version/origin checks. Missing globals are transient; incomplete authentication is `.checking`.
6. During bootstrap only, use a bounded 100–200 ms lightweight readiness cadence for at most 10 seconds or an equivalent verified event. Stop on first content, terminal failure, sign-out, or a replacement document. This is local store observation, not repeated server refresh. Keep normal steady-state runtime/media-clock sampling and failure backoff.
7. Treat stored-PAT revalidation as potential background contention, not a proven serial blocker. Defer it until first content/explicit creation intent only if A5 demonstrates material interference; write authorization still requires complete proof. Do not remove proof for speed.

**Acceptance fixtures:** unchanged-route Library transition; ready empty Library; initial missing globals; usable adapter while navigation remains loading; account change/sign-out; no stale readiness; bootstrap cadence/budget; pending data never becomes false empty success; hidden-window clock still advances; shared items remain included.

**Target:** web-Library-ready to native model publication p95 around 200 ms or less on the measured host, with upstream data wait reported separately. This is an objective to verify, not a result already achieved.

## A7 — Return only the requested album/folder

**Files:** `Tunes/Resources/SamplyBridge.js`, `Tunes/Samply/Web/SamplyWebModels.swift`, `SamplyWebSession.swift`, `SamplyTiming.swift`, `Tunes/App/SamplyBackend.swift`; optionally one focused browse coordinator; fixtures.

1. Add an additive `browsePage` command and page DTO containing version/account, canonical route/project/folder, both readiness conditions, required access/version evidence, and current boxes. It contains no Library array or playback clock. Keep legacy `browse` for creation/open callers until separately migrated and tested.
2. Register the new command with dispatch, capabilities, typed error mapping, diagnostics, and the 25-second interaction deadline. A missing page store during initialization remains transient; do not label every missing capability a permanent contract mismatch.
3. If the existing authorized route/project/folder and both readiness flags match, use a direct current-page read with zero router pushes and no unnecessary loading/clear transition. Do not accept a route string alone. Retain tokenized external-link resolution and expected-project checks for actual navigation.
4. When navigation is necessary, keep Samply's router/player access checks and both player/boxes loading flags. Return a confirmed empty level only after readiness. Do not invent route-independent folder APIs, new raw Firestore schemas, or alternative minified exports.
5. Separate router wait, box-data wait, and observation delay. Replace or tune 100 ms readiness sampling only with verified bounded behavior. This can remove tens of milliseconds of native observation delay, not seconds of upstream loading by itself.
6. **Track freshness by scope.** A page-only reply does not refresh the Library; a Library-only reply does not refresh boxes/playback. Do not call the current `noteFullContentAccepted()` on a scoped reply as though every collection was refreshed. Preserve pending invalidations and only advance the matching scope's timestamp. A cached preview never advances authoritative freshness. It is acceptable to retain a legacy periodic full reconciliation while safely migrating, with no duplicate full read after every scoped action.
7. Keep cancellation/account/page epochs and playing-album binding independent of the displayed page. Browsing must not restart playback, replace the queue, or bind the player cover to a different displayed album.

**Acceptance fixtures:** 10 versus 1,000 unrelated Library entries yield zero Library mappings and constant page-reply overhead for equal boxes; current-page hit makes zero router calls; wrong folder/project forces validation; pending loading cannot return an empty success; shared/version-restricted content; tokenized link; A → B → A; page freshness cannot consume Library invalidation; no playback resets.

**Target:** reduce selection-to-authoritative-page overhead after Samply boxes are ready, while reporting cold upstream wait separately. The known 229,378-byte full browse is a baseline to replace, not the latency acceptance metric.

## A8 — Keep visited page previews without granting stale actions

**Files:** one small page cache/state helper under `Tunes/Samply/Web/` or `Tunes/Features/Album/`, `Tunes/App/SamplyBackend.swift`, `Tunes/Features/Album/AlbumContents.swift`, `AlbumDetailView.swift`; tests.

1. Add memory-only LRU previews keyed by build/session epoch, confirmed account, canonical route, expected project, and folder. Initial bounds: 20 entries, 5,000 box records, 8 MiB estimated encoded metadata, 30-second preview TTL. Enforce every bound; do not re-encode the entire cache on every clock tick.
2. Cache adapter-returned display metadata only. No credentials, pasted sign-in links, token-bearing route inputs, or media URLs. Keep image URLs private inside existing account-scoped display models; never export/log them as diagnostics.
3. Add explicit loading, preview/validating, ready, and failed presentation states. A hit can publish immediately, then revalidate the active web route/account/permissions. Preview is not `.loaded`, cannot fulfill fresh server refresh, and cannot enable play, versions, upload, or other actions. Keep authoritative action state separate from displayed metadata.
4. Clear on sign-out/account change. Remove relevant entries on denial, authoritative removal, processing/version changes, or content mutation/upload invalidation. Fresh ready empty content replaces an older nonempty preview; incomplete content does not masquerade as a fresh empty page.
5. Preserve the requested native page, active WebView route, and playing album as distinct identities. Do not reuse cached route evidence to play a track from a page no longer prepared in Samply.

**Acceptance fixtures:** A → B → A; folder/child/parent; TTL/LRU/record/byte bounds; account/build isolation; access revocation; no stale actions; fresh empty replacement; upload invalidation; delayed cancelled results; no wrong-album cover.

**Target:** a warm preview publication around 100 ms or less, measured separately from fresh action-ready latency. No cross-launch disk Library cache is included; it needs its own identity/privacy/restoration design.

## A9 — Derive album content once and isolate the progress clock

**Files:** `Tunes/Features/Album/AlbumContents.swift`, `AlbumDetailView.swift`, `AlbumTrackRow.swift`, `Tunes/Features/Playback/PlaybackController.swift`; Library view only for a measured filtering issue.

1. Build an immutable album presentation per accepted content revision: tracks, folders, indices, divider flags, first playable item, and duration summary. Reuse it within the view. Remove repeated filtering through the computed `contents` property and `contents.tracks.count` inside row creation.
2. Retain the lazy layout, track order, empty/loading distinction, processing/version presentation, and incomplete-duration semantics. Do not use this task to redesign visual styles or copy.
3. Store independently observed current-file/transport presentation that changes only when those fields change. The list observes it; the progress bar observes position. A computed alias of `state.fileID` still observes the whole stored `state` and does not solve the boundary. Preserve Samply's authoritative media clock and seek behavior.
4. Keep A4's field-level content observation. Optimize search indexes or off-main decode only if phase/CPU evidence shows they matter. No blind actor migration of WebKit/AppKit objects.

**Acceptance fixtures:** one derivation per content revision; equal content no notification; position-only change no list-presentation invalidation; track/transport/processing/version changes still update; grouping, durations, search behavior, seek hold, player origin, and media-key tests pass.

## Real-account verification policy

The cached Debug web session is useful for an ordinary-use sanity check after deterministic checks pass. It is not required for unit tests and its availability is unverified. Use it only through the app's normal isolated Debug session; do not inspect, copy, export, migrate, or reset website credentials or website-data directories to obtain access.

Normal startup, reading Library, opening a few existing albums, entering/returning from folders, and ordinary playback if relevant are within the user's permission. Keep this a small finite normal-use pass with natural pauses. Do not add artificial one-click limits, but do not create a loop, parallel load, account enumeration, repeated sign-in cycle, or live benchmark that repeats navigation dozens of times. Existing normal startup token verification must not be artificially retriggered for measurements.

`AGENTS.md` prohibits Computer Use, browser/accessibility automation, UI test runners, and screenshots/visual inspection of a running app by the Agent. Accordingly, human actions drive real UI flows and the Agent may consume the sanitized passive A5 trace through an available permitted read mechanism or a user-provided export. Do not use Xcode snippets to drive the real WebView, call live browse/refresh loops, bypass the hosted-test startup guard, or extract private state. Provide the concrete user procedure in chat only.

Do not create projects, upload/artwork tickets or storage PUTs, alter shared access/versions/downloads, delete content, change the account, or sign out for this performance verification. Exercise those failure/mutation paths with fixtures. Normal Library/player reads can still cause Samply's own history/analytics effects; do not describe them as a guarantee of zero remote side effects.

Stop additional diagnostic activity if rate limiting, authorization/access failure, an account change, a security challenge, or service instability appears. Respect `Retry-After`; do not keep refreshing or requesting new sign-in links. Preserve the session and report the condition. Do not change account/signing configuration to continue testing.

Report a few real observations as a sanity check with their actual sample count. Use fixture repetitions for statistical/work-count evidence. Do not claim a stable real-world p95 or stress-test result from a normal-use pass, and do not generate real traffic to satisfy a synthetic sample-count target.

## Final gates and rollback

- **Correctness:** all four reviewed defects have regression coverage; zero stale-account/page commits; cancelled web work cannot resurrect older data; no new automatic writes; transfer retention/deadlines are bounded; real content observers are silent for equal input.
- **Latency:** A6 readiness invalidates immediately; A7 excludes unrelated collections and supports a validated current-page hit; A8 preview and action readiness stay distinct; A9 removes content derivation from progress-only updates. Report startup/navigation median/p95 where measurements support them; bytes/CPU are explanatory metrics.
- **Compatibility:** preserve authentication/session history, shared Library, empty albums, folder/version permissions, hidden media clock, playback origin/artwork, seek/media keys, credential authority, creation quarantine, and upload uncertainty.
- **Validation:** focused tests after each stage, then all hosted `TunesTests` and bridge protocols using the permitted tool path. Run diagnosis/benchmark fixtures when relevant paths change. No UI tests. A missing signing prerequisite leaves the hosted gate explicitly unresolved, not waived.
- **Rollback:** correctness fixes A1–A4 remain independent. Scoped-read/cache/presentation changes are separately reversible; retain compatible legacy DTO/command paths during migration. Never roll back to stale cancellation behavior, clear user website data, or alter permissions to restore performance. Do not run both old and new recovery/poll owners concurrently.
- **Handoff:** list stage IDs, files, checks/tool selections, pass/fail/blocked results, synthetic versus real samples, before/after scoped work and latency, and remaining limitations. Report any unmet gate without claiming full completion. No repository manual checklist.

## Copyable implementation prompt

> Implement `Docs/LoadingPerformanceImplementationPlan.md` on the current checkout. Read `AGENTS.md` and the linked architecture/authentication documents first. Execute A0–A9 serially, making each stage reviewable and running its focused checks before proceeding; continue automatically when checks pass. Discover Xcode Code Intelligence tools and use their built-in build/test workflow first, with temporary Derived Data, original Apple Development/team/bundle configuration, hosted TunesTests only, and TunesUITests excluded. State a specific tool limitation before any fallback; never change signing to get a pass. Fix the one P1 and three P2 issues before adding page previews. Preserve the shared web Library, existing WebKit player, official sign-in, PAT file policy, account/selection guards, and mutation uncertainty. Keep synthetic tests isolated from the cached real Debug account. Real-account verification may follow normal user behavior in a small ordinary-use pass, with no stress or write tests; obey the repository's UI-automation prohibition and collect passive sanitized timings from human-driven actions. Provide any human verification procedure in chat only. Do not stop at another plan or claim speed from payload bytes alone. Report each stage and every unresolved validation prerequisite honestly.
