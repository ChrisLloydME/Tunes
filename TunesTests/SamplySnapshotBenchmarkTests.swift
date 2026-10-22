import Foundation
import Testing
@testable import Tunes

/// T0 informational baseline for native snapshot decoding.
///
/// Timing is Debug-build wall clock on a shared machine, so it is printed for
/// comparison rather than asserted. Counts and payload bytes are deterministic
/// and asserted. Samply network and WebKit serialization are not measured here.
struct SamplySnapshotBenchmarkTests {
    private let warmups = 5
    private let measured = 30

    private func libraryItem(_ index: Int) -> LibraryItem {
        LibraryItem(id: "library-\(index)", name: "Library \(index)",
                    projectID: "project-\(index)", playerID: "player-\(index)",
                    shareID: "share-\(index)", artist: "Artist \(index)",
                    artwork: "https://example.test/artwork-\(index).png",
                    canUpload: index % 7 == 0, isOwned: index % 3 == 0)
    }

    private func box(_ index: Int) -> WebBox {
        let kind = index % 10 == 0 ? "folder" : index % 10 == 1 ? "stack" : "file"
        return WebBox(id: "box-\(index)", name: "Box \(index)", kind: kind,
                      activeID: kind == "folder" ? "box-\(index)" : nil,
                      duration: kind == "file" ? Double(60 + index) : nil,
                      isAudio: kind == "file", isProcessing: index % 7 == 0,
                      versionName: kind == "stack" ? "Version \(index)" : nil,
                      childIDs: kind == "stack" ? ["box-\(index)"] : [])
    }

    private func payload(libraryCount: Int, boxCount: Int) -> (data: Data, snapshot: WebSnapshot) {
        let snapshot = WebSnapshot(
            version: 1,
            account: .init(uid: "fixture-account", name: "Fixture"),
            libraryReady: true,
            library: (0..<libraryCount).map(libraryItem),
            routeID: "share-0", projectID: "project-0",
            boxesReady: true,
            boxes: (0..<boxCount).map(box),
            capabilities: ["library", "boxes", "playback"])
        let data = try! JSONEncoder().encode(snapshot)
        return (data, snapshot)
    }

    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, Int(ceil(fraction * Double(sorted.count))) - 1)
        return sorted[max(0, index)]
    }

    private func measureDecode(libraryCount: Int, boxCount: Int) -> String {
        let (data, source) = payload(libraryCount: libraryCount, boxCount: boxCount)
        for _ in 0..<warmups {
            _ = try? JSONDecoder().decode(WebSnapshot.self, from: data)
        }
        var samples: [Double] = []
        var decoded: WebSnapshot?
        for _ in 0..<measured {
            let started = DispatchTime.now().uptimeNanoseconds
            decoded = try? JSONDecoder().decode(WebSnapshot.self, from: data)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            samples.append(elapsed)
        }
        #expect(decoded?.library.count == libraryCount)
        #expect(decoded?.boxes.count == boxCount)
        #expect(decoded?.library.first?.shareID == source.library.first?.shareID)
        #expect(data.count > libraryCount + boxCount)
        let median = percentile(samples, 0.5)
        let p95 = percentile(samples, 0.95)
        return "library=\(libraryCount) boxes=\(boxCount) bytes=\(data.count) " +
            "median=\(String(format: "%.3f", median))ms p95=\(String(format: "%.3f", p95))ms"
    }

    @Test func libraryDecodingBaselineAtTenOneHundredAndOneThousandItems() {
        for count in [10, 100, 1_000] {
            print("T0 decode baseline \(measureDecode(libraryCount: count, boxCount: 0))")
        }
    }

    @Test func boxDecodingBaselineAtZeroOneHundredAndOneThousandBoxes() {
        for count in [0, 100, 1_000] {
            print("T0 decode baseline \(measureDecode(libraryCount: 10, boxCount: count))")
        }
    }
}
