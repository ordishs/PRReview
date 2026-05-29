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
    public private(set) var diffStates: [String: DiffLoadState] = [:]
    public private(set) var registeredRepos: [RegisteredRepo] = []
    public private(set) var claudeSessions: [String: ClaudeSession] = [:]
    public private(set) var claudePaneState: [String: ClaudePaneState] = [:]
    public private(set) var claudeStatuses: [String: ClaudeStatus] = [:]

    private var transcriptWatchers: [String: TranscriptWatcher] = [:]
    private var lastEventAt: [String: Date] = [:]
    private var lastVerdictSnippet: [String: String] = [:]
    private var notifiedIdleForSession: Set<String> = []
    private var tickTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private static let tickIntervalNanoseconds: UInt64 = 5_000_000_000

    private let store: ReviewStore
    private let client: GitHubClient
    private let diffLoader: DiffLoading
    private let worktreeProvider: WorktreeProviding
    private let cloneRegistrar: CloneRegistering
    private let claudePath: String
    private let notificationPoster: NotificationPosting
    private let statusReader: ClaudeStatusReader

    public init(
        store: ReviewStore,
        client: GitHubClient,
        diffLoader: DiffLoading,
        worktreeProvider: WorktreeProviding,
        cloneRegistrar: CloneRegistering,
        claudePath: String,
        notificationPoster: NotificationPosting,
        statusReader: ClaudeStatusReader = ClaudeStatusReader()
    ) {
        self.store = store
        self.client = client
        self.diffLoader = diffLoader
        self.worktreeProvider = worktreeProvider
        self.cloneRegistrar = cloneRegistrar
        self.claudePath = claudePath
        self.notificationPoster = notificationPoster
        self.statusReader = statusReader
    }

    public func load() async {
        reviews = await store.allReviews()
        registeredRepos = await store.allRepos()
        startTickTimerIfNeeded()
    }

    private func startTickTimerIfNeeded() {
        guard tickTask == nil else { return }
        tickTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.tickIntervalNanoseconds)
                self.tickAllActiveStatuses()
            }
        }
    }

    private func tickAllActiveStatuses() {
        let now = Date()
        for id in claudeSessions.keys {
            recomputeStatus(for: id, now: now)
        }
    }

    public func startDiscoveryPolling() {
        guard discoveryTask == nil else { return }
        discoveryTask = Task { @MainActor in
            await self.discoverNow()
            let intervalNs = UInt64(Settings.default.pollIntervalSeconds) * 1_000_000_000
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNs)
                await self.discoverNow()
            }
        }
    }

    func discoverNow() async {
        let queries = Settings.default.discoveryQueries
        var hitsByID: [String: DiscoveryHit] = [:]
        for query in queries {
            guard let results = try? await client.searchPRs(query: query) else { continue }
            for hit in results {
                hitsByID[hit.id] = hit
            }
        }
        await mergeDiscoveryHits(Array(hitsByID.values))
    }

    private func mergeDiscoveryHits(_ hits: [DiscoveryHit]) async {
        let existingByID = Dictionary(reviews.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for hit in hits {
            if let existing = existingByID[hit.id] {
                var updated = existing
                updated.title = hit.title
                updated.prState = GitHubClient.mapDiscoveryState(state: hit.state, isDraft: hit.isDraft)
                if existing.origin == .added { updated.origin = .both }
                try? await store.upsert(updated)
            } else if let lateAdded = reviews.first(where: { $0.id == hit.id }) {
                var updated = lateAdded
                updated.title = hit.title
                updated.prState = GitHubClient.mapDiscoveryState(state: hit.state, isDraft: hit.isDraft)
                updated.origin = .both
                try? await store.upsert(updated)
            } else {
                guard let fresh = try? await client.fetchReview(for: hit.ref, origin: .discovered) else { continue }
                try? await store.upsert(fresh)
            }
        }
        reviews = await store.allReviews()
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
            prefetch(for: review)
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
        diffStates.removeValue(forKey: id)
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
        diffStates[review.id] = .loading
        do {
            let result = try await diffLoader.loadDiff(for: review, registeredClonePath: registeredClonePath(for: review))
            if review.worktreePath != result.worktreePath {
                guard reviews.contains(where: { $0.id == review.id }) else {
                    diffStates[review.id] = .loaded(result.files)
                    return
                }
                var updated = review
                updated.worktreePath = result.worktreePath
                try await store.upsert(updated)
                reviews = await store.allReviews()
            }
            diffStates[review.id] = .loaded(result.files)
        } catch {
            diffStates[review.id] = .failed(String(describing: error))
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
        if claudeSessions[review.id] != nil {
            claudePaneState[review.id] = .sessionLive
            return
        }
        guard reviews.contains(where: { $0.id == review.id }) else { return }
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
        attachTranscriptWatcher(reviewID: review.id, worktreePath: ready.worktreePath)
        recomputeStatus(for: review.id, now: Date())
    }

    private func attachTranscriptWatcher(reviewID: String, worktreePath: String) {
        if transcriptWatchers[reviewID] != nil { return }
        let dir = ClaudeTranscriptPath.directoryURL(forWorktreePath: worktreePath)
        let watcher = TranscriptWatcher(transcriptDir: dir)
        watcher.start { [weak self] date, snippet in
            guard let self else { return }
            self.handleTranscriptEvent(reviewID: reviewID, at: date, snippet: snippet)
        }
        transcriptWatchers[reviewID] = watcher
    }

    func handleTranscriptEvent(reviewID: String, at date: Date, snippet: String?) {
        guard claudeSessions[reviewID] != nil else { return }
        let isNewer = lastEventAt[reviewID].map { $0 < date } ?? true
        if isNewer {
            lastEventAt[reviewID] = date
        }
        if let snippet, !snippet.isEmpty {
            lastVerdictSnippet[reviewID] = snippet
        }
        recomputeStatus(for: reviewID, now: Date())
    }

    func recomputeStatus(for reviewID: String, now: Date = Date()) {
        let processState = claudeSessions[reviewID]?.state ?? .starting
        let newStatus = statusReader.status(
            processState: processState,
            lastEventAt: lastEventAt[reviewID],
            lastVerdictSnippet: lastVerdictSnippet[reviewID],
            now: now
        )
        let oldStatus = claudeStatuses[reviewID]
        claudeStatuses[reviewID] = newStatus
        if shouldFireReviewReady(old: oldStatus, new: newStatus, reviewID: reviewID) {
            notifiedIdleForSession.insert(reviewID)
            postReviewReadyNotification(for: reviewID, status: newStatus)
        }
    }

    private func shouldFireReviewReady(old: ClaudeStatus?, new: ClaudeStatus, reviewID: String) -> Bool {
        guard !notifiedIdleForSession.contains(reviewID) else { return false }
        guard case .idle = new else { return false }
        guard case .working = old else { return false }
        return true
    }

    private func postReviewReadyNotification(for reviewID: String, status: ClaudeStatus) {
        guard let review = reviews.first(where: { $0.id == reviewID }) else { return }
        var snippet: String? = nil
        if case .idle(_, let s) = status { snippet = s }
        let title = "Review ready · #\(review.number)"
        let body = snippet ?? "\(review.owner)/\(review.repo) · \(review.author)"
        let poster = notificationPoster
        Task {
            await poster.postReviewReady(reviewID: reviewID, title: title, body: body)
        }
    }

    func terminateClaudeSession(for id: String) {
        claudeSessions[id]?.terminate()
        claudeSessions.removeValue(forKey: id)
        claudePaneState.removeValue(forKey: id)
        transcriptWatchers[id]?.stop()
        transcriptWatchers.removeValue(forKey: id)
        claudeStatuses.removeValue(forKey: id)
        lastEventAt.removeValue(forKey: id)
        lastVerdictSnippet.removeValue(forKey: id)
        notifiedIdleForSession.remove(id)
    }

    public func terminateAllClaudeSessions() {
        tickTask?.cancel()
        tickTask = nil
        discoveryTask?.cancel()
        discoveryTask = nil
        for session in claudeSessions.values { session.terminate() }
        for watcher in transcriptWatchers.values { watcher.stop() }
        claudeSessions.removeAll()
        claudePaneState.removeAll()
        transcriptWatchers.removeAll()
        claudeStatuses.removeAll()
        lastEventAt.removeAll()
        lastVerdictSnippet.removeAll()
        notifiedIdleForSession.removeAll()
    }

    public func prefetch(for review: Review) {
        Task { await ensureClaudeSession(for: review) }
        Task { await loadDiff(for: review) }
    }

    public func selectedReview() -> Review? {
        guard let selection else { return nil }
        return reviews.first { $0.id == selection }
    }

    public func dismissError() {
        errorMessage = nil
    }
}
