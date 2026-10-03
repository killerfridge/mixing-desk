import SwiftUI

private struct DeskCompactKey: EnvironmentKey { static let defaultValue = false }
private struct DeskFaderHeightKey: EnvironmentKey { static let defaultValue: CGFloat = 208 }
extension EnvironmentValues {
    var deskCompact: Bool {
        get { self[DeskCompactKey.self] }
        set { self[DeskCompactKey.self] = newValue }
    }
    var deskFaderHeight: CGFloat {
        get { self[DeskFaderHeightKey.self] }
        set { self[DeskFaderHeightKey.self] = newValue }
    }
}
