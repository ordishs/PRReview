import AppKit
import AppCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationWillTerminate(_ notification: Notification) {
        model?.terminateAllClaudeSessions()
    }
}
