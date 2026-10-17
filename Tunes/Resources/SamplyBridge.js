/* Tunes adapter v1. Public Samply build inspected 2026-10-17 (index.1817c5c9.js).
 * Uses the same stores/actions as Samply's FileView. No stream URL extraction,
 * Firebase credentials, download permission changes, or application source copies.
 * Keep this entire undocumented integration behind a versioned contract.
 */
(() => {
    'use strict';
    if (location.origin !== 'https://samply.app' || window.top !== window) return;
    if (window.__tunesSamply?.version === 1) return;
    let operation = 0;
    const finite = (v, fallback = 0) => typeof v === 'number' && Number.isFinite(v) ? v : fallback;
    const text = v => typeof v === 'string' ? v : undefined;
    function globals() {
        const app = document.querySelector('#app')?.__vue_app__;
        const g = app?.config?.globalProperties;
        if (!g?.$pinia?._s || !g?.$router) throw new Error('Samply Vue/Pinia application is not ready or has changed.');
        return g;
    }
    const store = id => globals().$pinia._s.get(id);
    function requireStore(id, methods = []) {
        const s = store(id);
        if (!s || methods.some(m => typeof s[m] !== 'function'))
            throw new Error(`Samply store contract changed: ${id}. Open the web window to continue.`);
        return s;
    }
    const image = artwork => text(artwork) || text(artwork?.small?.src) || text(artwork?.medium?.src);
    function account() {
        const auth = store('profile-auth-module');
        if (!auth?.uid || auth.isAnonymous !== false) return null;
        return { uid: auth.uid, name: text(auth.userSnippet?.displayName) };
    }
    function assertAccount() {
        if (!account()) throw new Error('Sign in to Samply in the web window first.');
    }
    async function waitFor(test, expectedOperation) {
        const deadline = Date.now() + 20000;
        while (Date.now() < deadline) {
            if (operation !== expectedOperation) throw new Error('Operation superseded.');
            const value = test();
            if (value) return value;
            await new Promise(resolve => setTimeout(resolve, 100));
        }
        throw new Error('Samply did not become ready. Check sign-in, permissions, or processing in the web window.');
    }
    function maySeeVersions() {
        const p = store('player');
        return p?.allowVersions === true || p?.isProjectOwner === true || ['admin', 'editor'].includes(p?.projectRole);
    }
    function boxView(vm, boxes) {
        const raw = vm.data || {};
        const children = raw.type === 'stack' && maySeeVersions() ? boxes.getBoxVersions?.(vm.id) || [] : [];
        return {
            id: vm.id, name: vm.name || raw.name || vm.id,
            kind: raw.type === 'group' ? 'folder' : raw.type === 'stack' ? 'stack' : 'file',
            activeID: text(vm.activeid), duration: finite(vm.duration) || undefined,
            isAudio: vm.isAudio === true, isProcessing: boxes.isBoxProcessing?.(vm.id) === true,
            versionName: text(vm.versionName), childIDs: children.map(v => v.id)
        };
    }
    function syncPlaybackClock() {
        // Samply's audio-shaka-module normally samples the media element from
        // requestAnimationFrame. WebKit suspends those frames in our hidden web
        // window even while audio continues. Use its existing time-update path
        // when polling so track-relative time and gapless transitions stay owned
        // by Samply; the native UI must not invent elapsed time or read stream URLs.
        const engine = store('audio-shaka-module');
        const currentTime = engine?.audio?.currentTime;
        if (engine?.loading || !Number.isFinite(currentTime) || currentTime < 0 ||
            currentTime === engine.currentTime) return;
        if (typeof engine?.opts?.ontimeupdate === 'function') engine.opts.ontimeupdate();
    }
    function snapshot() {
        const g = globals(), auth = account(), lib = store('library');
        if (auth) syncPlaybackClock();
        const player = store('player'), boxes = store('boxes'), audio = store('audio-module');
        const capabilities = [];
        if (lib && Array.isArray(lib.items)) capabilities.push('library');
        if (boxes && typeof boxes.getBox === 'function') capabilities.push('boxes');
        if (audio && ['play', 'pause', 'seek', 'setVolume', 'loadBox'].every(k => typeof audio[k] === 'function')) capabilities.push('playback');
        const boxesReady = !!auth && !!player?.playerDocumentData && boxes?.loadingBoxes === false &&
            player?.shareid === g.$router.currentRoute.value.params.shareid;
        let playback = null;
        if (audio && auth) {
            playback = {
                fileID: text(audio.audioboxid), title: text(audio.metadata?.title),
                artist: text(audio.metadata?.artist), album: text(audio.metadata?.album),
                artwork: image(audio.artwork), playing: audio.playing === true,
                loading: audio.loading === true, buffering: audio.buffering === true,
                position: Math.max(0, finite(audio.currentTime)), duration: Math.max(0, finite(audio.duration)),
                volume: finite(audio.volume, 1), quality: text(audio.qualityLoaded),
                error: audio.error ? 'Samply web player reported a playback error.' : undefined,
                canGoNext: (audio.queue?.length || 0) > 1,
                canGoPrevious: (audio.queue?.length || 0) > 1
            };
        }
        return {
            version: 1, account: auth,
            libraryReady: !!auth && lib?.loading === false,
            library: auth && Array.isArray(lib?.items) ? lib.items.filter(i => !i.archived).map(i => ({
                id: i.id, name: i.name, projectID: text(i.projectid), playerID: text(i.playerid),
                shareID: text(i.shareid), artist: text(i.artist), artwork: image(i.artwork),
                canUpload: lib.canUploadFilesInProject?.(i.id) === true, isOwned: i.owner === auth.uid
            })) : [],
            routeID: text(g.$router.currentRoute.value.params.shareid),
            projectID: text(player?.parentProjectID), levelID: text(boxes?.currentLevelId),
            boxesReady,
            boxes: boxesReady ? (boxes.boxViewModelsCurrentLevel || []).map(vm => boxView(vm, boxes)) : [],
            playback, capabilities
        };
    }
    async function browse(args) {
        assertAccount();
        const ticket = ++operation;
        const id = args.routeID;
        if (typeof id !== 'string' || !id.length) throw new Error('Missing player identity.');
        const query = args.groupID ? {group: args.groupID} : {};
        await globals().$router.push({path: '/p/' + encodeURIComponent(id), query});
        await waitFor(() => {
            const p = store('player'), b = store('boxes');
            return globals().$router.currentRoute.value.params.shareid === id && p?.shareid === id &&
                p?.playerDocumentData && b?.loadingBoxes === false &&
                (args.groupID ? b.currentLevelId === args.groupID : !b.currentLevelId);
        }, ticket);
        return snapshot();
    }
    async function playBox(args) {
        assertAccount();
        const ticket = ++operation;
        const p = requireStore('player'), b = requireStore('boxes', ['getBox', 'getPlayableBoxViewModel']);
        const a = requireStore('audio-module', ['loadBox', 'play']);
        if (!args.routeID || globals().$router.currentRoute.value.params.shareid !== args.routeID || p.shareid !== args.routeID)
            throw new Error('The selected project is no longer open.');
        const vm = b.getBox(args.fileID);
        const playable = vm && b.getPlayableBoxViewModel(vm);
        if (!playable?.isAudio) throw new Error('This file is not ready or is not playable audio.');
        if (!maySeeVersions()) {
            for (const parentID of b.findParents?.(playable.id) || []) {
                const parent = b.getBox(parentID);
                if (parent?.data?.type === 'stack' && parent.activeid !== playable.id)
                    throw new Error('This player does not allow access to other versions.');
            }
        }
        const raw = b.getBox(playable.id, false);
        if (!raw || !p.playerid || !p.playerDocumentData || !p.parentProjectID || !p.parentProjectData)
            throw new Error('Samply has not granted playback access to this file.');
        if (a.audioboxid === playable.id) { await a.play(); return snapshot(); }
        // Same authorized objects/options used by Samply FileView's loadBox action.
        await a.loadBox({id: playable.id, data: raw}, {
            audioBoxes: b.audioBoxes,
            player: {id: p.playerid, data: p.playerDocumentData},
            project: {id: p.parentProjectID, data: p.parentProjectData},
            autoplay: true, skipGapless: false, quality: p.defaultQuality,
            loudnessMatch: p.loudnessMatch === true,
            loudnessPlatform: p.loudnessPlatform, targetLufs: p.targetLufs,
            hideComments: true
        });
        await waitFor(() => a.audioboxid === playable.id && !a.loading, ticket);
        if (a.error) throw new Error('Samply could not play this file.');
        return snapshot();
    }
    async function command(name, args = {}) {
        if (name === 'snapshot') return snapshot();
        if (name === 'browse') return await browse(args);
        if (name === 'playBox') return await playBox(args);
        if (name === 'versions') {
            const b = requireStore('boxes', ['getBoxVersions']);
            assertAccount();
            if (!maySeeVersions()) throw new Error('This player does not allow access to other versions.');
            return (b.getBoxVersions(args.fileID) || []).map(vm => boxView(vm, b));
        }
        assertAccount();
        const a = requireStore('audio-module', ['play', 'pause', 'seek', 'setVolume']);
        switch (name) {
        case 'play': await a.play(); break;
        case 'pause': await a.pause(); break;
        case 'toggle': if (a.playing) await a.pause(); else await a.play(); break;
        case 'next': await a.skipNext(); break;
        case 'previous': await a.skipPrevious(); break;
        case 'seek': {
            if (!Number.isFinite(args.value) || !Number.isFinite(a.duration) || a.duration <= 0) throw new Error('This track cannot seek yet.');
            await a.seek(Math.min(Math.max(0, args.value), a.duration)); break;
        }
        case 'volume': {
            if (!Number.isFinite(args.value)) throw new Error('Invalid volume.');
            await a.setVolume(Math.min(Math.max(0, args.value), 1)); break;
        }
        case 'quality':
            if (!['compressed', 'lossless'].includes(args.value)) throw new Error('Invalid quality.');
            if (typeof a.selectQuality !== 'function') throw new Error('Quality selection unavailable.');
            await a.selectQuality(args.value, {inplace: true}); break;
        default: throw new Error('Unsupported Tunes command.');
        }
        return snapshot();
    }
    window.__tunesSamply = Object.freeze({version: 1, command});
})();
