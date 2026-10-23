# Library and album loading latency diagnosis

Date: 2026-10-23. Reviewed application revision: `7cefa55`. Comparison baseline: `810f8c3`.

Execution handoff: use [LoadingPerformanceImplementationPlan.md](LoadingPerformanceImplementationPlan.md), which combines this diagnosis with the four reviewed defects and the user's clarification permitting ordinary-use real-account verification without stress testing.

## User report and conclusion

The user reports that startup to Library and opening albums/folders remain substantially slower than using the Samply website. Those are the primary targets of this diagnosis; artwork and playback controls are secondary.

The preceding upgrade reduced steady-state bridge traffic and strengthened recovery, but left the album navigation critical path essentially unchanged. It also introduced a Library readiness detection gap. Reducing background CPU or payload size is useful, but is not evidence that a user can see or use a page sooner.

There are concrete opportunities to remove native waiting and improve repeat navigation. The largest unknown is still the duration of Samply's route/data initialization inside the hidden WebView. Neither live account timings nor a running-app profile were collected. Do not attribute every multi-second delay to JSON, polling, or Samply's network without separating those intervals.

## Evidence collected

`Scripts/diagnose-loading-latency.mjs` runs the actual adapter against simulated stores and compares it with the pre-upgrade adapter. It does not launch Tunes, inspect a real browser session, or contact Samply.

| Probe | Result | Interpretation |
| --- | --- | --- |
| Library changes from loading to ready with unchanged account/route | Full snapshots change `libraryReady` from false to true, but the runtime payload stays identical and contains no `libraryReady`. | The 700 ms runtime loop cannot invalidate the 2.1-second content cadence for this transition. |
| One album browse with 1,000 Library entries and 100 boxes, before upgrade | One router call; 1,000 Library mappings; 229,336-byte response. | This is the interactive path, not the background polling benchmark. |
| Same album browse and fixture, after upgrade | One router call; 1,000 Library mappings; 229,378-byte response. | The interactive route and unrelated Library work were not removed. The small payload difference is additive capabilities. |
| Boxes become ready about 5.9 ms after a simulated route | Browse returns about 101.4 ms after start; about 95.5 ms is observation delay in this run. | The adapter's 100 ms `waitFor` tick adds avoidable delay. It does not explain multi-second loads on its own. These are informational Node timings, not Samply measurements. |

The readiness and work/count results are deterministic for this fixture. Timer timings vary by host. Reproduce with `node Scripts/diagnose-loading-latency.mjs`.

## Current critical paths

### Startup to Library

```text
ContentView.task
  -> SamplyBackend.start
  -> create/attach WebView host and load /library
  -> wait for webView.isLoading to become false
  -> next runtime poll (roughly 700 ms cadence when healthy)
  -> resolve web authentication
  -> full snapshot
  -> if Library is still loading, wait for the 2.1-second content cadence
  -> serialize full snapshot, decode on MainActor, publish Library
  -> create native grid and begin artwork work
```

Relevant source:

- `Tunes/Samply/Web/SamplyWebSession.swift`: `loadSession`, `refreshRuntime`, `refresh`.
- `Tunes/App/SamplyBackend.swift`: `poll`, `acceptRuntimeSnapshot`, `libraryReady`.
- `Tunes/Resources/SamplyBridge.js`: `runtimeSnapshot`, `snapshot`.
- `Tunes/App/ContentView.swift`: `mainContent` gates the grid on a full snapshot's readiness.

Two waits are introduced by Tunes:

1. Both read paths reject the read while `WKWebView.isLoading` is true. This prevents observing an initialized Samply store before the overall navigation finishes. The duration of this gate has not been measured; it must not be assumed to equal the data-loading duration. Treat store readiness, document identity, and navigation completion as separate signals.
2. `RuntimeIdentity` includes route/project/level/box readiness but not Library readiness. If a full read happens just before Library becomes ready, another successful full read normally waits approximately 2.1 seconds plus execution/scheduling time. The old full-poll interval was 700 ms. A favorable background-traffic benchmark therefore coexists with a worse first-Library observation bound. This is conditional scheduling overhead, not a fixed 2.1-second delay on every launch.

On launch with a stored PAT, `ProjectCredentialAuthority.activate` also starts REST owned-project enumeration and web ownership proof. It is not awaited by Library loading, so it is **not a proven serial dependency**. It can contend for resources and should be measured and deprioritized until after first content if material. Verification must still finish before any write is enabled.

### Album and folder navigation

```text
select / openFolder / goUp
  -> cancel prior browse and immediately clear current boxes
  -> show loading state
  -> bridge browse
  -> await router.push
  -> sample player and boxes readiness every 100 ms
  -> require matching route, project, folder and loaded view models
  -> build full snapshot, including every Library item and playback
  -> stringify, WebKit handoff, native decode, accept boxes
  -> derive album metadata and render rows
```

Relevant source:

- `Tunes/App/SamplyBackend.swift`: `select`, `browse`, `openFolder`, `goUp`.
- `Tunes/Resources/SamplyBridge.js`: `browse`, `waitFor`, `snapshot`.
- `Tunes/Features/Album/AlbumDetailView.swift`: loading state, `contents`, and row construction.

The app retains only the currently accepted level, not a cache of visited pages. Switching pages clears the native list even when the same page was recently visited. Samply may already reuse some web data; the existence of a router call does **not** prove that a new network request, store reset, or project subscription is made for every folder. Instrument those stages before proposing changes to Samply's internal folder contracts.

The 350 ms loading-indicator delay only postpones showing the spinner. It does not delay the actual browse request or make data arrive later. Removing it is not a loading optimization.

## Refactoring priorities

### L0 — Trace page latency instead of only aggregate bridge work

Add a small opt-in Debug trace with an opaque local operation ID and fixed stage names. Keep a bounded ring of at most 128 operations or equivalent bounded histograms. Record no account/resource identifiers, names, URLs, credentials, email links, payloads, or arbitrary exceptions.

Required stages:

| Flow | Milestones |
| --- | --- |
| Startup | Start requested; WebView navigation started/committed/finished; adapter usable; authentication resolved; Library store ready; first Library payload decoded; native content published |
| Browse | User selection; bridge invocation; router settled; matching boxes ready; response built; native decode complete; native content published |
| Repeat browse | Same current route hit, page-preview hit, or miss; route validation complete; fresh content published |

Measure JS intervals with a monotonic JS clock and native intervals with a monotonic native clock. Correlate via the opaque operation ID; never subtract raw `performance.now()` timestamps from native uptime. A model publication is not proof of a displayed frame. A passive presentation callback can provide an additional user-run signal, without automated app control or screenshots.

The existing diagnostics group only by stage/outcome and retain count/mean/max, losing the command category and operation correlation. They do not isolate router time from readiness polling or provide p95. Keep the safe aggregate counters but add the missing fixed phase correlation and a bounded developer-readable result. Do not add a permanent log per polling tick.

**Completion:** synthetic delayed-router and delayed-box fixtures attribute the delay to different stages. Report median/p95 for separately identified cold-start, first-visit, and repeat-visit scenarios once user-run measurements exist. Missing measurements must remain explicitly missing.

### L1 — Make first Library readiness independent of steady-state content cadence

**Primary files:** `SamplyBridge.js`, `SamplyWebModels.swift`, `SamplyWebSession.swift`, `SamplyBackend.swift`, `SamplyPollSchedule.swift`.

1. Include explicit Library readiness in runtime state and its invalidation identity. Trigger one immediate Library read when the authenticated Library changes from not ready to ready; do not wait for the periodic 2.1-second sweep.
2. Add a scoped `librarySnapshot` command/result carrying only version, authentication/account, Library readiness, and Library items. Do not map current album boxes or sample unrelated playback to deliver Library data. Keep existing full-snapshot contracts working for current callers until migration is complete.
3. Probe actual adapter/store readiness on the current allowed main document rather than unconditionally requiring all of `webView.isLoading == false`. Preserve document-generation, origin, cancellation, and version checks. Unavailable globals during navigation are transient; they must not be accepted as valid content or as confirmed sign-out.
4. During bootstrap only, use a bounded short readiness cadence, initially 100–200 ms for at most 10 seconds, or an equivalently scoped readiness notification. Stop the fast phase after first content or terminal failure and retain the normal failure budget. Do not raise all steady-state full snapshot polling to 100 ms.
5. Defer low-priority restored-PAT proof until first Library content or explicitly requested creation/upload, if L0 shows contention. Retain token/session/revision binding and keep writes disabled until proof succeeds. Do not confuse a restored PAT with web sign-in.

**Target:** once the authorized web Library is ready, native model publication should take at most about 200 ms at p95 on the measured host. This is a proposed native-overhead target, not a promise for full launch/network duration.

**Tests:** Library becomes ready immediately after a full read; ready empty Library; readiness with unchanged route; authentication changes during bootstrap; page still navigating while adapter is usable; missing globals; rapid sign-out/re-sign-in; no periodic forced server reads; no early write authorization. Drive readiness with fake time and enforce work counts; use actual timing only as informational evidence.

### L2 — Give album navigation a page-sized response and a current-page fast path

**Primary files:** `SamplyBridge.js`, `SamplyWebModels.swift`, `SamplyBackend.swift`; a small browsing coordinator if needed for scope ownership.

1. Add a scoped browse response with version, account identity, canonical route/project/folder identity, loaded/permission evidence, and the requested boxes. It must not remap or serialize the complete Library or playback clock. Keep the existing `browse` result for creation/open consumers until each caller is deliberately migrated.
2. Before navigating, test whether the existing authorized route, project, level, and both readiness flags already match the requested page. If they match, read that page directly without `router.push`, clearing content, or a loading transition. A matching route string alone is insufficient, including tokenized external player links.
3. If navigation is needed, retain Samply's current router/player permission flow. Preserve both player and boxes loading checks and allow a confirmed empty array. Do not accelerate by interpreting incomplete data as an empty album.
4. Improve completion detection only after separating route wait from box wait. Prefer a verified readiness notification or a bounded faster initial probe, then back off. The current 100 ms sampling delay is worth removing, but must not be presented as a solution for seconds spent awaiting upstream data.
5. Ensure cancellation expires the JS operation as well as the native waiter before adding any speculative/cache work. Do not automatically retry audio or mutations. Preserve late-result protection for A → B → A.

**Targets:** a ready current-page request makes zero router calls; adding unrelated Library entries does not increase browse-response size or Library mapping count; after web boxes are ready, the native acceptance gap stays within the measured overhead budget. Uncached upstream data may still take the same time.

**Tests:** same-route loaded page; same route but wrong folder/project; loading flags false before documents arrive; confirmed empty album; tokenized player link; shared/restricted versions; a 1,000-item unrelated Library; late cancellation; preserved playback queue and position.

Do not invent a route-independent folder API. A project-level folder index is a follow-up only if inspection of the supported/pinned adapter contract proves the existing web session already exposes the necessary authorized data. No new raw Firestore schema assumptions or guessed minified exports are authorized by this plan.

### L3 — Reuse visited page presentation while revalidating access

**Primary files:** a page-state/browse coordinator in `Tunes/Samply/Web/` or `Tunes/Features/Album/`, `SamplyBackend.swift`, `AlbumContents.swift`, `AlbumDetailView.swift`.

Add a small **memory-only** cache keyed by build/session epoch, account, canonical route, expected project, and folder. Initial bounds: at most 20 page entries, 5,000 total box records, 8 MiB estimated encoded metadata, and a 30-second preview TTL; evict on any limit and clear on account change/sign-out. Exclude credentials, sign-in links, token-bearing route inputs, and media URLs. Store only adapter-returned display metadata, including original user names.

Use explicit page states such as loading, preview/validating, ready, and failed:

- A recently visited page can publish its preview immediately rather than flash an empty list.
- Preview content is display-only. Playback, alternate-version access, upload, and other actions remain disabled until the current web route and authorization are validated. A preview must not set `.loaded` or satisfy a fresh server-refresh request.
- A cache miss navigates normally. Keep the requested page identity distinct from the still-active WebView route and currently playing album.
- A fresh access denial removes the corresponding preview. Authorized fresh data replaces it; incomplete data must not erase it as a false empty success. Invalidate affected entries on confirmed content changes or upload activity.

**Targets:** returning to a cached page commits a display preview within roughly 100 ms, while actual action-ready latency is reported separately. This improves repeat navigation and perceived continuity; it does not speed up a first visit or authorize playback sooner.

**Tests:** album A → B → A; folder → child → parent; TTL/LRU/byte limits; account/build isolation; permission revocation; cache miss; refreshed empty content; upload invalidation; no wrong-album playback binding; no writes enabled by a preview.

A cross-launch disk cache is a separate design. It cannot safely reuse a stored profile UID as proof of the current account and requires clear privacy, invalidation, and authenticated-restoration behavior. It is not part of L3 and is not required to fix the current first-Library detection gap.

### L4 — Remove native list work from the playback clock's update path

**Primary files:** `SamplyContentAcceptance.swift`, `PlaybackController.swift`, `AlbumContents.swift`, `AlbumDetailView.swift`, `LibraryView.swift`.

1. Fix the previously identified Observation boundary: equality inside a mutating value stored in `@Observable` does not suppress the outer `_modify` notification. Compare before entering that mutation or use independently observed content fields. Verify with `withObservationTracking`, not just assignment counters.
2. Build an immutable album presentation once per accepted content revision: tracks, folders, track indices, divider flags, first playable item, and duration summary. `contents` currently refilters boxes on each access; `contents.tracks.count` inside row construction can repeat the work for each instantiated row. Retain the existing lazy list and semantic order.
3. Store an independently observed playback presentation containing current file identity and playing/buffering status, separate from the position clock. A computed alias of `state.fileID` still observes the entire stored `state`; it does not establish this boundary. Keep the progress bar on the clock path and rows on actual track/transport changes.
4. Optimize Library filtering/search and move decoding off the main actor only if traces show they are material. First avoid unrelated payloads and repeated derivation; do not add actor hops or a generic data layer around work that is already small.

This should reduce native rebuilding and scrolling stalls on large pages, particularly during playback. It is not proof of faster Samply data delivery.

**Tests:** identical data produces no content notification; position-only changes do not invalidate album track presentation; track/processing/version changes do; grouping/metadata derivation runs once per revision; long-page row construction uses precomputed counts; search results and empty-state semantics are preserved.

## Delivery order and success criteria

Implement L0 with L1 first; retain the earlier cancellation/account-isolation fixes as prerequisites for L2/L3. Then implement L2, L3, and L4 in separately reviewable changes. Prioritize first content and navigation over further artwork/retry tuning for this user report.

Measure these scenarios separately: process launch with existing website data; first album visit; same-page revisit; A → B → A; parent/child folder navigation; large Library/long album while playing. Separate preview, authoritative action-ready state, and artwork completion. A cached preview must never be counted as freshly authorized content.

Compare the same account/content, equivalent cold/warm conditions, and Debug versus Release deliberately. A running browser tab has already paid initialization costs that a newly started WebView may still owe; never clear or import browser sessions to manufacture a comparison. Website data readiness and the native acceptance interval must be reported separately.

The main metrics are startup-to-first-Library-content and selection-to-visible/action-ready-page median/p95. Bridge bytes, average CPU, request counts, and cache hits explain those results; they are not substitutes. If upstream route/data initialization dominates after native waits are removed, report that limitation rather than increasing polling or switching the shared Library to the owned-only REST list.

Use builds, hosted unit tests, and simulated bridge protocols for automated validation. Follow Xcode-tool discovery, signing, temporary Derived Data, and `TunesTests`/`TunesUITests` restrictions in `AGENTS.md`. No app UI automation, interactive app launches by the Agent, screenshots, browser-profile access, or automated real-account stress tests. Ordinary-use real-account verification and passive timing collection follow the policy in [LoadingPerformanceImplementationPlan.md](LoadingPerformanceImplementationPlan.md). Provide any user-run verification instructions in chat only.

This diagnosis adds a report and a fixture probe, not runtime performance changes. The prior hosted test attempt was blocked by the development signing certificate/private-key prerequisite; no new claim of Swift build or hosted-test success is made here.
