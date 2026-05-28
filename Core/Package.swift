// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PRReviewCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PRReviewModels", targets: ["PRReviewModels"]),
        .library(name: "CommandSupport", targets: ["CommandSupport"]),
        .library(name: "ReviewStore", targets: ["ReviewStore"]),
        .library(name: "GitHubKit", targets: ["GitHubKit"]),
        .library(name: "WorktreeKit", targets: ["WorktreeKit"]),
        .library(name: "DiffKit", targets: ["DiffKit"]),
        .library(name: "ClaudeSessionKit", targets: ["ClaudeSessionKit"]),
        .library(name: "AppCore", targets: ["AppCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .target(name: "PRReviewModels"),
        .target(name: "CommandSupport"),
        .target(name: "ReviewStore", dependencies: ["PRReviewModels"]),
        .target(name: "GitHubKit", dependencies: ["PRReviewModels", "CommandSupport"]),
        .target(name: "WorktreeKit", dependencies: ["CommandSupport"]),
        .target(name: "DiffKit", dependencies: ["CommandSupport"]),
        .target(
            name: "ClaudeSessionKit",
            dependencies: [
                "PRReviewModels",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .target(
            name: "AppCore",
            dependencies: ["PRReviewModels", "ReviewStore", "GitHubKit", "CommandSupport", "WorktreeKit", "DiffKit", "ClaudeSessionKit"]
        ),
        .testTarget(name: "PRReviewModelsTests", dependencies: ["PRReviewModels"]),
        .testTarget(name: "ReviewStoreTests", dependencies: ["ReviewStore", "PRReviewModels"]),
        .testTarget(name: "GitHubKitTests", dependencies: ["GitHubKit", "PRReviewModels", "CommandSupport"]),
        .testTarget(name: "CommandSupportTests", dependencies: ["CommandSupport"]),
        .testTarget(name: "WorktreeKitTests", dependencies: ["WorktreeKit", "CommandSupport"]),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore", "PRReviewModels", "ReviewStore", "GitHubKit", "CommandSupport", "DiffKit", "ClaudeSessionKit"]),
        .testTarget(name: "DiffKitTests", dependencies: ["DiffKit", "CommandSupport"]),
        .testTarget(name: "ClaudeSessionKitTests", dependencies: ["ClaudeSessionKit"]),
    ]
)
