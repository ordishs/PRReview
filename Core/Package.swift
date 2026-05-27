// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PRReviewCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PRReviewModels", targets: ["PRReviewModels"]),
        .library(name: "ReviewStore", targets: ["ReviewStore"]),
        .library(name: "GitHubKit", targets: ["GitHubKit"]),
        .library(name: "WorktreeKit", targets: ["WorktreeKit"]),
        .library(name: "DiffKit", targets: ["DiffKit"]),
        .library(name: "ClaudeSessionKit", targets: ["ClaudeSessionKit"]),
    ],
    targets: [
        .target(name: "PRReviewModels"),
        .target(name: "ReviewStore", dependencies: ["PRReviewModels"]),
        .target(name: "GitHubKit", dependencies: ["PRReviewModels"]),
        .target(name: "WorktreeKit", dependencies: ["PRReviewModels"]),
        .target(name: "DiffKit", dependencies: ["PRReviewModels"]),
        .target(name: "ClaudeSessionKit", dependencies: ["PRReviewModels"]),
        .testTarget(name: "PRReviewModelsTests", dependencies: ["PRReviewModels"]),
        .testTarget(name: "ReviewStoreTests", dependencies: ["ReviewStore", "PRReviewModels"]),
        .testTarget(name: "GitHubKitTests", dependencies: ["GitHubKit", "PRReviewModels"]),
    ]
)
