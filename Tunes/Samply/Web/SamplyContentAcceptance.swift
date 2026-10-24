import Foundation
import Observation

/// Holds the accepted Library and box arrays and rejects identical assignments.
///
/// Equality includes every field and the order, so a rename, artwork update,
/// permission change, processing completion, or version change is accepted while
/// repeated identical snapshots cause no observable assignment. Loading is kept
/// separate in `AlbumLoadState`, so a confirmed empty album is not confused with
/// "no read yet".
@MainActor
@Observable
final class SamplyContentAcceptance {
    private(set) var library: [LibraryItem] = []
    private(set) var boxes: [WebBox] = []

    /// Local assignment counters for acceptance tests and diagnostics.
    @ObservationIgnored private(set) var libraryAssignmentCount = 0
    @ObservationIgnored private(set) var boxAssignmentCount = 0

    @discardableResult
    func acceptLibrary(_ incoming: [LibraryItem]) -> Bool {
        // Compare before assigning the observed field so identical input does
        // not emit an Observation notification through a mutating accessor.
        guard library != incoming else { return false }
        library = incoming
        libraryAssignmentCount &+= 1
        return true
    }

    @discardableResult
    func acceptBoxes(_ incoming: [WebBox]) -> Bool {
        guard boxes != incoming else { return false }
        boxes = incoming
        boxAssignmentCount &+= 1
        return true
    }

    /// Applies a created-project update in place instead of replacing a newer
    /// Library snapshot. The item identity must already be present.
    @discardableResult
    func replaceLibraryItem(_ item: LibraryItem) -> Bool {
        guard let index = library.firstIndex(where: { $0.id == item.id }),
              library[index] != item else { return false }
        library[index] = item
        libraryAssignmentCount &+= 1
        return true
    }

    func clear() {
        acceptLibrary([])
        acceptBoxes([])
    }
}
