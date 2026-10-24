// Fixture-only phase baseline for the bridge timing side channel.
// No app, account, network, or real Samply store is used.
import {fixture} from './samply-bridge-fixture.mjs';

const warmups = 5;
const samples = 30;

function percentile(values, fraction) {
    const sorted = [...values].sort((a, b) => a - b);
    const index = Math.min(sorted.length - 1, Math.ceil(fraction * sorted.length) - 1);
    return sorted[Math.max(0, index)];
}

async function measure(kind) {
    const router = [];
    const boxes = [];
    const totals = [];
    let responseBytes = 0;
    for (let index = 0; index < warmups + samples; index++) {
        const f = fixture();
        if (kind === 'router') {
            const push = f.router.push.bind(f.router);
            f.router.push = async args => {
                await new Promise(resolve => setTimeout(resolve, 30));
                return push(args);
            };
        } else {
            f.player.playerBoxesLoading = true;
            setTimeout(() => { f.player.playerBoxesLoading = false; }, 70);
        }
        const requestID = 10_000 + index;
        const result = await f.bridge.command('browse', {
            routeID: 'share-1', requestID, debugTiming: true
        });
        const timing = f.bridge.timing(requestID);
        if (index < warmups) continue;
        router.push(timing.routerMilliseconds);
        boxes.push(timing.boxesMilliseconds);
        totals.push(timing.totalMilliseconds);
        responseBytes = Buffer.byteLength(JSON.stringify(result));
    }
    return {
        scenario: kind,
        samples,
        responseBytes,
        routerMedianMs: Number(percentile(router, 0.5).toFixed(2)),
        routerP95Ms: Number(percentile(router, 0.95).toFixed(2)),
        boxesMedianMs: Number(percentile(boxes, 0.5).toFixed(2)),
        boxesP95Ms: Number(percentile(boxes, 0.95).toFixed(2)),
        totalMedianMs: Number(percentile(totals, 0.5).toFixed(2)),
        totalP95Ms: Number(percentile(totals, 0.95).toFixed(2))
    };
}

const results = [await measure('router'), await measure('data')];
console.log(JSON.stringify({warmups, results}, null, 2));
