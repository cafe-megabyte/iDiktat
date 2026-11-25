import Foundation

/// Local link between the iDiktat app and its keyboard.
///
/// Everything stays on the device: settings and messages live in the shared App Group
/// container, and "something changed" signals are Darwin notifications, which carry no data
/// and never leave the phone.
enum AppBridge {
    static let appGroup = "group.de.cafe-megabyte.iDiktat"
    /// Opens the app and starts a session. Registered in Config/App-Info.plist.
    static let sessionURL = URL(string: "idiktat://session")!

    /// Where speech recognition runs.
    enum Mode: String, CaseIterable, Identifiable {
        /// The keyboard records and recognizes by itself. No app switch, but the keyboard's memory limit applies.
        case keyboard
        /// The app records and recognizes in the background; the keyboard only sends start/stop.
        case app

        var id: String { rawValue }
    }

    static var mode: Mode {
        get { defaults.flatMap { Mode(rawValue: $0.string(forKey: "mode") ?? "") } ?? .keyboard }
        set { defaults?.set(newValue.rawValue, forKey: "mode") }
    }

    // MARK: Keyboard → app

    struct Command: Codable {
        enum Action: String, Codable { case start, stop }
        var dictation: Int
        var action: Action
    }

    static func send(_ command: Command) {
        write(command, to: "command.json")
        post(commandNotification)
    }

    static func readCommand() -> Command? { read("command.json") }

    // MARK: App → keyboard

    struct State: Codable {
        enum Phase: String, Codable { case idle, listening, transcribing, finished, failed }
        var dictation = 0
        var phase = Phase.idle
        var seconds = 0.0
        /// Recognized pieces in order. The keyboard inserts the ones it has not inserted yet.
        var texts: [String] = []
        var message: String?
        /// Written every second while a session runs; a stale value means the app is gone.
        var heartbeat = Date.distantPast

        var isSessionAlive: Bool { Date().timeIntervalSince(heartbeat) < 3 }
    }

    static func publish(_ state: State) {
        write(state, to: "state.json")
        post(stateNotification)
    }

    static func readState() -> State { read("state.json") ?? State() }

    // MARK: Keyboard setup status

    /// What the keyboard last reported about itself, so the app can show whether setup is done.
    ///
    /// Without Full Access iOS denies the keyboard write access to the shared container, so a
    /// keyboard without it cannot report at all. That is why only the keyboard (with Full
    /// Access) writes this, and why `fullAccess == true` means it was really granted.
    struct KeyboardStatus: Codable {
        var fullAccess: Bool
        var reported: Date
    }

    /// Returns false if the write failed (no Full Access, or iOS has not granted the
    /// shared container to the keyboard yet).
    @discardableResult
    static func report(_ status: KeyboardStatus) -> Bool {
        guard write(status, to: "keyboard.json") else { return false }
        post(keyboardNotification)
        return true
    }

    static func readKeyboardStatus() -> KeyboardStatus? { read("keyboard.json") }

    // MARK: Signals

    static let commandNotification = "de.cafe-megabyte.iDiktat.command"
    static let stateNotification = "de.cafe-megabyte.iDiktat.state"
    static let keyboardNotification = "de.cafe-megabyte.iDiktat.keyboard"

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true
        )
    }

    /// Calls `handler` on the main thread whenever the named signal arrives, as long as the observer lives.
    final class Observer {
        private let name: String
        private let handler: () -> Void

        init(_ name: String, handler: @escaping () -> Void) {
            self.name = name
            self.handler = handler
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(),
                { _, observer, _, _, _ in
                    guard let observer else { return }
                    let target = Unmanaged<Observer>.fromOpaque(observer).takeUnretainedValue()
                    if Thread.isMainThread {
                        target.handler()
                    } else {
                        DispatchQueue.main.async { [weak target] in target?.handler() }
                    }
                },
                name as CFString, nil, .deliverImmediately
            )
        }

        deinit {
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
                CFNotificationName(name as CFString), nil
            )
        }
    }

    // MARK: Storage

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    private static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    @discardableResult
    private static func write<T: Encodable>(_ value: T, to file: String) -> Bool {
        guard let url = container?.appendingPathComponent(file), let data = try? JSONEncoder().encode(value) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    private static func read<T: Decodable>(_ file: String) -> T? {
        guard let url = container?.appendingPathComponent(file), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
