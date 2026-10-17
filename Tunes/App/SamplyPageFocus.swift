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
