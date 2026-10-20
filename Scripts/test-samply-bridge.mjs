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
        allowVersions: true, playerDocumentData: {name: 'Shared'}, playerBoxesLoading: false,
        parentProjectData: {name: 'Project'}, defaultQuality: 'lossless'};
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
    const upload = {
        async uploadFileItems(options) {
            calls.push(['uploadArtwork', options]);
            const boxid = 'artwork-box';
            server.projectDocs[options.projectid].artwork = {
                micro: {ref: boxid, src: 'https://example.test/artwork-micro.jpg'},
                small: {ref: boxid, src: 'https://example.test/artwork-small.jpg'},
                medium: {ref: boxid, src: 'https://example.test/artwork-medium.jpg'},
                large: {ref: boxid, src: 'https://example.test/artwork-large.jpg'},
                original: {ref: boxid, src: 'https://example.test/artwork-original.jpg'}
            };
            setTimeout(() => options.uploadTaskCallbacks?.onComplete?.(), 0);
            return [boxid];
        }
    };
    const stores = new Map([['profile-auth-module', auth], ['library', library], ['player', player],
        ['boxes', boxes], ['audio-module', audio], ['upload', upload]]);
    const router = {currentRoute: {value: {params: {shareid: 'share-1'}}},
        async push(route) {
            calls.push(['navigate', route]);
            // The player view resolves a token-bearing external link to the live
            // share route and removes the token from the URL.
            const token = route.query?.token;
            const shareid = token ? 'share-1' : decodeURIComponent(route.path.split('/').pop());
            const {token: _discarded, ...query} = route.query ?? {};
            this.currentRoute.value.path = token ? `/p/${shareid}` : route.path;
            this.currentRoute.value.params.shareid = shareid;
            this.currentRoute.value.query = query;
            player.shareid = shareid; boxes.currentLevelId = query.group;
        }};
    const server = {library: [], boxes: [], projectDocs: {
        'project-1': {owner: 'user-a', roles: {'user-a': {role: 'admin'}}, artwork: undefined}
    }};
    const dataAPI = {
        a9: () => ({}), a7: {USERS: 'users', HISTORY: 'history', PROJECTS: 'projects', BOXES: 'boxes'},
        a6: (_db, ...path) => ({path}), a3: (collection, filter) => ({...collection, filter}),
        a5: (...args) => args, aJ: (_db, ...path) => ({path}),
        async dZ(query) {
            calls.push(['serverRead', query]);
            return {docs: query.path[0] === 'users' ? server.library : server.boxes};
        },
        async dW(ref) {
            calls.push(['serverDoc', ref]);
            const data = server.projectDocs[ref.path.at(-1)];
            return {exists: () => data !== undefined, data: () => data};
        },
        at: () => ({async getSecurePlayerBoxContent(args) {
            calls.push(['sharedRead', args]); return {boxes: server.boxes.map(doc => ({id: doc.id, data: doc.data()}))};
        }})
    };
    const context = {location: {origin}, URL, setTimeout, clearTimeout, File, atob,
        // Replace only the module-loading boundary; all adapter behavior runs unchanged.
        __fixtureImport: async () => dataAPI,
        document: {querySelector(selector) {
            if (selector === 'script[type="module"][src]') return {src: origin + '/assets/index.1817c5c9.js'};
            return {__vue_app__: {config: {globalProperties: {$pinia: {_s: stores}, $router: router}}}};
        }}};
    context.window = context;
    context.top = context;
    vm.createContext(context);
    vm.runInContext(script.replace('import(moduleURL.href)', '__fixtureImport(moduleURL.href)'), context);
    return {bridge: context.__tunesSamply, context, calls, audio, player, boxes, stores, auth, library, router, server, dataAPI};
}
const plain = value => JSON.parse(JSON.stringify(value));

test('profile snapshot includes only display metadata and tolerates missing profile fields', async () => {
    const f = fixture();
    f.auth.userSnippet = {displayName: '测试 Artist', photoURL: 'https://example.test/avatar.png',
        email: 'private@example.test', accessToken: 'NEVER_SERIALIZE_THIS'};
    assert.deepEqual(plain((await f.bridge.command('snapshot')).account), {
        uid: 'user-a', name: '测试 Artist', avatarURL: 'https://example.test/avatar.png'
    });
    delete f.auth.userSnippet;
    assert.deepEqual(plain((await f.bridge.command('snapshot')).account), {uid: 'user-a'});
    f.auth.isAnonymous = true;
    assert.equal((await f.bridge.command('snapshot')).account, null);
});

test('page initialization has a distinct retryable error and recovers without reinstalling the adapter', async () => {
    const f = fixture();
    const querySelector = f.context.document.querySelector;
    f.context.document.querySelector = () => null;
    await assert.rejects(f.bridge.command('snapshot'), error => error.code === 'TUNES_NOT_READY');
    f.context.document.querySelector = querySelector;
    assert.equal((await f.bridge.command('snapshot')).account.uid, 'user-a');
});

test('known rejected actions are distinct from transient page initialization', async () => {
    const f = fixture({anonymous: true});
    await assert.rejects(f.bridge.command('play'), error => error.code === 'TUNES_OPERATION_FAILED');
    assert.deepEqual(f.calls, []);
    f.auth.isAnonymous = false;
    await assert.rejects(f.bridge.command('seek', {value: 'invalid'}), error => error.code === 'TUNES_OPERATION_FAILED');
    assert.deepEqual(f.calls, []);
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

test('completed session restoration with no user is signed out after relaunch', async () => {
    const f = fixture();
    const profile = {uid: null, isAnonymous: null, onAuthFired: false};
    f.stores.set('profile-auth-module', profile);
    assert.equal((await f.bridge.command('snapshot')).authentication, 'checking');
    profile.onAuthFired = true;
    const snapshot = await f.bridge.command('snapshot');
    assert.equal(snapshot.authentication, 'signedOut');
    assert.equal(snapshot.account, null);
    assert.equal(snapshot.libraryReady, false);
    assert.deepEqual(plain(snapshot.library), []);
    assert.equal(snapshot.playback, null);

    // A later sign-in must recover in the same document without resetting the adapter.
    Object.assign(profile, {uid: 'user-a', isAnonymous: false});
    assert.equal((await f.bridge.command('snapshot')).authentication, 'signedIn');
    Object.assign(profile, {uid: null, isAnonymous: null});
    assert.equal((await f.bridge.command('snapshot')).authentication, 'signedOut');
});

test('missing or incomplete auth readiness does not falsely expire a restoring session', async () => {
    const f = fixture();
    for (const profile of [
        {uid: null, isAnonymous: null},
        {uid: null, isAnonymous: null, onAuthFired: 'true'},
        {uid: null, isAnonymous: false, onAuthFired: true},
        {uid: 'user-a', isAnonymous: null, onAuthFired: true}
    ]) {
        f.stores.set('profile-auth-module', profile);
        assert.equal((await f.bridge.command('snapshot')).authentication, 'checking');
    }
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

test('opens an empty project through a tokenized player URL with matching project identity', async () => {
    const f = fixture();
    f.boxes.boxViewModelsCurrentLevel = [];
    const snapshot = await f.bridge.command('browse', {
        routeID: 'project-1', token: 'share-1', projectID: 'project-1'
    });
    assert.equal(snapshot.boxesReady, true);
    assert.deepEqual(plain(snapshot.boxes), []);
    assert.equal(snapshot.projectID, 'project-1');
    assert.equal(snapshot.routeID, 'share-1');
    assert.deepEqual(plain(f.calls), [['navigate', {
        path: '/p/project-1', query: {token: 'share-1'}
    }]]);
});

test('rejects a loaded player whose project identity differs from the requested project', async () => {
    const f = fixture();
    f.player.parentProjectID = 'project-other';
    await assert.rejects(f.bridge.command('browse', {
        routeID: 'project-1', token: 'share-1', projectID: 'project-1'
    }), /did not match/);
});

test('assigns project artwork through the authorized hidden system upload', async () => {
    const f = fixture();
    const result = await f.bridge.command('setProjectArtwork', {
        projectID: 'project-1', fileName: 'cover.jpg', mimeType: 'image/jpeg',
        dataBase64: Buffer.from([1, 2, 3]).toString('base64')
    });
    assert.equal(result.status, 'confirmed');
    const upload = f.calls.find(call => call[0] === 'uploadArtwork');
    assert.equal(upload[1].projectid, 'project-1');
    assert.equal(upload[1].writeback, 'project');
    assert.equal(upload[1].isSystem, true);
    assert.equal(upload[1].isHidden, false);
    assert.equal(f.server.projectDocs['project-1'].artwork.small.ref, 'artwork-box');
    assert.equal(f.calls.some(call => call[0] === 'navigate'), false);
});

test('reports an unsupported artwork contract instead of inventing a write path', async () => {
    const f = fixture();
    f.stores.delete('upload');
    const result = await f.bridge.command('setProjectArtwork', {
        projectID: 'project-1', fileName: 'cover.jpg', mimeType: 'image/jpeg',
        dataBase64: Buffer.from([1, 2, 3]).toString('base64')
    });
    assert.equal(result.status, 'unsupported');
    assert.equal(f.calls.some(call => call[0] === 'uploadArtwork'), false);
});

test('does not report unloaded view models or the previous folder as an empty album', async () => {
    const f = fixture();
    const models = f.boxes.boxViewModelsCurrentLevel;
    f.boxes.boxViewModelsCurrentLevel = undefined;
    assert.equal((await f.bridge.command('snapshot')).boxesReady, false);
    const browsing = f.bridge.command('browse', {routeID: 'share-2'});
    setTimeout(() => { f.boxes.boxViewModelsCurrentLevel = models; }, 5);
    const loaded = await browsing;
    assert.equal(loaded.boxesReady, true);
    assert.equal(loaded.boxes[0].id, 'file-1');
    f.router.currentRoute.value.query = {group: 'new-folder'};
    assert.equal((await f.bridge.command('snapshot')).boxesReady, false);
    f.boxes.currentLevelId = 'new-folder';
    f.boxes.boxViewModelsCurrentLevel = [];
    const empty = await f.bridge.command('snapshot');
    assert.equal(empty.boxesReady, true);
    assert.equal(empty.boxes.length, 0);
});

test('waits for the player subscription even when the boxes store already claims it is ready', async () => {
    const f = fixture();
    const models = f.boxes.boxViewModelsCurrentLevel;
    f.player.playerBoxesLoading = true;
    f.boxes.loadingBoxes = false;
    f.boxes.boxViewModelsCurrentLevel = [];
    assert.equal((await f.bridge.command('snapshot')).boxesReady, false);
    const browsing = f.bridge.command('browse', {routeID: 'share-2'});
    let finished = false;
    browsing.then(() => { finished = true; });
    await new Promise(resolve => setTimeout(resolve, 120));
    assert.equal(finished, false);
    f.boxes.boxViewModelsCurrentLevel = models;
    f.player.playerBoxesLoading = false;
    const loaded = await browsing;
    assert.equal(loaded.boxesReady, true);
    assert.equal(loaded.boxes[0].id, 'file-1');
    f.boxes.boxViewModelsCurrentLevel = [];
    assert.equal((await f.bridge.command('snapshot')).boxesReady, true);
});

const serverDocument = (id, data) => ({id, data: () => data});
function installRefreshedBoxModels(f) {
    let documents = [];
    Object.defineProperty(f.player, 'playerBoxes', {
        get: () => documents,
        set(value) {
            documents = value;
            f.boxes.boxViewModelsCurrentLevel = value.map(doc => ({id: doc.id, name: doc.data().name,
                data: doc.data(), isAudio: true, activeid: doc.id}));
        }
    });
}
function playingState(f) {
    f.audio.audioboxid = 'playing-file'; f.audio.playing = true; f.audio.currentTime = 42;
    return plain(f.audio);
}

test('Library refresh reads server history, including shared items, without navigating or touching playback', async () => {
    const f = fixture();
    const before = playingState(f);
    f.server.library = [serverDocument('shared-new', {projectid: 'project-b', playerid: 'player-b', shareid: 'share-b',
        snippet: {name: 'Updated shared album', owner: 'user-b', artist: {displayName: 'Artist'}}})];
    const result = await f.bridge.command('refreshPage', {page: 'library'});
    assert.equal(result.library[0].name, 'Updated shared album');
    assert.equal(result.library[0].shareID, 'share-b');
    assert.equal(result.library[0].isOwned, false);
    assert.equal((await f.bridge.command('snapshot')).library[0].name, 'Updated shared album');
    f.library.items = [{id: 'live-change', name: 'Later live change'}];
    assert.equal((await f.bridge.command('snapshot')).library[0].name, 'Later live change');
    assert.deepEqual(plain(f.calls), [['serverRead', {path: ['users', 'user-a', 'history'], filter: ['snippet.archived', '==', false]}]]);
    assert.deepEqual(plain(f.audio), before);
    assert.equal(f.router.currentRoute.value.params.shareid, 'share-1');
});

test('album and folder refresh replace only box data, keeping track, position, queue and playback unchanged', async () => {
    const f = fixture();
    const before = playingState(f);
    installRefreshedBoxModels(f);
    f.player.isProjectOwner = true;
    f.boxes.currentLevelId = 'folder-1';
    f.router.currentRoute.value.query = {group: 'folder-1'};
    f.server.boxes = [serverDocument('updated-file', {type: 'file', name: 'Updated track'})];
    const result = await f.bridge.command('refreshPage', {page: 'album', routeID: 'share-1', groupID: 'folder-1'});
    assert.equal(result.boxes[0].name, 'Updated track');
    assert.equal(result.levelID, 'folder-1');
    assert.deepEqual(plain(f.calls), [['serverRead', {path: ['projects', 'project-1', 'boxes']}]]);
    assert.deepEqual(plain(f.audio), before);
});

test('shared albums refresh through Samply authorized player content without changing access settings', async () => {
    const f = fixture();
    const before = playingState(f);
    installRefreshedBoxModels(f);
    f.server.boxes = [serverDocument('updated-file', {type: 'file', name: 'Shared update'})];
    const result = await f.bridge.command('refreshPage', {page: 'album', routeID: 'share-1'});
    assert.equal(result.boxes[0].name, 'Shared update');
    assert.deepEqual(plain(f.calls), [['sharedRead', {playerid: 'player-1', shareid: 'share-1'}]]);
    assert.deepEqual(plain(f.audio), before);
    assert.equal(f.player.allowVersions, true);
});

test('denied refresh preserves existing contents and playback without any fallback', async () => {
    const f = fixture();
    const before = playingState(f), contents = f.boxes.boxViewModelsCurrentLevel;
    f.dataAPI.at = () => ({async getSecurePlayerBoxContent() { throw new Error('Denied'); }});
    await assert.rejects(f.bridge.command('refreshPage', {page: 'album', routeID: 'share-1'}), /Denied/);
    assert.equal(f.boxes.boxViewModelsCurrentLevel, contents);
    assert.deepEqual(plain(f.audio), before);
    assert.deepEqual(f.calls, []);
});

test('Open in Samply navigates to the requested Library, album, or folder without audio actions', async () => {
    const f = fixture();
    const before = playingState(f);
    assert.equal(await f.bridge.command('navigatePage', {page: 'library'}), true);
    assert.equal(await f.bridge.command('navigatePage', {page: 'album', routeID: 'share /2'}), true);
    assert.equal(await f.bridge.command('navigatePage', {page: 'album', routeID: 'share /2', groupID: 'folder-2'}), true);
    assert.deepEqual(plain(f.calls), [
        ['navigate', {path: '/library'}],
        ['navigate', {path: '/p/share%20%2F2', query: {}}],
        ['navigate', {path: '/p/share%20%2F2', query: {group: 'folder-2'}}]
    ]);
    assert.deepEqual(plain(f.audio), before);
});

test('navigation or account change discards an in-flight refresh before replacing any box data', async () => {
    for (const changeAccount of [false, true]) {
        const f = fixture();
        const before = playingState(f);
        installRefreshedBoxModels(f);
        f.player.isProjectOwner = true;
        let finish;
        f.dataAPI.dZ = () => new Promise(resolve => { finish = resolve; });
        const refreshing = f.bridge.command('refreshPage', {page: 'album', routeID: 'share-1'});
        await new Promise(resolve => setImmediate(resolve));
        if (changeAccount) f.auth.uid = 'user-b';
        else await f.bridge.command('navigatePage', {page: 'library'});
        finish({docs: [serverDocument('stale', {type: 'file', name: 'Stale track'})]});
        await assert.rejects(refreshing, /superseded/);
        assert.equal(f.player.playerBoxes.length, 0);
        assert.deepEqual(plain(f.audio), before);
    }
});

test('refreshing a temporarily loading album remains retryable without touching its contents or audio', async () => {
    const f = fixture();
    const before = playingState(f);
    f.player.playerBoxesLoading = true;
    await assert.rejects(f.bridge.command('refreshPage', {page: 'album', routeID: 'share-1'}),
        error => error.code === 'TUNES_NOT_READY');
    assert.deepEqual(f.calls, []);
    assert.deepEqual(plain(f.audio), before);
    f.player.playerBoxesLoading = false;
    installRefreshedBoxModels(f);
    f.server.boxes = [serverDocument('ready-track', {type: 'file', name: 'Ready'})];
    const result = await f.bridge.command('refreshPage', {page: 'album', routeID: 'share-1'});
    assert.equal(result.boxes[0].name, 'Ready');
    assert.deepEqual(plain(f.audio), before);
});
