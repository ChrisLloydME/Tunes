// Source-backed, fixture-only probes for the user-visible loading paths.
// No app is launched, no account is accessed, and no network request is sent.
// Timings are informational Node VM measurements, not real Samply latency.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
import {performance} from 'node:perf_hooks';
import vm from 'node:vm';
import {fixture} from './samply-bridge-fixture.mjs';

const baselineRef = '810f8c3';
const baselineSource = execFileSync('git', [
    'show', `${baselineRef}:Tunes/Resources/SamplyBridge.js`
], {cwd: new URL('../', import.meta.url), encoding: 'utf8'});

function buildFixture(useBaseline) {
    const f = fixture({libraryCount: 1000, boxCount: 100});
    if (useBaseline) {
        delete f.context.__tunesSamply;
        vm.runInContext(baselineSource.replace(
            'import(moduleURL.href)', '__fixtureImport(moduleURL.href)'), f.context);
        f.bridge = f.context.__tunesSamply;
    }
    return f;
}

async function browseProbe(useBaseline) {
    const f = buildFixture(useBaseline);
    let libraryMappings = 0;
    const original = f.library.canUploadFilesInProject;
    f.library.canUploadFilesInProject = id => {
        libraryMappings += 1;
        return original(id);
    };
    const result = await f.bridge.command('browse', {
        routeID: 'share-1', projectID: 'project-1'
    });
    assert.equal(result.boxes.length, 100);
    return {
        revision: useBaseline ? baselineRef : 'working tree',
        routerCalls: f.calls.filter(([name]) => name === 'navigate').length,
        libraryMappings,
        libraryItemsInReply: result.library.length,
        boxesInReply: result.boxes.length,
        responseBytes: Buffer.byteLength(JSON.stringify(result))
    };
}

const readiness = fixture();
readiness.library.loading = true;
const beforeRuntime = JSON.stringify(await readiness.bridge.command('runtimeSnapshot'));
const beforeFull = await readiness.bridge.command('snapshot');
readiness.library.loading = false;
const afterRuntime = JSON.stringify(await readiness.bridge.command('runtimeSnapshot'));
const afterFull = await readiness.bridge.command('snapshot');
assert.equal(beforeFull.libraryReady, false);
assert.equal(afterFull.libraryReady, true);

const schedule = readFileSync(new URL(
    '../Tunes/Samply/Web/SamplyPollSchedule.swift', import.meta.url), 'utf8');
const fullInterval = Number(schedule.match(/fullContentInterval: TimeInterval = ([\d.]+)/)?.[1]);
const runtimeInterval = Number(schedule.match(/runtimeInterval: TimeInterval = ([\d.]+)/)?.[1]);
assert(Number.isFinite(fullInterval) && Number.isFinite(runtimeInterval));

console.log('Library readiness probe:');
console.log(JSON.stringify({
    fullSnapshotReadinessBefore: beforeFull.libraryReady,
    fullSnapshotReadinessAfter: afterFull.libraryReady,
    runtimePayloadChanged: beforeRuntime !== afterRuntime,
    runtimeIncludesLibraryReady: 'libraryReady' in JSON.parse(afterRuntime),
    runtimeIntervalSeconds: runtimeInterval,
    fullContentIntervalSeconds: fullInterval
}, null, 2));

console.log('\nAlbum navigation work, identical fixture:');
console.log(JSON.stringify([
    await browseProbe(true), await browseProbe(false)
], null, 2));

// Quantify only the adapter's polling observation delay. The synthetic router
// returns immediately and publishes loaded boxes after five milliseconds.
// This is not a model of Samply's network, rendering, or subscription behavior.
const polling = fixture();
const push = polling.router.push.bind(polling.router);
let dataReadyAt;
polling.router.push = async args => {
    await push(args);
    polling.player.playerBoxesLoading = true;
    setTimeout(() => {
        polling.player.playerBoxesLoading = false;
        dataReadyAt = performance.now();
    }, 5);
};
const startedAt = performance.now();
await polling.bridge.command('browse', {routeID: 'share-1', projectID: 'project-1'});
const completedAt = performance.now();
assert(dataReadyAt !== undefined);
console.log('\nInformational readiness sampling probe (synthetic five-ms data wait):');
console.log(JSON.stringify({
    dataReadyMilliseconds: Number((dataReadyAt - startedAt).toFixed(2)),
    browseReplyMilliseconds: Number((completedAt - startedAt).toFixed(2)),
    observationDelayMilliseconds: Number((completedAt - dataReadyAt).toFixed(2))
}, null, 2));
