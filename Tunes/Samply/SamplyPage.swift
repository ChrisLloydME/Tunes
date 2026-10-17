import Foundation
import SwiftUI

private struct SamplyPageKey: FocusedValueKey {
    typealias Value = SamplyPage
}

extension FocusedValues {
    var samplyPage: SamplyPage? {
        get { self[SamplyPageKey.self] }
        set { self[SamplyPageKey.self] = newValue }
    }
}

enum SamplyPage: Equatable, Sendable {
    case library
    case album(routeID: String, groupID: String?)

    var arguments: [String: Any] {
        switch self {
        case .library: return ["page": "library"]
        case .album(let routeID, let groupID):
            var arguments: [String: Any] = ["page": "album", "routeID": routeID]
            if let groupID { arguments["groupID"] = groupID }
            return arguments
        }
    }

    var refreshLabel: String {
        switch self {
        case .library: "Refresh Library"
        case .album(_, nil): "Refresh Album"
        case .album: "Refresh Folder"
        }
    }
}
