import Foundation

/// Whether the iDiktat keyboard is added and has Full Access, for step 2 in the app.
///
/// iOS offers no API for an app to ask this about its own keyboard. So the keyboard reports
/// `hasFullAccess` through the App Group each time it appears (`AppBridge.report`), and the
/// app reads that. Whether the keyboard is added at all comes from the system's list of
/// active keyboards, when iOS makes it readable.
@MainActor
final class KeyboardSetup: ObservableObject {
    enum Status: Equatable {
        /// The keyboard is not in the list of active keyboards.
        case notAdded
        /// Added (or unknown), but the keyboard has not confirmed Full Access yet.
        case awaitingFullAccess
        /// The keyboard reported that Full Access is granted.
        case ready
    }

    @Published private(set) var status = Status.awaitingFullAccess

    private var observer: AppBridge.Observer?
    private let keyboardID = (Bundle.main.bundleIdentifier ?? "de.cafe-megabyte.iDiktat") + ".Keyboard"

    init() {
        // Updates live when the keyboard is opened, e.g. in the test field of this app.
        observer = AppBridge.Observer(AppBridge.keyboardNotification) { [weak self] in self?.refresh() }
        refresh()
    }

    func refresh() {
        let fullAccess = AppBridge.readKeyboardStatus()?.fullAccess == true
        status = switch (isAdded, fullAccess) {
        case (false, _): .notAdded
        case (_, true): .ready
        case (_, false): .awaitingFullAccess
        }
    }

    /// nil when iOS does not expose the list; then only the keyboard's own report counts.
    private var isAdded: Bool? {
        (UserDefaults.standard.array(forKey: "AppleKeyboards") as? [String]).map { $0.contains(keyboardID) }
    }
}
