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

    public func loadDiff(for review: Review, registeredClonePath: String?) async throws -> DiffResult {
        let remoteURL = "https://github.com/\(review.owner)/\(review.repo).git"
        let clonePath = try await worktreeManager.resolveClone(
            owner: review.owner,
            repo: review.repo,
            remoteURL: remoteURL,
            registeredClonePath: registeredClonePath
        )

        let remoteName: String
        if registeredClonePath != nil {
            let remotes = try await worktreeManager.listRemotes(clonePath: clonePath)
            let target = "\(review.owner)/\(review.repo)".lowercased()
            remoteName = remotes.first { entry in
                guard let (owner, repo) = GitOriginParser.parse(entry.url) else { return false }
                return "\(owner)/\(repo)".lowercased() == target
            }?.name ?? "origin"
        } else {
            remoteName = "origin"
        }

        let worktreePath: String
        if let existing = review.worktreePath, FileManager.default.fileExists(atPath: existing) {
            worktreePath = existing
        } else {
            worktreePath = try await worktreeManager.createWorktree(
                clonePath: clonePath,
                owner: review.owner,
                repo: review.repo,
                number: review.number,
                remoteName: remoteName
            )
        }
        let base = try await worktreeManager.mergeBase(worktreePath: worktreePath, baseRef: "\(remoteName)/\(review.baseBranch)")
        let files = try await diffService.diff(worktreePath: worktreePath, baseRef: base)
        return DiffResult(worktreePath: worktreePath, files: files)
    }
}
