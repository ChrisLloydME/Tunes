# Loading performance implementation progress

This technical checkpoint records source implementation and automated evidence. It is not a manual UI verification checklist. The prompt preparation itself did not implement a runtime fix; implemented steps are recorded below.

## Current checkpoint

- Application baseline at prompt preparation: `7cefa55`.
- Current revision: `0a13747` base, with uncommitted S01 source, test, and checkpoint changes.
- Last completed implementation step: S01.
- Next requested step: S02; not started.
- Implementation state: S01 native/JS cancellation, request expiry, and coalesced waiter handling implemented and verified. S00's environment and synthetic baseline remain valid.
- Hosted validation in the implementing Xcode environment: Xcode Code Intelligence `BuildProject` succeeded and the focused bridge/coordinator `TunesTests` selection passed. The prior authoring-chat signing limitation did not reproduce here.
- Validation-path limitation: the built-in build/test tools expose no custom Derived Data option and used the open workspace's standard Derived Data (`~/Library/Developer/Xcode/DerivedData/Tunes-<hash>/`). No shell build/test fallback was taken. The complete hosted suite remains deferred to S16.
- Existing supporting material: implementation plan, loading diagnosis, and fixture probe. Preserve these and other user changes.

## Step status

Use `pending`, `in progress`, `implemented; validation blocked`, `verified`, or `blocked` accurately. A later step does not retroactively verify an earlier one without evidence.

| Step | Scope | Status |
| --- | --- | --- |
| S00 | Xcode tools and baseline | verified |
| S01 | Native/JS cancellation | verified |
| S02 | Active REST GET deadline | pending |
| S03 | Bounded image receiver | pending |
| S04 | Content Observation boundary | pending |
| S05 | Bounded trace recorder | pending |
| S06 | Connected loading traces | pending |
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

- State: verified. Base `7cefa55`; current `0a13747` plus the uncommitted S01 changes listed below. Signing, bundle identifiers, authentication, WebKit stores, and loading cadence were not changed.
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

## Evidence format for each completed or interrupted step

Record step ID, implementation state, base/current revision if relevant, changed files, completed behavior, actual validation tool/target/test selections, check outcomes, preserved invariants, and exact unresolved issue. Distinguish synthetic from any ordinary-use real observations. Do not include secrets, URLs, account/resource identifiers, or manual click procedures.

Keep a concise chronological entry per step and update the current checkpoint. On interruption, identify the next incomplete action inside the same step. On success, name the next step but mark it not started. Do not write a completed entry merely because code was generated or a test command was dispatched.
