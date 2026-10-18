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
    let refreshedLibrary = null;
    const finite = (v, fallback = 0) => typeof v === 'number' && Number.isFinite(v) ? v : fallback;
    const text = v => typeof v === 'string' ? v : undefined;
    function globals() {
        const app = document.querySelector('#app')?.__vue_app__;
        const g = app?.config?.globalProperties;
        if (!g?.$pinia?._s || !g?.$router) {
            throw initializationError('Samply Vue/Pinia application is not ready or has changed.');
        }
        return g;
    }
    const store = id => globals().$pinia._s.get(id);
    function requireStore(id, methods = []) {
        const s = store(id);
        if (!s || methods.some(m => typeof s[m] !== 'function'))
            throw operationError(`Samply store contract changed: ${id}. Open the web window to continue.`);
        return s;
    }
    function operationError(message) {
        const error = new Error(message);
        error.code = 'TUNES_OPERATION_FAILED';
        return error;
    }
    function initializationError(message) {
        const error = new Error(message);
        error.code = 'TUNES_NOT_READY';
        return error;
    }
    const image = artwork => text(artwork) || text(artwork?.small?.src) || text(artwork?.medium?.src);
    function libraryView(items, auth, lib) {
        return items.filter(i => !i.archived).map(i => ({
            id: i.id, name: i.name, projectID: text(i.projectid), playerID: text(i.playerid),
            shareID: text(i.shareid), artist: text(i.artist), artwork: image(i.artwork),
            canUpload: lib.canUploadFilesInProject?.(i.id) === true, isOwned: i.owner === auth.uid
        }));
    }
    function account() {
        const auth = store('profile-auth-module');
        if (!auth?.uid || auth.isAnonymous !== false) return null;
        return { uid: auth.uid, name: text(auth.userSnippet?.displayName),
            avatarURL: text(auth.userSnippet?.photoURL) };
    }
    function authenticationState(auth) {
        if (auth) return 'signedIn';
        const profile = store('profile-auth-module');
        // A missing UID is also the initial state while Samply restores its session.
        // Only a resolved anonymous identity confirms that sign-in is needed.
        return profile?.uid && profile.isAnonymous === true ? 'signedOut' : 'checking';
    }
    function assertAccount() {
        if (!account()) throw operationError('Sign in to Samply in the web window first.');
    }
    async function waitFor(test, expectedOperation) {
        const deadline = Date.now() + 20000;
        while (Date.now() < deadline) {
            if (operation !== expectedOperation) throw operationError('Operation superseded.');
            const value = test();
            if (value) return value;
            await new Promise(resolve => setTimeout(resolve, 100));
        }
        throw operationError('Samply did not become ready. Check sign-in, permissions, or processing in the web window.');
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
        // Retain the explicit server read until the live Library subscription publishes
        // a new array, so the next background poll cannot restore its older cached list.
        if (refreshedLibrary && (refreshedLibrary.uid !== auth?.uid || refreshedLibrary.source !== lib?.items))
            refreshedLibrary = null;
        if (auth) syncPlaybackClock();
        const player = store('player'), boxes = store('boxes'), audio = store('audio-module');
        const capabilities = [];
        if (lib && Array.isArray(lib.items)) capabilities.push('library');
        if (boxes && typeof boxes.getBox === 'function') capabilities.push('boxes');
        if (audio && ['play', 'pause', 'seek', 'setVolume', 'loadBox'].every(k => typeof audio[k] === 'function')) capabilities.push('playback');
        const boxesReady = !!auth && !!player?.playerDocumentData && player.playerBoxesLoading === false &&
            boxes?.loadingBoxes === false &&
            player?.shareid === g.$router.currentRoute.value.params.shareid &&
            (boxes.currentLevelId || null) === (g.$router.currentRoute.value.query?.group || null) &&
            Array.isArray(boxes.boxViewModelsCurrentLevel);
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
            version: 1, account: auth, authentication: authenticationState(auth),
            libraryReady: !!auth && (!!refreshedLibrary || lib?.loading === false),
            library: refreshedLibrary?.items || (auth && Array.isArray(lib?.items) ? libraryView(lib.items, auth, lib) : []),
            routeID: text(g.$router.currentRoute.value.params.shareid),
            projectID: text(player?.parentProjectID), levelID: text(boxes?.currentLevelId),
            boxesReady,
            boxes: boxesReady ? (boxes.boxViewModelsCurrentLevel || []).map(vm => boxView(vm, boxes)) : [],
            playback, capabilities
        };
    }
    async function dataAPI() {
        // These are the data-only exports used by this inspected Samply build.
        // Reuse its initialized client and authorization; never access auth SDKs or credentials.
        const src = document.querySelector('script[type="module"][src]')?.src;
        if (!src) throw initializationError('Samply data adapter unavailable.');
        const moduleURL = new URL(src, location.origin);
        if (moduleURL.origin !== location.origin || moduleURL.pathname !== '/assets/index.1817c5c9.js')
            throw operationError('Samply data adapter build changed.');
        const api = await import(moduleURL.href);
        if (!['a9', 'a6', 'a3', 'a5', 'dZ', 'aJ', 'at'].every(k => typeof api[k] === 'function') || !api.a7)
            throw operationError('Samply data adapter contract changed.');
        return api;
    }
    async function withDeadline(promise) {
        let timer;
        try {
            return await Promise.race([promise, new Promise((_, reject) => {
                timer = setTimeout(() => reject(new Error('Samply data refresh timed out.')), 20000);
            })]);
        } finally { clearTimeout(timer); }
    }
    function pageRoute(args) {
        if (args.page === 'library') return {path: '/library'};
        if (args.page !== 'album' || typeof args.routeID !== 'string' || !args.routeID)
            throw operationError('Missing page identity.');
        return {path: '/p/' + encodeURIComponent(args.routeID), query: args.groupID ? {group: args.groupID} : {}};
    }
    async function refreshPage(args) {
        assertAccount();
        pageRoute(args); // Validate the target without navigating or reloading the media document.
        const uid = account().uid;
        const ticket = operation;
        const api = await dataAPI();
        const db = api.a9(), paths = api.a7;
        const stillCurrent = () => account()?.uid === uid && operation === ticket;
        if (args.page === 'library') {
            const query = api.a3(api.a6(db, paths.USERS, uid, paths.HISTORY), api.a5('snippet.archived', '==', false));
            const result = await withDeadline(api.dZ(query)); // getDocsFromServer, never a cached success.
            if (!stillCurrent()) throw operationError('Operation superseded.');
            const items = result.docs.map(doc => {
                const data = doc.data(), snippet = data.snippet;
                if (!snippet) return null;
                return {id: doc.id, name: snippet.name || doc.id, projectid: data.projectid,
                    playerid: data.playerid, shareid: data.shareid, artist: snippet.artist?.displayName || snippet.creator?.displayName,
                    artwork: snippet.artwork, owner: snippet.owner, archived: snippet.archived};
            }).filter(Boolean);
            const lib = requireStore('library');
            refreshedLibrary = {uid, source: lib.items, items: libraryView(items, account(), lib)};
            return {...snapshot(), libraryReady: true};
        }
        const player = requireStore('player');
        const matches = () => player.shareid === args.routeID &&
            globals().$router.currentRoute.value.params.shareid === args.routeID &&
            (store('boxes')?.currentLevelId || null) === (args.groupID || null);
        if (!matches() || !player.playerid || !player.parentProjectID || player.playerBoxesLoading !== false)
            throw initializationError('The selected album is not ready.');
        const playerID = player.playerid;
        let documents;
        if (player.isProjectOwner === true || ['admin', 'editor'].includes(player.projectRole)) {
            documents = (await withDeadline(api.dZ(api.a6(db, paths.PROJECTS, player.parentProjectID, paths.BOXES)))).docs;
        } else {
            // Use Samply's authorized shared-player read, preserving all server-side access checks.
            // Password-protected access may require checking the existing Samply window.
            const result = await withDeadline(api.at().getSecurePlayerBoxContent({playerid: playerID, shareid: args.routeID}));
            documents = result.boxes.map(box => ({id: box.id,
                ref: api.aJ(db, paths.PROJECTS, player.parentProjectID, paths.BOXES, box.id), data: () => box.data}));
        }
        if (!stillCurrent() || !matches() || player.playerid !== playerID) throw operationError('Operation superseded.');
        // Update only the same box snapshots consumed by the existing files store.
        // No router navigation, store reset, queue change, or audio action occurs here.
        player.playerBoxes = documents;
        await Promise.resolve(); // Let Vue invalidate its computed box view models.
        return snapshot();
    }
    async function browse(args) {
        assertAccount();
        const ticket = ++operation;
        const id = args.routeID;
        if (typeof id !== 'string' || !id.length) throw operationError('Missing player identity.');
        const query = args.groupID ? {group: args.groupID} : {};
        await globals().$router.push({path: '/p/' + encodeURIComponent(id), query});
        await waitFor(() => {
            const p = store('player'), b = store('boxes');
            return globals().$router.currentRoute.value.params.shareid === id && p?.shareid === id &&
                p?.playerDocumentData && p.playerBoxesLoading === false && b?.loadingBoxes === false &&
                Array.isArray(b.boxViewModelsCurrentLevel) &&
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
            throw operationError('The selected project is no longer open.');
        const vm = b.getBox(args.fileID);
        const playable = vm && b.getPlayableBoxViewModel(vm);
        if (!playable?.isAudio) throw operationError('This file is not ready or is not playable audio.');
        if (!maySeeVersions()) {
            for (const parentID of b.findParents?.(playable.id) || []) {
                const parent = b.getBox(parentID);
                if (parent?.data?.type === 'stack' && parent.activeid !== playable.id)
                    throw operationError('This player does not allow access to other versions.');
            }
        }
        const raw = b.getBox(playable.id, false);
        if (!raw || !p.playerid || !p.playerDocumentData || !p.parentProjectID || !p.parentProjectData)
            throw operationError('Samply has not granted playback access to this file.');
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
        if (a.error) throw operationError('Samply could not play this file.');
        return snapshot();
    }
    async function command(name, args = {}) {
        if (name === 'snapshot') return snapshot();
        if (name === 'refreshPage') return await refreshPage(args);
        if (name === 'navigatePage') {
            assertAccount();
            ++operation;
            await globals().$router.push(pageRoute(args));
            return true;
        }
        if (name === 'browse') return await browse(args);
        if (name === 'playBox') return await playBox(args);
        if (name === 'versions') {
            const b = requireStore('boxes', ['getBoxVersions']);
            assertAccount();
            if (!maySeeVersions()) throw operationError('This player does not allow access to other versions.');
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
            if (!Number.isFinite(args.value) || !Number.isFinite(a.duration) || a.duration <= 0) throw operationError('This track cannot seek yet.');
            await a.seek(Math.min(Math.max(0, args.value), a.duration)); break;
        }
        case 'volume': {
            if (!Number.isFinite(args.value)) throw operationError('Invalid volume.');
            await a.setVolume(Math.min(Math.max(0, args.value), 1)); break;
        }
        case 'quality':
            if (!['compressed', 'lossless'].includes(args.value)) throw operationError('Invalid quality.');
            if (typeof a.selectQuality !== 'function') throw operationError('Quality selection unavailable.');
            await a.selectQuality(args.value, {inplace: true}); break;
        default: throw operationError('Unsupported Tunes command.');
        }
        return snapshot();
    }
    window.__tunesSamply = Object.freeze({version: 1, command});
})();
