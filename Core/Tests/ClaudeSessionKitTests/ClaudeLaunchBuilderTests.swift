import Testing
import Foundation
import PRReviewModels
@testable import ClaudeSessionKit

private func sampleReview() -> Review {
    Review(
        owner: "bsv-blockchain", repo: "teranode", number: 944,
        url: URL(string: "https://github.com/bsv-blockchain/teranode/pull/944")!,
        title: "fix", author: "icellan",
        headBranch: "fix", baseBranch: "main",
        origin: .added, prState: .open, addedAt: Date()
    )
}

@Test func launchBuilderWithoutContinueIncludesReviewSlashCommand() {
    let spec = ClaudeLaunchBuilder.build(
        settings: .default,
        review: sampleReview(),
        worktreePath: "/tmp/wt",
        resolvedClaudePath: "/bin/claude",
        includeContinue: false
    )
    #expect(spec.executable == "/bin/claude")
    #expect(spec.cwd == "/tmp/wt")
    #expect(spec.arguments.contains("--name"))
    #expect(spec.arguments.contains("944 - icellan"))
    #expect(spec.arguments.contains("--effort"))
    #expect(spec.arguments.contains("max"))
    #expect(spec.arguments.contains("--dangerously-skip-permissions"))
    #expect(spec.arguments.contains("/review https://github.com/bsv-blockchain/teranode/pull/944"))
    #expect(!spec.arguments.contains("--continue"))
}

@Test func launchBuilderWithContinueOmitsReviewSlashCommand() {
    let spec = ClaudeLaunchBuilder.build(
        settings: .default,
        review: sampleReview(),
        worktreePath: "/tmp/wt",
        resolvedClaudePath: "/bin/claude",
        includeContinue: true
    )
    #expect(spec.arguments.contains("--continue"))
    #expect(!spec.arguments.contains { $0.hasPrefix("/review ") })
}
