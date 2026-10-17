import Foundation

/// Presents the current Samply level as an album without counting folders or documents as songs.
struct AlbumContents {
    let tracks: [WebBox]
    let folders: [WebBox]

    init(boxes: [WebBox]) {
        tracks = boxes.filter { $0.kind != "folder" && ($0.isAudio || $0.kind == "stack") }
        folders = boxes.filter { $0.kind == "folder" }
    }

    var firstPlayableTrack: WebBox? { tracks.first { $0.isAudio && !$0.isProcessing } }

    var metadataText: String {
        let count = tracks.count == 1 ? "1 song" : "\(tracks.count) songs"
        // Missing durations must not be presented as a complete album running time.
        guard !tracks.isEmpty, tracks.allSatisfy({ ($0.duration ?? 0) > 0 && $0.duration?.isFinite == true }) else {
            return count
        }
        let total = tracks.reduce(0.0) { min(864000, $0 + min($1.duration ?? 0, 864000)) }
        let seconds = Int(total)
        let duration = seconds >= 3600
            ? "\(seconds / 3600) hr \((seconds % 3600) / 60) min"
            : seconds >= 60 ? "\(seconds / 60) min" : "\(seconds) sec"
        return "\(count) • \(duration)"
    }

    static func durationText(_ duration: Double?) -> String {
        guard let duration, duration.isFinite, duration >= 0 else { return "—" }
        let seconds = Int(min(duration, 864000))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
