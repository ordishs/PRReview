import Foundation
import Observation
import PRReviewModels
import ReviewStore
import GitHubKit
import ClaudeSessionKit

public enum ClaudePaneState: Sendable, Equatable {
    case idle
    case preparingWorktree
    case worktreeFailed(String)
    case sessionLive
}

@MainActor
@Observable
public final class AppModel {
    public private(set) var reviews: [Review] = []
    public var selection: String?
    public private(set) var errorMessage: String?
    public private(set) var isAdding = false
    public private(set) var diffState: DiffLoadState = .idle
    public private(set) var registeredRepos: [RegisteredRepo] = []
    public private(set) var claudeSessions: [String: ClaudeSession] = [:]
    public private(set) var claudePaneState: [String: ClaudePaneState] = [:]

    private let store: ReviewStore
    private let client: GitHubClient
    private let diffLoader: DiffLoading
    private let worktreeProvider: WorktreeProviding
    private let cloneRegistrar: CloneRegistering
    private let claudePath: String

    public init(
        store: ReviewStore,
        client: GitHubClient,
        diffLoader: DiffLoading,
        worktreeProvider: WorktreeProviding,
        cloneRegistrar: CloneRegistering,
        claudePath: String
    ) {
        self.store = store
        self.client = client
        self.diffLoader = diffLoader
        self.worktreeProvider = worktreeProvider
        self.cloneRegistrar = cloneRegistrar
        self.claudePath = claudePath
    }

    public func load() async {
        reviews = await store.allReviews()
        registeredRepos = await store.allRepos()
    }

    public func addPR(urlString: String) async {
        isAdding = true
        defer { isAdding = false }
        do {
            let ref = try PRRef.parse(urlString)
            let review = try await client.fetchReview(for: ref)
            try await store.upsert(review)
            reviews = await store.allReviews()
            selection = review.id
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func registeredClonePath(for review: Review) -> String? {
        let identity = "github.com/\(review.owner)/\(review.repo)"
        return registeredRepos.first { $0.remoteIdentity == identity }?.localClonePath
    }

    public func registerClone(for review: Review, localPath: String) async {
        do {
            try await cloneRegistrar.validate(localPath: localPath, expectedOwner: review.owner, expectedRepo: review.repo)
            let identity = "github.com/\(review.owner)/\(review.repo)"
            let entry = RegisteredRepo(remoteIdentity: identity, localClonePath: localPath, defaultBase: review.baseBranch)
            try await store.upsert(entry)
            registeredRepos = await store.allRepos()
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func registerLocalClone(at localPath: String) async {
        do {
            let identities = try await cloneRegistrar.detectRepositories(at: localPath)
            guard !identities.isEmpty else {
                errorMessage = "No GitHub repositories found in \(localPath)"
                return
            }
            for identity in identities {
                let entry = RegisteredRepo(remoteIdentity: "github.com/\(identity)", localClonePath: localPath, defaultBase: "main")
                try await store.upsert(entry)
            }
            registeredRepos = await store.allRepos()
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func removeRegisteredRepo(remoteIdentity: String) async {
        do {
            try await store.removeRepo(id: remoteIdentity)
            registeredRepos = await store.allRepos()
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func removeReview(id: String) async {
        guard let review = reviews.first(where: { $0.id == id }) else { return }
        terminateClaudeSession(for: id)
        if let worktreePath = review.worktreePath, FileManager.default.fileExists(atPath: worktreePath) {
            try? FileManager.default.removeItem(atPath: worktreePath)
        }
        do {
            try await store.removeReview(id: id)
            reviews = await store.allReviews()
            if selection == id {
                selection = nil
            }
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func loadDiff(for review: Review) async {
        diffState = .loading
        do {
            let result = try await diffLoader.loadDiff(for: review, registeredClonePath: registeredClonePath(for: review))
            if review.worktreePath != result.worktreePath {
                var updated = review
                updated.worktreePath = result.worktreePath
                try await store.upsert(updated)
                reviews = await store.allReviews()
            }
            diffState = .loaded(result.files)
        } catch {
            diffState = .failed(String(describing: error))
        }
    }

    public func ensureClaudeSession(for review: Review) async {
        if claudeSessions[review.id] != nil {
            claudePaneState[review.id] = .sessionLive
            return
        }
        claudePaneState[review.id] = .preparingWorktree
        let ready: WorktreeReady
        do {
            ready = try await worktreeProvider.ensureWorktree(
                for: review,
                registeredClonePath: registeredClonePath(for: review)
            )
        } catch {
            claudePaneState[review.id] = .worktreeFailed(String(describing: error))
            return
        }
        if review.worktreePath != ready.worktreePath {
            var updated = review
            updated.worktreePath = ready.worktreePath
            try? await store.upsert(updated)
            reviews = await store.allReviews()
        }
        let spec = ClaudeLaunchBuilder.build(
            settings: .default,
            review: review,
            worktreePath: ready.worktreePath,
            resolvedClaudePath: claudePath
        )
        let session = ClaudeSession(spec: spec)
        claudeSessions[review.id] = session
        claudePaneState[review.id] = .sessionLive
        session.start()
    }

    public func terminateClaudeSession(for id: String) {
        claudeSessions[id]?.terminate()
        claudeSessions.removeValue(forKey: id)
        claudePaneState.removeValue(forKey: id)
    }

    public func terminateAllClaudeSessions() {
        for session in claudeSessions.values { session.terminate() }
        claudeSessions.removeAll()
        claudePaneState.removeAll()
    }

    public func selectedReview() -> Review? {
        guard let selection else { return nil }
        return reviews.first { $0.id == selection }
    }

    public func dismissError() {
        errorMessage = nil
    }
}
