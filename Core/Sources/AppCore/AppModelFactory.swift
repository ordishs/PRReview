import Foundation
import PRReviewModels
import ReviewStore
import GitHubKit
import CommandSupport

public enum AppModelFactory {
    @MainActor
    public static func makeDefault() throws -> AppModel {
        let settings = Settings.default
        let storeURL = URL(fileURLWithPath: settings.managedRoot).appendingPathComponent("store.json")
        let store = try ReviewStore(fileURL: storeURL)
        let ghPath = settings.ghPath ?? ToolResolver.resolve("gh") ?? "/opt/homebrew/bin/gh"
        let client = GitHubClient(runner: ProcessCommandRunner(), ghPath: ghPath)
        return AppModel(store: store, client: client)
    }
}
