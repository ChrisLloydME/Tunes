// Simulated Samply page for bridge protocol tests and the T0 benchmark.
// Nothing here contacts a live site: the adapter runs unchanged in a Node VM
// against plain Vue/Pinia store stubs.
import vm from 'node:vm';
import {readFileSync} from 'node:fs';

export const script = readFileSync(new URL('../Tunes/Resources/SamplyBridge.js', import.meta.url), 'utf8');

/// Builds a fixture. `libraryCount` and `boxCount` replace the small default
/// collections with synthetic stress data while preserving permission,
/// folder, version, and processing fields.
export function fixture({origin = 'https://samply.app', anonymous = false,
    libraryCount = null, boxCount = null} = {}) {
    const calls = [];
    const file = {id: 'file-1', name: 'Mix', data: {type: 'file', mimeType: 'audio/wav'},
        activeid: 'file-1', activeData: {audio: {duration: 120}}, isAudio: true, duration: 120};
    const raw = {type: 'file', mimeType: 'audio/wav', audio: {duration: 120}};

    function syntheticLibraryItem(index) {
        return {
            id: `library-${index}`,
            name: `Library ${index}`,
            projectid: `project-${index}`,
            playerid: `player-${index}`,
            shareid: `share-${index}`,
            artist: `Artist ${index}`,
            artwork: {small: {src: `https://example.test/artwork-${index}.png`}},
            owner: index % 3 === 0 ? 'user-a' : 'user-b'
        };
    }

    function syntheticBox(index) {
        const type = index % 10 === 0 ? 'group' : index % 10 === 1 ? 'stack' : 'file';
        const data = {type, name: `Box ${index}`,
            audio: type === 'file' ? {duration: 60 + index} : undefined,
            version: type === 'stack' ? `Version ${index}` : undefined};
        return {
            id: `box-${index}`,
            name: `Box ${index}`,
            data,
            duration: type === 'file' ? 60 + index : undefined,
            isAudio: type === 'file',
            isProcessing: index % 7 === 0,
            versionName: type === 'stack' ? `Version ${index}` : undefined
        };
    }

    const defaultLibraryItems = [
        {id: 'project-1', projectid: 'project-1', playerid: 'project-1', shareid: 'own-share', name: 'Owned', owner: 'user-a'},
        {id: 'player-1', projectid: 'project-1', playerid: 'player-1', shareid: 'share-1', name: 'Shared', owner: 'user-b'},
        {id: 'archive', name: 'Archive', archived: true}
    ];
    const libraryItems = libraryCount === null
        ? defaultLibraryItems
        : Array.from({length: libraryCount}, (_, index) => syntheticLibraryItem(index));

    const defaultBoxes = [file];
    const generatedBoxes = boxCount === null ? null
        : Array.from({length: boxCount}, (_, index) => syntheticBox(index));
    const currentBoxes = generatedBoxes ?? defaultBoxes;
    const visibleLevel = generatedBoxes ? null : undefined;

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
    const boxes = {
        loadingBoxes: false,
        boxViewModelsCurrentLevel: currentBoxes,
        currentLevelId: visibleLevel,
        audioBoxes: [{id: file.id, data: raw}],
        getBox(id, viewModel = true) {
            if (generatedBoxes) {
                const match = generatedBoxes.find(box => box.id === id);
                return match ? (viewModel ? match : match.data) : undefined;
            }
            return id === file.id ? viewModel ? file : raw : undefined;
        },
        getPlayableBoxViewModel(value) { return value; },
        getBoxVersions() { return generatedBoxes ? [] : [file]; },
        isBoxProcessing(id) {
            if (generatedBoxes) return generatedBoxes.find(box => box.id === id)?.isProcessing === true;
            return false;
        }
    };
    const auth = {uid: 'user-a', isAnonymous: anonymous, userSnippet: {displayName: 'Test'},
        user: {accessToken: 'NEVER_SERIALIZE_THIS'}};
    const library = {loading: false, items: libraryItems,
        canUploadFilesInProject(id) { return id === 'project-1'; }};
    const stores = new Map([['profile-auth-module', auth], ['library', library], ['player', player],
        ['boxes', boxes], ['audio-module', audio]]);
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
    return {bridge: context.__tunesSamply, context, calls, audio, player, boxes, stores, auth, library,
        router, server, dataAPI, libraryCount, boxCount};
}
