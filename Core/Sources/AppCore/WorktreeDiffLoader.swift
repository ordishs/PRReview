import Foundation
import PRReviewModels
import WorktreeKit
import DiffKit

public struct WorktreeDiffLoader: DiffLoading {
    private let worktreeManager: WorktreeManager
    private let diffService: DiffService

    public init(worktreeManager: WorktreeManager, diffService: DiffService) {
        self.worktreeManager = worktreeManager
        self.diffService = diffService
    }

    public func loadDiff(for review: Review) async throws -> DiffResult {
        let remoteURL = "https://github.com/\(review.owner)/\(review.repo).git"
        let clonePath = try await worktreeManager.resolveClone(
            owner: review.owner,
            repo: review.repo,
            remoteURL: remoteURL,
            registeredClonePath: nil
        )
        let worktreePath: String
        if let existing = review.worktreePath, FileManager.default.fileExists(atPath: existing) {
            worktreePath = existing
        } else {
            worktreePath = try await worktreeManager.createWorktree(
                clonePath: clonePath,
                owner: review.owner,
                repo: review.repo,
                number: review.number
            )
        }
        let base = try await worktreeManager.mergeBase(worktreePath: worktreePath, baseRef: "origin/\(review.baseBranch)")
        let files = try await diffService.diff(worktreePath: worktreePath, baseRef: base)
        return DiffResult(worktreePath: worktreePath, files: files)
    }
}
