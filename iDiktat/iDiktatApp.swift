import SwiftUI

@main
struct iDiktatApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                // The keyboard opens idiktat://session when it needs a session in app mode.
                .onOpenURL { url in
                    guard url.scheme == AppBridge.sessionURL.scheme, url.host == AppBridge.sessionURL.host else { return }
                    let service = DictationService.shared
                    service.mode = .app
                    service.startSession()
                }
        }
    }
}
