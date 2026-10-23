# Sequential implementation prompts

Use these prompts in order, one message at a time, in the same implementing chat when possible. Each code block is one complete instruction. Do not send the entire document as an instruction to execute all steps.

The user explicitly selected **one requested step per turn**. This overrides the earlier all-stages continuation wording. Finish the requested step, verify its boundary, write the checkpoint, and stop. Continue within that step to resolve routine issues; do not begin the next step without a new human message.

The detailed requirements remain in [LoadingPerformanceImplementationPlan.md](LoadingPerformanceImplementationPlan.md). Durable technical status belongs in [LoadingPerformanceProgress.md](LoadingPerformanceProgress.md). These files record implementation and automated evidence, not a manual UI checklist.

## Contract shared by every prompt

1. Read `AGENTS.md`, the implementation plan, this contract, and the latest progress checkpoint. Preserve existing changes and completed fixes. Reconcile against current source rather than relying on line numbers or a remembered baseline.
2. Check the previous step's implementation and evidence before consuming it. Fix an incomplete dependency within its existing scope or explain the blocker; do not build additional refactors on a known broken contract. An environment-blocked check is distinct from a source failure: record it, preserve independent work, and never claim a verified result.
3. Use Xcode Code Intelligence build/test tools first, following discovery and schemas. Keep temporary Derived Data, original signing/team/bundle identifiers, hosted `TunesTests` only, and `TunesUITests` excluded. State the precise limitation before a permitted fallback. Use focused checks for each step; reserve the complete regression suite for S16 unless an intervening change justifies it.
4. Preserve account/session/selection cancellation, official sign-in, PAT file storage, shared Library, version/access restrictions, hidden-window playback clock, and mutation uncertainty. No automatic replay of writes/audio commands. Keep WebKit/AppKit on MainActor and repository text in English.
5. Use fixtures for cancellation races, timeouts, transfer limits, burst traffic, and repeated benchmarks. Normal-use real-account verification is allowed under the plan; no stress tests, bulk writes, repeated sign-in, UI automation, screenshots, or bypassing hosted-test isolation. Put any human verification procedure in chat only.
6. Add regression coverage and the corresponding production fix together when they form one behavior boundary. Do not stop with a deliberately failing checked-in state or ship only one half of a Swift/JS contract. An additive, tested API that leaves the old consumer running is a valid migration checkpoint.
7. Keep changes within the requested step and necessary dependency repair. Do not start unrelated cleanup, create a server/database, invent Samply APIs, or automatically commit/stash/reset user work.
8. Update the progress checkpoint with implementation state, changed files, actual checks/tool path, unresolved prerequisites, and the next expected step. End the chat reply with: completed step; checks passed/failed/blocked; remaining issues; next step ID **not started**. Then stop.

## Why these boundaries stay coherent

| Prompt | Plan stage | Atomic result |
| --- | --- | --- |
| S00 | A0 | Environment/tool discovery and reproducible baseline |
| S01 | A1 | Complete native/JS/shared-waiter cancellation fix |
| S02 | A2 | Complete active GET deadline and cancellation fix |
| S03 | A3 | Complete bounded image receive path |
| S04 | A4 | Actual field-level Observation boundary |
| S05 | A5, part 1 | Tested bounded trace recorder, not yet connected |
| S06 | A5, part 2 | Connected native/JS phase timing without changing loading behavior |
| S07 | A6, part 1 | Library readiness immediately invalidates the existing read path |
| S08 | A6, part 2 | Additive scoped Library contract, old consumers retained |
| S09 | A6, part 3 | Scoped Library consumption and bounded bootstrap scheduling |
| S10 | A7, part 1 | Additive scoped browse contract with validated current-page fast path |
| S11 | A7, part 2 | Scoped browse consumption and per-scope freshness |
| S12 | A8, part 1 | Tested memory preview cache, not yet connected to UI |
| S13 | A8, part 2 | Preview integration and action guards together |
| S14 | A9, part 1 | Album presentation derived once per content revision |
| S15 | A9, part 2 | Independent track/transport observation, progress clock preserved |
| S16 | Final gates | Cumulative regression and honest acceptance report |

The cancellation bridge, active-request deadline, and image receiver are each kept in one prompt because splitting their production ownership from completion/cancellation handling creates unsafe intermediate states. Larger performance changes use additive-contract, consumer, and presentation checkpoints instead.

## S00 — Establish tools and baseline

```text
Execute S00 only from Docs/LoadingPerformanceStepPrompts.md, following its shared contract. Read AGENTS.md, Docs/LoadingPerformanceImplementationPlan.md, and Docs/LoadingPerformanceProgress.md. This Agent is running through Xcode Code Intelligence: discover the available built-in tools and their schemas before selecting build/test commands. Confirm project/scheme, temporary Derived Data support, hosted TunesTests selection excluding TunesUITests, original Apple Development/team YM5G2M8PV9, and Debug/Release identifiers. Preserve the hosted-test real-account startup guard and cached Debug session. Establish the existing build/test prerequisite status and synthetic bridge/latency baseline using the permitted tool path. A prior chat's signing/tool failure is not evidence about this environment. Make no runtime refactor and do not start real-account UI verification. Record the baseline, tool path, and any actual blocker in the progress file. Stop after the S00 checkpoint; do not implement S01.
```

## S01 — Fix cancellation end to end

```text
Execute S01 only, following the shared contract and plan A1. Check S00's checkpoint. Fix native cancellation, JS request expiry, and coalesced waiter handling as one coherent change. Add a fixture where cancelled read A finishes after successful newer read B; verify both the next JS snapshot and native content retain B. Expire same-document ordinary cancellations as well as timeouts, without sending old-document cancellation into a replacement document. Keep exactly-once completion, bounded request bookkeeping, sibling-waiter independence, and post-await caller cancellation checks. Update no-extra-request assertions to permit a cancel protocol notification while forbidding business-command replay. Test races, final-waiter cancellation, A-to-B-to-A, and late audio completion without replay. Do not change loading cadence, DTOs, caching, or signing. Verify focused bridge/coordinator checks, update the S01 checkpoint, and stop. S02 must remain unstarted.
```

## S02 — Fix active REST GET deadlines

```text
Execute S02 only, following the shared contract and plan A2. Verify S01's boundary first. Implement one absolute monotonic GET deadline that can release the waiter and cancel the active URLSession task while data is still arriving. Include requests and retry sleeps; reject overdue success and settle exactly once. Add delayed/chunked and never-completing fixtures, deadline/success races, and caller cancellation. Preserve GET attempt/status/transport allowlists, Retry-After, cookie/redirect isolation, and all POST/ticket/PUT timeout and uncertainty behavior. Changing request.timeoutInterval alone or checking time only after the response is insufficient. Do not redesign the bridge, add caches, or run live timeout tests. Run focused retry and mutation-preservation checks, record the S02 result, and stop before S03.
```

## S03 — Fix image transfer bounds

```text
Execute S03 only, following the shared contract and plan A3. Verify S02's checkpoint. Refactor BoundedHTTPDataLoader so remaining-capacity checks and receive buffering happen on a controlled serial receive path before MainActor handoff. Eliminate unbounded per-chunk Data-capturing tasks, check before append, reject further data after terminal failure, and preserve exactly-once cancellation/completion. Add multi-chunk, false/unknown Content-Length, delayed-handoff, and completion-race fixtures with retained-buffer/pending-delivery assertions; a tooLarge result alone is insufficient. Preserve artwork/avatar byte limits, timeouts, HTTPS/cookie/PAT/redirect isolation, four-transfer behavior, coalescing, and cooldown. Avoid UI changes or a wider artwork rewrite. Run focused loader/artwork/avatar checks, update S03, and stop before S04.
```

## S04 — Fix actual Observation notifications

```text
Execute S04 only, following the shared contract and plan A4. Verify S03's checkpoint. Fix the observable content boundary so identical Library/box input produces no further notification through the actual backend/production owner. Use withObservationTracking, not assignment counters alone. Compare before observed mutation or use independently observed reference fields; simply making the value type Equatable does not fix mutating _modify access. Ensure Library-only and box-only changes notify their own observers, while real rename/order/access/processing/version changes still propagate. Preserve empty-loaded state, account guards, and creation callbacks. Do not introduce page previews or playback model redesign yet. Run focused state/empty-album checks, checkpoint S04, and stop before S05.
```

## S05 — Add the bounded trace recorder

```text
Execute S05 only, following the shared contract and plan A5. Confirm S01-S04 implementation/evidence in the progress file. Add a small opt-in Debug loading trace model/recorder beside the existing diagnostics. Retain operation and command correlation, fixed stage categories, bounded history of at most 128 operations, and bounded stages per operation; provide sanitized developer-readable output. Cover eviction, stage correlation, disabled/Release behavior, and absence of dynamic sensitive fields. Use opaque local IDs and durations/counts/bytes/outcomes only. Do not instrument loading paths, change bridge payload behavior, add a permanent poll log, or run a real account yet. This step ends with a tested recorder that is not yet connected. Update S05 and stop before S06.
```

## S06 — Connect phase timing without changing loading

```text
Execute S06 only, following the shared contract and the remaining A5 requirements. Use S05's recorder to connect startup, router-settled, matching-boxes-ready, response-built, native-decode, and content-publication timing on existing paths. Use compatible optional debug timing fields/side channels and keep current production response/readiness behavior unchanged. Correlate JS/native intervals by opaque operation ID; do not subtract raw clocks across processes. Add fixtures that independently delay routing and data readiness and show different phase attribution. Ensure tracing is bounded and adds no server requests, account/resource identifiers, URLs, credentials, or arbitrary error text. Do not optimize polling or introduce scoped DTO consumers yet. Preserve a synthetic phase baseline, checkpoint S06, and stop before S07.
```

## S07 — Fix the Library readiness invalidation gap

```text
Execute S07 only, following the shared contract and the readiness portion of A6. Add backward-compatible Library readiness to runtime state and the native invalidation identity. When the authorized Library becomes ready without an account/route change, schedule an immediate read through the existing complete-snapshot path instead of waiting for the 2.1-second sweep. Keep old runtime fixtures decodable; a missing field must not mean ready or signed out. Test ready empty Library, transition just after a prior read, account change, cancellation, and hidden playback-clock preservation. Do not add librarySnapshot, change the navigation-loading gate, speed up bootstrap polling, defer PAT verification, or add a cache in this step. Verify focused runtime/schedule tests and the readiness probe, checkpoint S07, and stop before S08.
```

## S08 — Add the scoped Library contract atomically

```text
Execute S08 only, following the shared contract and A6's scoped Library contract requirements. Add librarySnapshot and its Swift DTO together with JS/native dispatch, version/capability/error mapping, diagnostics, five-second status deadline classification, and fixture coverage. Return only authentication/account, Library readiness/items, version, and necessary capability evidence; do not map boxes or sample unrelated playback. Keep existing full snapshot and server refresh contracts intact, and leave current production monitoring/Library consumers on the old path for this checkpoint. Exercise the new contract through fixtures, including missing initialization, shared items, ready empty Library, cancellation, and unknown versions. No bootstrap/scheduler/cache changes. Update S08 after focused protocol/decoding checks, then stop before S09.
```

## S09 — Use scoped Library reads and bounded bootstrap

```text
Execute S09 only, following the shared contract and remaining A6 requirements. Consume the tested scoped Library contract from S08. Tie accepted Library readiness to account/session state rather than requiring web.snapshot, without fabricating a full snapshot with empty arrays. Use actual allowed-document/adapter/store readiness rather than waiting unconditionally for webView.isLoading to become false. Add the bounded bootstrap-only 100-200 ms lightweight readiness phase, at most ten seconds, stopping on first content/terminal failure/document or account change. Preserve steady-state/failure/media-clock cadence and forbid periodic forced server refresh. Maintain scope-specific freshness: a Library-only result cannot refresh boxes/playback or erase their invalidations. Test missing globals, navigation still loading, stale completion, ready empty content, old payloads, and no early write authorization. Leave PAT revalidation scheduling unchanged unless existing traces prove contention; record it as deferred if unmeasured. Run focused integration checks, record S09, and stop before S10.
```

## S10 — Add the scoped browse contract and fast path

```text
Execute S10 only, following the shared contract and A7's adapter/contract requirements. Add browsePage and its page DTO atomically with dispatch, capabilities, errors, diagnostics, and the 25-second interaction deadline. Include only current account/canonical route/project/folder/readiness/access evidence and boxes, with no whole Library or playback clock. Add the validated current-page fast path: matching authorized identity and both readiness flags permit a direct read with zero router pushes. Preserve empty-level readiness, tokenized link resolution, versions/shared access, and cancellation. Keep legacy browse and its creation/open consumers working, and leave the ordinary backend navigation consumer unchanged until S11. Compare equal-box replies under 10 versus 1,000 unrelated Library items: no Library mapping and no collection-driven payload growth. Do not invent folder APIs or add caching. Checkpoint S10 and stop before S11.
```

## S11 — Migrate ordinary browsing and freshness accounting

```text
Execute S11 only, following the shared contract and remaining A7 requirements. Move ordinary album/folder navigation to the scoped browsePage contract tested in S10; preserve legacy creation/open integration. Do not clear content or enter loading unnecessarily for a validated current-page hit. Keep account/document/selection and playing-album identities distinct. Replace blanket noteFullContentAccepted treatment with correct scoped freshness: page results cannot consume Library invalidations, Library reads cannot consume page invalidations, and no duplicate full read is added after every scoped action. Add integration tests for those interactions, A-to-B-to-A, tokenized links, pending versus ready empty levels, and preserved playback. Tune readiness observation only if S06 traces justify it; keep any probe/event bounded. Update the latency probe to exercise the new path while retaining the old baseline evidence. No preview cache yet. Checkpoint S11 and stop before S12.
```

## S12 — Add the isolated memory preview cache

```text
Execute S12 only, following the shared contract and A8's cache requirements. Add a small testable memory-only page preview cache keyed by build/session epoch, confirmed account, canonical route, expected project, and folder. Enforce the plan's entry/record/byte/TTL limits and cover eviction, invalidation, account isolation, empty values, and canonical identity in fixtures. Store display metadata only, never credentials, token-bearing route inputs, or streaming URLs; do not log private keys/metadata. The cache does not establish authentication, freshness, permissions, or playability. Leave production navigation and UI behavior unchanged in this step; the tested cache is deliberately not connected until S13. Do not add disk persistence or prefetch. Checkpoint S12 and stop before S13.
```

## S13 — Integrate previews and action guards together

```text
Execute S13 only, following the shared contract and remaining A8 requirements. Integrate S12's cache with explicit loading/preview-validating/ready/failed page presentation. Publish a warm preview promptly, then validate current web identity/readiness/access; preview must never set loaded, satisfy a fresh refresh, or enable play/versions/upload. Update the backend, view presentation, and every affected action guard as one coherent change. Preserve requested page versus active web route versus playing album. Clear/invalidate on account changes, denial, authoritative removal/content changes, and upload activity; correctly replace stale content with a fresh ready empty result. Test album/folder return navigation, cancellation, revocation, stale actions, and wrong-album artwork binding with fixtures. Measure preview separately from action readiness. No layout redesign or unrelated playback refactor. Checkpoint S13 and stop before S14.
```

## S14 — Derive the album presentation once

```text
Execute S14 only, following the shared contract and A9's content-derivation requirements. Build and reuse an immutable album presentation per accepted content revision: tracks, folders, indices/dividers, first playable track, and duration summary. Remove repeated contents filtering and per-row recomputation of total track count. Preserve lazy layout, ordering, previews versus authoritative state, incomplete-duration handling, processing/version presentation, and the existing visual design. Verify one derivation per content revision, unchanged content reuse, real metadata changes, grouping, and empty states. Do not yet redesign the playback clock/transport observation model or add search/decode optimizations without measurement. Run focused album/state checks, checkpoint S14, and stop before S15.
```

## S15 — Isolate track presentation from progress ticks

```text
Execute S15 only, following the shared contract and the remaining A9 requirements. Introduce independently observed stored track/transport presentation that updates only when its fields change, and move album-row observation onto it. Keep progress/timing on its existing authoritative Samply clock path. A computed alias of state.fileID still observes state and is not sufficient. Preserve hidden-window clock sampling, seeking/hold behavior, buffering, track transitions, playback origin/artwork, Now Playing, and media keys. Test with real Observation tracking that position-only changes do not invalidate the album presentation, while track/transport/content changes still update. Do not add a decoder, stream URL handling, layout redesign, or unrelated cleanup. Run focused playback/album regressions, checkpoint S15, and stop before S16.
```

## S16 — Run cumulative acceptance and stop

```text
Execute S16 only, following the shared contract and the plan's final gates. Read all checkpoints and audit the integrated diff for cancellation, active GET deadlines, bounded image retention, actual Observation notifications, Library readiness, scoped replies/freshness, preview action guards, and independent clock presentation. Run the complete hosted TunesTests suite with TunesUITests excluded through the permitted Xcode tool path, plus bridge protocols and relevant synthetic latency probes. Report before/after user-path work and timings with preview/action-ready/upstream/native intervals separated. If useful, provide a short human-driven ordinary-use real-account procedure in chat and consume only sanitized passive timing evidence; do not automate UI, stress the account, or invent real timing results. Fix only regressions directly attributable to the completed steps, using the smallest coherent repair, then rerun affected checks. No new features or broad refactor. Mark actual verified/blocked status, provide the final acceptance report, update S16, and stop. Do not claim completion while a required gate is unresolved.
```

## Resume the current step after interruption

Replace `Sxx` with the actual current step. This prompt resumes work; it does not authorize the next step.

```text
Resume Sxx only from Docs/LoadingPerformanceStepPrompts.md. Read AGENTS.md, the shared contract, Docs/LoadingPerformanceImplementationPlan.md, and the latest Docs/LoadingPerformanceProgress.md checkpoint. Inspect the current diff and preserve completed/user changes. Continue the unfinished part of Sxx; do not restart completed refactors, repeat already-passing checks without a reason, reset/stash the checkout, or begin another step. If validation is blocked, report the exact source/environment cause and retain honest implemented-versus-verified status. Finish the checkpoint and stop at the Sxx boundary.
```

## Repair a failed checkpoint before proceeding

```text
Repair the most recent failed implementation/checkpoint recorded in Docs/LoadingPerformanceProgress.md only. Follow AGENTS.md and the shared contract in Docs/LoadingPerformanceStepPrompts.md. Reproduce the reported failure using fixtures or the permitted hosted-test workflow, fix its root cause within that step's scope, and rerun the affected checks. Preserve earlier validated behavior and user changes. Do not weaken assertions, skip a required test, change signing/authentication, exercise failure against the real account, or start later steps to hide the failure. Update the checkpoint with the result and stop; do not proceed automatically.
```
