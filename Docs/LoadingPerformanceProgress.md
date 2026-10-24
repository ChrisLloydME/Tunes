# Loading performance implementation progress

This technical checkpoint records source implementation and automated evidence. It is not a manual UI verification checklist. The prompt preparation itself did not implement a runtime fix; implemented steps are recorded below.

## Current checkpoint

- Application baseline at prompt preparation: `7cefa55`.
- Current commit: `a61c318`; S02-S06 source, test, and checkpoint changes are uncommitted.
- Last completed implementation step: S06.
- Next requested step: S07; not started.
- Implementation state: S02-S06 implemented and verified. S00 and S01 remain valid and were committed as `b61e041` and `a61c318`.
- Hosted validation in the implementing Xcode environment: Xcode Code Intelligence `BuildProject` succeeded and the focused retry, loader, Observation, diagnostics, and bridge/coordinator `TunesTests` selections passed. The prior authoring-chat signing limitation did not reproduce here.
- Validation-path limitation: the built-in build/test tools expose no custom Derived Data option and used the open workspace's standard Derived Data (`~/Library/Developer/Xcode/DerivedData/Tunes-<hash>/`). No shell build/test fallback was taken. The complete hosted suite remains deferred to S16.
- Existing supporting material: implementation plan, loading diagnosis, and fixture probe. Preserve these and other user changes.

## Step status

Use `pending`, `in progress`, `implemented; validation blocked`, `verified`, or `blocked` accurately. A later step does not retroactively verify an earlier one without evidence.

| Step | Scope | Status |
| --- | --- | --- |
| S00 | Xcode tools and baseline | verified |
| S01 | Native/JS cancellation | verified |
| S02 | Active REST GET deadline | verified |
| S03 | Bounded image receiver | verified |
| S04 | Content Observation boundary | verified |
| S05 | Bounded trace recorder | verified |
| S06 | Connected loading traces | verified |
| S07 | Library readiness invalidation | pending |
| S08 | Scoped Library contract | pending |
| S09 | Library consumption/bootstrap | pending |
| S10 | Scoped browse contract/fast path | pending |
| S11 | Browse consumption/freshness | pending |
| S12 | Isolated preview cache | pending |
| S13 | Preview/action-guard integration | pending |
| S14 | Per-revision album presentation | pending |
| S15 | Independent playback presentation | pending |
| S16 | Cumulative acceptance | pending |

## Step entries

### S00 — Establish tools and synthetic baseline

- State: verified. Base `7cefa55`; current `0a13747`; working tree was clean and no application source was changed. The only changed file for this checkpoint is `Docs/LoadingPerformanceProgress.md`.
- Environment: project `Tunes.xcodeproj`, shared scheme `Tunes`, active test plan `Tunes`, destination `My Mac` (macOS 27.0.1, arm64), Debug configuration. Targets are `Tunes`, `TunesTests`, and `TunesUITests`.
- Test selection: the active plan lists 214 enabled tests, including two `TunesUITests`. `RunAllTests` was therefore not used; `RunSomeTests` selected only `TunesTests` identifiers.
- The built-in target-settings tool reports only the active Debug configuration. A read-only `xcodebuild -showBuildSettings` query, which performed no build or test, confirmed the Release and UI-test target values:

| Target | Configuration | Signing | Team | Bundle identifier |
| --- | --- | --- | --- | --- |
| Tunes | Debug | Automatic, Apple Development | YM5G2M8PV9 | com.lloydME.Tunes.beta |
| Tunes | Release | Automatic, Apple Development | YM5G2M8PV9 | com.lloydME.Tunes |
| TunesTests | Debug | Automatic, Apple Development | YM5G2M8PV9 | com.lloydME.Tunes.beta.Tests |
| TunesUITests | Debug | Automatic, Apple Development | YM5G2M8PV9 | com.lloydME.Tunes.beta.UITests |

- Build: `BuildProject` succeeded in 7.576 s with no reported errors and signed `Tunes.debug.dylib` and `Tunes.app`. No installed application was replaced. The built-in build used the open workspace's standard Derived Data (`~/Library/Developer/Xcode/DerivedData/Tunes-<hash>/`).
- Focused hosted checks: `RunSomeTests` reported 7 passed, 0 failed, 0 skipped, 0 not run, 0 expected failures; console test execution was 0.136 s. Selected tests were both `SamplySnapshotBenchmarkTests` baselines, two `SamplyPollScheduleTests`, `SamplyWebSessionBridgeTests/delayedCompletionIsDecodedAndMeasured()`, `SamplyBridgeDeadlineTests/productDeadlinesMatchTheApprovedCommandClasses()`, and `SamplyReadRecoveryPolicyTests/attemptsUseTheApprovedDelaysWithBoundedJitter()`.
- Native decode baseline (Debug build, 5 warmups and 30 samples per row, informational wall-clock medians; byte counts are deterministic):

| Fixture | Encoded bytes | Median | p95 |
| --- | --- | --- | --- |
| Library 10, boxes 0 | 2,291 | 0.047 ms | 0.185 ms |
| Library 100, boxes 0 | 21,598 | 0.344 ms | 0.689 ms |
| Library 1,000, boxes 0 | 220,970 | 3.106 ms | 3.462 ms |
| Library 10, boxes 0 (second test method) | 2,291 | 0.114 ms | 0.169 ms |
| Library 10, boxes 100 | 13,620 | 0.333 ms | 0.672 ms |
| Library 10, boxes 1,000 | 118,210 | 2.779 ms | 3.091 ms |

- Synthetic bridge protocol: `node --test Scripts/test-samply-bridge.mjs` on Node v26.12.1 reported 45 passed, 0 failed, 0 cancelled, 0 skipped in 596 ms.
- Synthetic loading diagnosis: `node Scripts/diagnose-loading-latency.mjs` reproduced the known fixture baseline. Full-snapshot Library readiness changed from false to true while the runtime payload remained identical and still omitted `libraryReady`; runtime and full-content intervals were 0.7 s and 2.1 s. With 1,000 Library items and 100 boxes, the `810f8c3` baseline used one router call, 1,000 Library mappings, and 229,336 bytes; the working tree used one router call, 1,000 mappings, and 229,378 bytes. The synthetic five-millisecond readiness probe returned data at 5.9 ms and the browse reply at 101.23 ms, an observational delay of 95.33 ms in this single host-dependent run.
- Preserved: no source, project, scheme, signing, bundle-identifier, WebKit-store, or user change. The hosted-test startup guard in `SamplyBackend.start` and test-only profile/session defaults remain in place. No interactive Agent-driven app launch, UI test, screenshot, real-account access, or website-data clearing occurred; hosted tests used their normal test host. The cached Debug web session was not exercised.
- Unresolved: the built-in runner has no temporary-Derived-Data path option and used the workspace's standard Derived Data; this is a tool-path limitation, not a source failure. The complete 212-test hosted `TunesTests` baseline was not run because the shared contract reserves it for S16. No live-account timing was collected; real UI verification remains manual. There is no remaining S00 action. S01 was not started.

### S01 — Fix cancellation end to end

- State: verified. Base `7cefa55`; S01 changes are committed as `b61e041` with this checkpoint in `a61c318`. Signing, bundle identifiers, authentication, WebKit stores, and loading cadence were not changed.
- Changed files: `Tunes/Samply/Web/SamplyWebSession.swift`, `Tunes/Resources/SamplyBridge.js`, `Tunes/App/SamplyBackend.swift`, `Scripts/test-samply-bridge.mjs`, `TunesTests/SamplyWebSessionBridgeTests.swift`, `TunesTests/SamplyBackendReadCoordinatorTests.swift`, and this checkpoint.
- Native cancellation: `finishInvocation` now expires both ordinary `CancellationError` and `.timedOut` exactly once. It sends no cancel notification when the pending generation differs from the current document or when signing out, so an old document cannot cancel a replacement document. Late completions remain ignored after the pending entry is removed.
- Caller cancellation: `call` checks cancellation after the bridge await and before reporting success; `refreshRuntime`, `refresh`, `readPageSnapshot`, `applyPageRefresh`, and `refreshLibrarySnapshot` check again before applying or returning content. A cancelled caller can no longer commit a success kept alive by a sibling waiter.
- Coalesced reads: releasing one waiter leaves the shared read alive for its sibling; the final waiter cancels the shared task and emits one protocol cancel. No business command is replayed automatically. The waiter release remains exactly-once.
- JS request expiry: `cancel` records the request ID, and cancelled IDs remain until their command settles. Eviction skips active IDs, uses a 64-entry soft cap, and retains unresolved entries rather than reactivating them. Cancel-before-command is supported. Navigation and audio paths recheck request activity after their awaits without undoing an action that already started.
- Build: final `BuildProject` passed in 0.939 s with no errors.
- Hosted checks: `RunSomeTests` selected 7 `SamplyWebSessionBridgeTests`, 4 `SamplyBridgeDeadlineTests`, 2 `SamplyBridgeProtocolTests`, 2 `SamplyRuntimeSessionTests`, and 9 `SamplyBackendReadCoordinatorTests`; all 24 passed with 0 failed, 0 skipped, and 0 not run. New fixtures cover ordinary-cancellation expiry, late completion after a newer read, A → B → A, final-waiter cancellation, sibling independence, cancelled shared callers, old-document replacement, and a success racing caller cancellation.
- Bridge protocol: `node --test Scripts/test-samply-bridge.mjs` reported 50 passed, 0 failed, 0 cancelled, 0 skipped in 614 ms. New fixtures cover a cancelled older read finishing after a newer accepted read, a newer cancellation leaving an older read independent, A → B → A, bounded expiry without reactivation, and a cancelled play load that finishes late without replay.
- Synthetic loading probe after the change still matches the known baseline: one router call, 1,000 Library mappings, 100 boxes, 229,378 bytes; runtime/full-content intervals 0.7 s/2.1 s; the single five-millisecond probe reported 5.98 ms data-ready, 100.76 ms reply, and 94.77 ms observation delay. These remain host-dependent synthetic values.
- Preserved: no DTO, cache, polling-cadence, signing, authentication, or UI change; the hosted-test startup guard and cached Debug session were untouched. No interactive app launch, UI test, screenshot, real-account access, or website-data clearing occurred.
- Unresolved: the built-in runner still uses the workspace's standard Derived Data rather than a temporary path; the complete hosted suite remains deferred to S16; no live-account timing was collected. There is no remaining S01 action. S02 was not started.

### S02 — Fix active REST GET deadlines

- State: verified. Base `7cefa55`; current commit `a61c318` plus the uncommitted S02 changes. Signing, bundle identifiers, authentication, WebKit stores, and loading cadence were not changed.
- Changed files: `Tunes/Samply/REST/SamplyAPI.swift`, `TunesTests/SamplyAPIRetryTests.swift`, and this checkpoint.
- Active GET deadline: each GET attempt now holds a cancellable `URLSessionDataTask` behind an exactly-once continuation. A deadline task waits only the remaining operation budget from the monotonic clock, then resumes the waiter with `SamplyError.timedOut`, cancels the active task, and ignores its eventual callback. A success that crosses the absolute deadline is rejected.
- Caller cancellation: the attempt changes cancellation into a `CancellationError`, including a racing `URLError.cancelled`, and the GET caller checks cancellation again before processing the response.
- Retry budget: the existing three-attempt limit, 429/502/503/504 allowlist, transient-transport allowlist, numeric/date `Retry-After`, and pre-sleep remaining-budget checks are preserved. No new URLSession is created per retry.
- Mutation preservation: only GET uses the active-transfer path. POST, ticket, and PUT operations keep their existing timeout and uncertainty behavior; no automatic replay was added.
- Build: final `BuildProject` passed in 0.896 s with no errors.
- Hosted checks: all 15 `SamplyAPIRetryTests` passed with 0 failed, 0 skipped, and 0 not run. New fixtures cover continuously arriving chunks cancelled at the deadline, a stalled response, a never-completing transfer, success before and after the deadline, caller cancellation during transfer, and terminal certificate failure. The existing retry, `Retry-After`, exhaustion, transport, decode, and mutation tests also passed.
- Mutation checks: 31 focused tests across `TunesTests`, `ProjectCreationTests`, and `SamplyUploaderTests` passed, covering POST/ticket non-replay, creator/auth errors, upload ticket encoding, artwork/captured-token behavior, PUT timeout uncertainty, and upload cancellation outcomes.
- Preserved: cookie/cache isolation, redirect suppression, captured credentials, GET attempt/status allowlists, retry waits, and all POST/ticket/PUT uncertainty behavior. No live timeout or real-account test was run.
- Unresolved: the built-in runner still uses the workspace's standard Derived Data rather than a temporary path; per-file source diagnostics were unavailable because `XcodeRefreshCodeIssuesInFile` returned `SourceEditorCallableDiagnosticError` error 5, although compilation and hosted tests succeeded. The complete hosted suite remains deferred to S16. There is no remaining S02 action. S03 was not started.

### S03 — Fix image transfer bounds

- State: verified. S02's active GET deadline remains intact. Signing, bundle identifiers, authentication, WebKit stores, and loading cadence were not changed.
- Changed files: `Tunes/Samply/Web/BoundedHTTPDataLoader.swift`, `TunesTests/BoundedHTTPDataLoaderTests.swift`, and this checkpoint.
- Receive path: each transfer now owns a lock-protected receive buffer on the URLSession delegate path. It checks remaining capacity before appending, rejects an oversized chunk without retaining it, treats `Content-Length` only as an optional early hint, and ignores every callback after a terminal outcome.
- Handoff: a terminal result is delivered through one injectable MainActor scheduler; the registry retains the bounded buffer for inspection until that single handoff. Cancellation settles once, cancels the data task, and a post-handoff cancellation check prevents a successful result from reaching a cancelled caller.
- Fixtures: 13 `BoundedHTTPDataLoaderTests` cover multi-chunk delivery, oversized single chunks, many small chunks, unknown and false-low `Content-Length`, oversized declared length, delayed handoff with retained-byte/pending-transfer assertions, cancellation with late completion, and cancellation before delayed handoff. Retained data never exceeded the configured limit.
- Integration checks: all 9 `ArtworkPipelineTests`, 4 `SamplyProfileCacheTests`, and 5 `SamplyProfileCacheCooldownTests` passed (31 focused checks total). The 8 MiB artwork/2 MiB avatar limits, four-transfer coalescing, timeouts, HTTPS/cookie/PAT/redirect isolation, and cooldown behavior remain unchanged.
- No UI change, wider artwork rewrite, or live oversized-response test was performed. There is no remaining S03 action; S04 was not started at this checkpoint.

### S04 — Fix actual Observation notifications

- State: verified. S03 remains intact.
- Changed files: `Tunes/Samply/Web/SamplyContentAcceptance.swift`, `TunesTests/StateAcceptanceTests.swift`, and this checkpoint.
- Content owner: `SamplyContentAcceptance` is now a small `@Observable` reference type with independently observed Library and box fields. Equality is checked before assigning either field, so identical input does not enter a mutating Observation accessor. Assignment counters are `@ObservationIgnored`.
- Backend observation: `SamplyBackend.library` and `.boxes` now observe the reference owner's fields directly. `withObservationTracking` probes through the production backend prove that identical Library/box input produces no further notification, Library-only and box-only changes notify only their own observer, and clear, rename, artwork, access, processing, version, order, and in-place creation updates still notify when they actually change.
- Checks: all 11 `StateAcceptanceTests` and 4 `AlbumContentsTests` passed. Eight focused project-creation checks also passed, covering creation callbacks, empty-loaded state, account guards, and optional writes.
- Creation in-place identity, empty-loaded representation, account guards, and existing playback assignment behavior remain intact. No page previews or playback model redesign were introduced. There is no remaining S04 action; S05 was not started at this checkpoint.

### S05 — Add the bounded trace recorder

- State: verified; recorder implemented but not connected to loading paths until S06.
- Changed files: `Tunes/Samply/Web/SamplyDiagnostics.swift`, `TunesTests/SamplyDiagnosticsTests.swift`, and this checkpoint.
- Trace model: fixed startup/navigation/cache stage categories, fixed outcome categories, opaque operation IDs, command categories, and duration/count/byte fields only.
- Bounds: at most 128 operations in chronological history and at most 16 stages per operation. Eviction drops the oldest operation; late stages recreate a bounded record rather than growing history. `developerDescription` emits fixed-format sanitized text with no dynamic page text, URLs, account/resource identifiers, credentials, bodies, or arbitrary errors.
- Behavior: disabled recorders retain nothing and expose only the disabled message; `SamplyDiagnostics.reset()` clears the trace; `SamplyDiagnostics` owns a recorder initialized from the existing Debug opt-in. Release builds remain disabled through the existing `#if DEBUG` opt-in.
- Checks: all 11 `SamplyDiagnosticsTests` passed, including correlation, eviction, stage bounds, disabled behavior, sanitized output, reset, and the existing aggregate-bucket tests.
- No loading-path instrumentation, poll log, bridge payload change, or real-account run was performed in S05. There is no remaining S05 action; S06 was not started at this checkpoint.

### S06 — Connect phase timing without changing loading

- State: verified. S05's recorder is now connected; production response/readiness behavior is unchanged when tracing is disabled.
- Changed files: `Tunes/Resources/SamplyBridge.js`, `Tunes/Samply/Web/SamplyBridgeTransport.swift`, `Tunes/Samply/Web/SamplyWebSession.swift`, `Tunes/App/SamplyBackend.swift`, `Scripts/samply-bridge-fixture.mjs`, `Scripts/test-samply-bridge.mjs`, `Scripts/benchmark-loading-phases.mjs`, `TunesTests/SamplyWebSessionBridgeTests.swift`, `TunesTests/SamplyBackendReadCoordinatorTests.swift`, and this checkpoint.
- Native/JS correlation: a trace-enabled call adds only a `debugTiming` argument. The adapter keeps at most 64 timing entries and returns fixed router/box/response/total durations; the Swift bridge response accepts an optional `timing` object and records `routerSettled`, `boxesReady`, `responseBuilt`, and `payloadDecoded` under the same opaque operation ID. No raw JS clock is compared with native uptime.
- Startup milestones: requested, document committed/finished, adapter usable, authentication resolved, web Library ready, payload decoded, and content published are recorded under a startup operation; the first complete snapshot uses that operation ID. Navigation records selection, bridge start, JS phases, decode, and content publication under the browse operation.
- No new bridge command or server request, no polling/cadence change, and no account/resource URLs, credentials, or error text are retained.
- Checks: all 26 focused bridge, deadline, protocol, runtime, and backend-read-coordinator tests passed, including a navigation trace that correlates JS phases with native decode/publication and rejects sensitive fields. `node --test Scripts/test-samply-bridge.mjs` reported 52 passed, 0 failed, in 815 ms. Router-heavy and data-heavy fixtures attribute delay to different phases.
- Synthetic phase baseline (`node Scripts/benchmark-loading-phases.mjs`, 5 warmups and 30 samples, informational): router scenario router median/p95 31.33/31.52 ms with boxes 0.06/0.08 ms and total 31.73/32.07 ms; data scenario router 0.06/0.13 ms with boxes 101.22/106.73 ms and total 101.58/109.21 ms. Both returned 827-byte synthetic responses.
- Final integrated `BuildProject` passed in 0.574 s. The S02 retry selection (15/15), S03 loader/artwork selection (31/31), and S04/S05 selection (26/26) were rerun after the connected changes.
- Unresolved: startup document/adapter milestones are connected but were not exercised by a hosted WebKit page-startup fixture; the built-in runner still uses the workspace's standard Derived Data rather than a temporary path; the complete hosted suite remains deferred to S16; no real-account timing was collected. There is no remaining S06 action. S07 was not started.

## Evidence format for each completed or interrupted step

Record step ID, implementation state, base/current revision if relevant, changed files, completed behavior, actual validation tool/target/test selections, check outcomes, preserved invariants, and exact unresolved issue. Distinguish synthetic from any ordinary-use real observations. Do not include secrets, URLs, account/resource identifiers, or manual click procedures.

Keep a concise chronological entry per step and update the current checkpoint. On interruption, identify the next incomplete action inside the same step. On success, name the next step but mark it not started. Do not write a completed entry merely because code was generated or a test command was dispatched.
