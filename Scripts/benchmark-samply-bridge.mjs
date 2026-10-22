// T0 informational baseline for the local Samply bridge payload.
//
// This measures snapshot construction inside the Node fixture and the
// JSON.stringify/parse boundary that approximates the WebKit string handoff.
// It does not measure Samply network latency, WebKit's own serialization, or
// Swift decoding (see SamplySnapshotBenchmarkTests for that). Wall-clock
// numbers are informational on shared machines; counts and payload bytes are
// deterministic.
import {performance} from 'node:perf_hooks';
import {fixture} from './samply-bridge-fixture.mjs';

const WARMUPS = 5;
const MEASURED = 30;

function percentile(sorted, fraction) {
    if (sorted.length === 0) return 0;
    const index = Math.min(sorted.length - 1, Math.ceil(fraction * sorted.length) - 1);
    return sorted[index];
}

function summarize(samples) {
    const sorted = [...samples].sort((a, b) => a - b);
    const median = percentile(sorted, 0.5);
    const p95 = percentile(sorted, 0.95);
    const average = samples.reduce((sum, value) => sum + value, 0) / samples.length;
    return {median, p95, average};
}

async function measure({libraryCount, boxCount}) {
    const f = fixture({libraryCount, boxCount});
    for (let index = 0; index < WARMUPS; index += 1) {
        await f.bridge.command('snapshot');
    }
    const construction = [];
    const serialization = [];
    let bytes = 0;
    let snapshot = null;
    for (let index = 0; index < MEASURED; index += 1) {
        const constructedAt = performance.now();
        snapshot = await f.bridge.command('snapshot');
        construction.push(performance.now() - constructedAt);
        const serializedAt = performance.now();
        bytes = Buffer.byteLength(JSON.stringify(snapshot));
        JSON.parse(JSON.stringify(snapshot));
        serialization.push(performance.now() - serializedAt);
    }
    if (snapshot.library.length !== (libraryCount ?? 3)) {
        throw new Error(`unexpected Library count ${snapshot.library.length}`);
    }
    if (boxCount !== null && snapshot.boxes.length !== boxCount) {
        throw new Error(`unexpected box count ${snapshot.boxes.length}`);
    }
    return {
        scenario: `library=${libraryCount ?? 'default'} boxes=${boxCount ?? 'default'}`,
        items: snapshot.library.length,
        boxes: snapshot.boxes.length,
        bytes,
        construction: summarize(construction),
        serialization: summarize(serialization)
    };
}

const mm = value => value.toFixed(3);
const kb = value => (value / 1024).toFixed(1);

const scenarios = [
    {libraryCount: 10, boxCount: 0},
    {libraryCount: 100, boxCount: 0},
    {libraryCount: 1000, boxCount: 0},
    {libraryCount: 10, boxCount: 0},
    {libraryCount: 10, boxCount: 100},
    {libraryCount: 10, boxCount: 1000}
];

console.log(`Bridge fixture baseline: ${WARMUPS} warmups, ${MEASURED} measured operations`);
console.log('| Scenario | Items | Boxes | Payload | Build median ms | Build p95 ms | Serialize median ms | Serialize p95 ms |');
console.log('| --- | --- | --- | --- | --- | --- | --- | --- |');
for (const scenario of scenarios) {
    const result = await measure(scenario);
    console.log(`| ${result.scenario} | ${result.items} | ${result.boxes} | ${kb(result.bytes)} KiB | ` +
        `${mm(result.construction.median)} | ${mm(result.construction.p95)} | ` +
        `${mm(result.serialization.median)} | ${mm(result.serialization.p95)} |`);
}
