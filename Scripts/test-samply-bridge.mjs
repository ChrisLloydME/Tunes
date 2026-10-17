import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFileSync} from 'node:fs';

const script = readFileSync(new URL('../Tunes/Resources/SamplyBridge.js', import.meta.url), 'utf8');
function fixture({origin = 'https://samply.app', anonymous = false} = {}) {
    const calls = [];
    const file = {id: 'file-1', name: 'Mix', data: {type: 'file', mimeType: 'audio/wav'},
        activeid: 'file-1', activeData: {audio: {duration: 120}}, isAudio: true, duration: 120};
    const raw = {type: 'file', mimeType: 'audio/wav', audio: {duration: 120}};
    const audio = {
        audioboxid: undefined, metadata: {title: 'Mix'}, loading: false, playing: false,
        currentTime: 5, duration: 120, volume: 0.7, queue: [{id: 'file-1'}, {id: 'file-2'}],
        play() { calls.push(['play']); this.playing = true; },
        pause() { calls.push(['pause']); this.playing = false; },
        seek(value) { calls.push(['seek', value]); this.currentTime = value; },
        setVolume(value) { calls.push(['volume', value]); this.volume = value; },
        skipNext() { calls.push(['next']); }, skipPrevious() { calls.push(['previous']); },
        selectQuality(value, options) { calls.push(['quality', value, options]); },
        async loadBox(box, options) {
            calls.push(['loadBox', box, options]); this.audioboxid = box.id; this.playing = true;
        }
    };
    const player = {shareid: 'share-1', playerid: 'player-1', parentProjectID: 'project-1',
        allowVersions: true, playerDocumentData: {name: 'Shared'}, parentProjectData: {name: 'Project'}, defaultQuality: 'lossless'};
    const boxes = {loadingBoxes: false, boxViewModelsCurrentLevel: [file], audioBoxes: [{id: file.id, data: raw}],
        getBox(id, viewModel = true) { return id === file.id ? viewModel ? file : raw : undefined; },
        getPlayableBoxViewModel(value) { return value; }, getBoxVersions() { return [file]; },
        isBoxProcessing() { return false; }};
    const auth = {uid: 'user-a', isAnonymous: anonymous, userSnippet: {displayName: 'Test'},
        user: {accessToken: 'NEVER_SERIALIZE_THIS'}};
    const library = {loading: false, items: [
        {id: 'project-1', projectid: 'project-1', playerid: 'project-1', shareid: 'own-share', name: 'Owned', owner: 'user-a'},
        {id: 'player-1', projectid: 'project-1', playerid: 'player-1', shareid: 'share-1', name: 'Shared', owner: 'user-b'},
        {id: 'archive', name: 'Archive', archived: true}
    ], canUploadFilesInProject(id) { return id === 'project-1'; }};
    const stores = new Map([['profile-auth-module', auth], ['library', library], ['player', player],
        ['boxes', boxes], ['audio-module', audio]]);
    const router = {currentRoute: {value: {params: {shareid: 'share-1'}}},
        async push(route) {
            calls.push(['navigate', route]);
            const shareid = decodeURIComponent(route.path.split('/').pop());
            this.currentRoute.value.path = route.path;
            this.currentRoute.value.params.shareid = shareid;
            player.shareid = shareid; boxes.currentLevelId = route.query?.group;
        }};
    const context = {location: {origin}, setTimeout, clearTimeout,
        document: {querySelector() { return {__vue_app__: {config: {globalProperties: {$pinia: {_s: stores}, $router: router}}}}; }}};
    context.window = context;
    context.top = context;
    vm.createContext(context);
    vm.runInContext(script, context);
    return {bridge: context.__tunesSamply, context, calls, audio, player, boxes, stores, auth, library, router};
}
const plain = value => JSON.parse(JSON.stringify(value));

test('page initialization has a distinct retryable error and recovers without reinstalling the adapter', async () => {
    const f = fixture();
    const querySelector = f.context.document.querySelector;
    f.context.document.querySelector = () => null;
    await assert.rejects(f.bridge.command('snapshot'), error => error.code === 'TUNES_NOT_READY');
    f.context.document.querySelector = querySelector;
    assert.equal((await f.bridge.command('snapshot')).account.uid, 'user-a');
});

test('session restoration stays checking until a real or anonymous identity resolves', async () => {
    const f = fixture();
    f.stores.delete('profile-auth-module');
    assert.equal((await f.bridge.command('snapshot')).authentication, 'checking');
    f.stores.set('profile-auth-module', {isAnonymous: false});
    assert.equal((await f.bridge.command('snapshot')).authentication, 'checking');
    f.stores.set('profile-auth-module', {isAnonymous: true});
    assert.equal((await f.bridge.command('snapshot')).authentication, 'checking');
    f.stores.set('profile-auth-module', f.auth);
    assert.equal((await f.bridge.command('snapshot')).authentication, 'signedIn');
    f.auth.isAnonymous = true;
    assert.equal((await f.bridge.command('snapshot')).authentication, 'signedOut');
    f.auth.isAnonymous = false;
    assert.equal((await f.bridge.command('snapshot')).authentication, 'signedIn');
});

// Samply normally invokes this callback from requestAnimationFrame, which WebKit
// can suspend while the app-owned web window is hidden. No animation frames run here.
function installMediaClock(f, {gapless = false} = {}) {
    const media = {currentTime: gapless ? 125 : 5, paused: false};
    const engine = {audio: media, currentTime: media.currentTime, loading: false,
        opts: {ontimeupdate() {
            engine.currentTime = media.currentTime;
            if (gapless && media.currentTime >= 240) f.audio.audioboxid = 'file-2';
            const start = gapless ? (media.currentTime >= 240 ? 240 : 120) : 0;
            f.audio.currentTime = engine.currentTime - start;
        }}};
    f.audio.audioboxid = 'file-1';
    f.audio.playing = true;
    f.stores.set('audio-shaka-module', engine);
    return {media, engine};
}

test('snapshots advance from the media clock without animation frames or user interaction', async () => {
    const f = fixture();
    const {media} = installMediaClock(f);
    assert.equal((await f.bridge.command('snapshot')).playback.position, 5);
    media.currentTime = 12.75;
    assert.equal((await f.bridge.command('snapshot')).playback.position, 12.75);
    media.currentTime = 21;
    assert.equal((await f.bridge.command('snapshot')).playback.position, 21);
    f.audio.seek = value => {
        f.calls.push(['seek', value]);
        media.currentTime = value;
    };
    assert.equal((await f.bridge.command('seek', {value: 70})).playback.position, 70);
    media.currentTime = 72;
    assert.equal((await f.bridge.command('snapshot')).playback.position, 72);
    media.paused = true;
    f.audio.playing = false;
    const paused = await f.bridge.command('snapshot');
    assert.equal(paused.playback.position, 72);
    assert.equal(paused.playback.playing, false);
    assert.equal((await f.bridge.command('snapshot')).playback.position, 72);
    assert.deepEqual(f.calls, [['seek', 70]]);
});

test('clock sampling preserves Samply gapless offsets and track transitions', async () => {
    const f = fixture();
    const {media} = installMediaClock(f, {gapless: true});
    media.currentTime = 150;
    assert.equal((await f.bridge.command('snapshot')).playback.position, 30);
    media.currentTime = 243;
    const next = await f.bridge.command('snapshot');
    assert.equal(next.playback.fileID, 'file-2');
    assert.equal(next.playback.position, 3);
});

test('does not sample an invalid or still-loading media clock', async () => {
    const f = fixture();
    const {media, engine} = installMediaClock(f);
    media.currentTime = NaN;
    assert.equal((await f.bridge.command('snapshot')).playback.position, 5);
    media.currentTime = 99;
    engine.loading = true;
    assert.equal((await f.bridge.command('snapshot')).playback.position, 5);
});

test('keeps snapshots usable if the optional engine callback is unavailable', async () => {
    const f = fixture();
    const {engine, media} = installMediaClock(f);
    media.currentTime = 20;
    delete engine.opts;
    assert.equal((await f.bridge.command('snapshot')).playback.position, 5);
});

test('library includes shared players, filters archives, and emits no credentials', async () => {
    const f = fixture();
    const s = await f.bridge.command('snapshot');
    assert.deepEqual(plain(s.library.map(x => x.name)), ['Owned', 'Shared']);
    assert.equal(s.library[0].canUpload, true);
    assert.equal(s.library[1].canUpload, false);
    assert.equal(s.account.uid, 'user-a');
    assert(!JSON.stringify(s).includes('NEVER_SERIALIZE_THIS'));
    assert.deepEqual(plain(s.capabilities), ['library', 'boxes', 'playback']);
});

test('does not install on another origin or inside an iframe', () => {
    assert.equal(fixture({origin: 'https://evil.example'}).bridge, undefined);
    const f = fixture(); delete f.context.__tunesSamply; f.context.top = {};
    vm.runInContext(script, f.context);
    assert.equal(f.context.__tunesSamply, undefined);
});

test('anonymous users cannot read the account library or control playback', async () => {
    const f = fixture({anonymous: true});
    const s = await f.bridge.command('snapshot');
    assert.equal(s.account, null); assert.equal(s.library.length, 0);
    await assert.rejects(f.bridge.command('play'), /Sign in/);
});

test('navigates using actual Samply player/group routes', async () => {
    const f = fixture();
    const s = await f.bridge.command('browse', {routeID: 'share-2', groupID: 'folder-1'});
    assert.equal(s.routeID, 'share-2'); assert.equal(s.levelID, 'folder-1');
    assert.deepEqual(plain(f.calls[0]), ['navigate', {path: '/p/share-2', query: {group: 'folder-1'}}]);
});

test('plays via the authorized web store, with original player context and gapless queue', async () => {
    const f = fixture();
    await f.bridge.command('playBox', {routeID: 'share-1', fileID: 'file-1'});
    const call = f.calls.find(x => x[0] === 'loadBox');
    assert.equal(call[1].id, 'file-1'); assert.equal(call[2].player.id, 'player-1');
    assert.equal(call[2].project.id, 'project-1'); assert.equal(call[2].autoplay, true);
    assert.equal(call[2].skipGapless, false); assert.equal(call[2].audioBoxes.length, 1);
    assert.equal(call[2].quality, 'lossless');
    await f.bridge.command('playBox', {routeID: 'share-1', fileID: 'file-1'});
    assert.equal(f.calls.filter(x => x[0] === 'loadBox').length, 1);
});

test('rejects a stale selection, unavailable file, or missing access context', async () => {
    const f = fixture();
    await assert.rejects(f.bridge.command('playBox', {routeID: 'old-share', fileID: 'file-1'}), /no longer open/);
    await assert.rejects(f.bridge.command('playBox', {routeID: 'share-1', fileID: 'missing'}), /not ready/);
    f.player.parentProjectData = null;
    await assert.rejects(f.bridge.command('playBox', {routeID: 'share-1', fileID: 'file-1'}), /not granted/);
    assert.equal(f.calls.length, 0);
});

test('play, pause, seek, volume, next, previous, and quality use player actions', async () => {
    const f = fixture();
    await f.bridge.command('play'); await f.bridge.command('toggle');
    await f.bridge.command('seek', {value: 999}); await f.bridge.command('seek', {value: -10});
    await f.bridge.command('volume', {value: 2}); await f.bridge.command('next');
    await f.bridge.command('previous'); await f.bridge.command('quality', {value: 'lossless'});
    assert.deepEqual(plain(f.calls.slice(0, 7)), [['play'], ['pause'], ['seek', 120], ['seek', 0],
        ['volume', 1], ['next'], ['previous']]);
    assert.equal(f.calls[7][1], 'lossless');
    await assert.rejects(f.bridge.command('seek', {value: NaN}), /cannot seek/);
    await assert.rejects(f.bridge.command('quality', {value: 'unsupported'}), /Invalid quality/);
    await assert.rejects(f.bridge.command('volume', {value: '0.5'}), /Invalid volume/);
});

test('reports changed web contracts clearly and sanitizes nonfinite playback values', async () => {
    const f = fixture(); f.stores.delete('audio-module');
    await assert.rejects(f.bridge.command('play'), /contract changed/);
    f.stores.set('audio-module', {...f.audio, duration: Infinity, currentTime: NaN});
    const s = await f.bridge.command('snapshot');
    assert.equal(s.playback.duration, 0); assert.equal(s.playback.position, 0);
});

test('returns stack versions without mutating library or download permissions', async () => {
    const f = fixture();
    const versions = await f.bridge.command('versions', {fileID: 'stack-1'});
    assert.equal(versions[0].id, 'file-1'); assert.equal(f.calls.length, 0);
});


test('honors disabled versions and does not expose an inactive version through native playback', async () => {
    const f = fixture(); f.player.allowVersions = false;
    await assert.rejects(f.bridge.command('versions', {fileID: 'stack-1'}), /does not allow/);
    const original = f.boxes.getBox;
    f.boxes.findParents = () => ['stack-1'];
    f.boxes.getBox = (id, viewModel) => id === 'stack-1' ?
        {id, activeid: 'other-version', data: {type: 'stack'}} : original(id, viewModel);
    await assert.rejects(f.bridge.command('playBox', {fileID: 'file-1', routeID: 'share-1'}), /does not allow/);
    f.player.projectRole = 'editor';
    const versions = await f.bridge.command('versions', {fileID: 'stack-1'});
    assert.equal(versions.length, 1);
});

test('does not publish stale boxes during a player route transition', async () => {
    const f = fixture(); f.player.shareid = 'previous-share';
    const snapshot = await f.bridge.command('snapshot');
    assert.equal(snapshot.boxesReady, false); assert.equal(snapshot.boxes.length, 0);
});
