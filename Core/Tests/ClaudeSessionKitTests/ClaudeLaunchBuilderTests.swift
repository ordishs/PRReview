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

@Test func launchBuilderWithoutResumeIDIncludesReviewSlashCommand() {
    let spec = ClaudeLaunchBuilder.build(
        settings: .default,
        review: sampleReview(),
        worktreePath: "/tmp/wt",
        resolvedClaudePath: "/bin/claude",
        resumeSessionID: nil
    )
    #expect(spec.executable == "/bin/claude")
    #expect(spec.cwd == "/tmp/wt")
    #expect(spec.arguments.contains("--name"))
    #expect(spec.arguments.contains("944 - icellan"))
    #expect(spec.arguments.contains("--effort"))
    #expect(spec.arguments.contains("max"))
    #expect(spec.arguments.contains("--dangerously-skip-permissions"))
    #expect(spec.arguments.contains("/review https://github.com/bsv-blockchain/teranode/pull/944"))
    #expect(!spec.arguments.contains("--resume"))
    #expect(!spec.arguments.contains("--continue"))
}

@Test func launchBuilderWithResumeIDEmitsResumeFlagAndOmitsReview() {
    let spec = ClaudeLaunchBuilder.build(
        settings: .default,
        review: sampleReview(),
        worktreePath: "/tmp/wt",
        resolvedClaudePath: "/bin/claude",
        resumeSessionID: "10889bb0-624c-4ef5-94f7-77480418849c"
    )
    let idx = spec.arguments.firstIndex(of: "--resume")
    #expect(idx != nil)
    if let idx {
        #expect(spec.arguments[spec.arguments.index(after: idx)] == "10889bb0-624c-4ef5-94f7-77480418849c")
    }
    #expect(!spec.arguments.contains { $0.hasPrefix("/review ") })
    #expect(!spec.arguments.contains("--continue"))
}
