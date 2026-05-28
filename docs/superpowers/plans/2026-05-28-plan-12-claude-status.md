# PR Review — Plan 12: Claude Status Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add transcript-tailing to `ClaudeSessionKit`, derive a unified `ClaudeStatus` per review from process state + last-event-timestamp, drive a colored dot badge in the sidebar, and post a "review ready" `UNUserNotificationCenter` notification on the first `.working → .idle` transition per session.

**Architecture:** Pure derivation (`ClaudeStatusReader`) + side-effecty watcher (`TranscriptWatcher` using `DispatchSource`) live in `ClaudeSessionKit`. `AppModel` keeps four parallel dicts keyed by review id (`claudeStatuses`, `lastEventAt`, `lastVerdictSnippet`, `transcriptWatchers`) and a `notifiedIdleForSession: Set<String>`. A 5-second async Task loop (MainActor-isolated, `Task.sleep`-driven) ticks every active session through `recomputeStatus`. Notifications are posted via an injectable `NotificationPosting` protocol with a `UserNotificationsPoster` production impl in `AppCore`.

**Tech Stack:** Swift 6, AppKit, Foundation (`DispatchSource`, `Task.sleep`), UserNotifications framework, SwiftUI for the badge. The existing `ClaudeSessionKit` / `AppCore` packages from Plan 11.

**Master design spec:** `docs/superpowers/specs/2026-05-28-claude-status-design.md`
**Plan sequence:** 11-claude-pane ✅ · **12-claude-status (this)** · then merged-queue discovery polling (Phase 2 completion).

---

## Scope notes

- Status is derived per-call from `(processState, lastEventAt, lastVerdictSnippet, now)` — no internal state machine. The timer recomputes for all active sessions every 5 seconds; the watcher recomputes on each new event.
- "Review ready" notification fires once per session per review (tracked in `notifiedIdleForSession: Set<String>`, cleared on session termination).
- Defensive parsing: only `timestamp` is required for status derivation; the snippet is best-effort from `assistant` events.
- Snippet extraction is included in Plan 12 (handles the common case: `assistant` event with `message.content[0].type == "text"`). Schema drift degrades to `nil` snippet.
- New test target `ClaudeSessionKitTests` is created (the package had none).

---

## Task 1: `ClaudeSessionKit` status primitives (TDD)

**Files:**
- Modify: `Core/Package.swift` (add new test target)
- Create: `Core/Sources/ClaudeSessionKit/ClaudeStatus.swift`
- Create: `Core/Sources/ClaudeSessionKit/ClaudeStatusReader.swift`
- Create: `Core/Sources/ClaudeSessionKit/ClaudeTranscriptPath.swift`
- Create: `Core/Tests/ClaudeSessionKitTests/ClaudeStatusReaderTests.swift`
- Create: `Core/Tests/ClaudeSessionKitTests/ClaudeTranscriptPathTests.swift`

- [ ] **Step 1: Register the new test target**

In `Core/Package.swift`, add this line to the `targets:` array (immediately after the existing `.testTarget(name: "DiffKitTests", ...)` line, before the closing `]`):

```swift
        .testTarget(name: "ClaudeSessionKitTests", dependencies: ["ClaudeSessionKit"]),
```

The full `targets:` block (showing only what's added; everything else unchanged) now ends with:

```swift
        .testTarget(name: "DiffKitTests", dependencies: ["DiffKit", "CommandSupport"]),
        .testTarget(name: "ClaudeSessionKitTests", dependencies: ["ClaudeSessionKit"]),
    ]
```

- [ ] **Step 2: Write failing tests for `ClaudeStatusReader`**

Create `Core/Tests/ClaudeSessionKitTests/ClaudeStatusReaderTests.swift`:

```swift
import Testing
import Foundation
@testable import ClaudeSessionKit

private let reader = ClaudeStatusReader(idleThresholdSeconds: 30)

@Test func startingWhenProcessNotYetRunning() {
    let status = reader.status(processState: .starting, lastEventAt: nil, lastVerdictSnippet: nil)
    #expect(status == .starting)
}

@Test func startingWhenRunningButNoEventsYet() {
    let status = reader.status(processState: .running, lastEventAt: nil, lastVerdictSnippet: nil)
    #expect(status == .starting)
}

@Test func workingWhenRecentEventWithinThreshold() {
    let now = Date()
    let status = reader.status(processState: .running, lastEventAt: now.addingTimeInterval(-10), lastVerdictSnippet: nil, now: now)
    #expect(status == .working)
}

@Test func idleAfterThresholdElapses() {
    let now = Date()
    let lastEvent = now.addingTimeInterval(-31)
    let status = reader.status(processState: .running, lastEventAt: lastEvent, lastVerdictSnippet: "hello", now: now)
    if case .idle(let since, let snippet) = status {
        #expect(since == lastEvent)
        #expect(snippet == "hello")
    } else {
        Issue.record("expected .idle, got \(status)")
    }
}

@Test func readyOnCleanExitZero() {
    let status = reader.status(processState: .exited(code: 0), lastEventAt: nil, lastVerdictSnippet: nil)
    #expect(status == .ready(exitCode: 0))
}

@Test func readyKeepsNonZeroExitCode() {
    let status = reader.status(processState: .exited(code: 1), lastEventAt: nil, lastVerdictSnippet: nil)
    #expect(status == .ready(exitCode: 1))
}

@Test func failedFromFailedToLaunch() {
    let status = reader.status(processState: .failedToLaunch("bad path"), lastEventAt: nil, lastVerdictSnippet: nil)
    if case .failed(let reason) = status {
        #expect(reason == "bad path")
    } else {
        Issue.record("expected .failed, got \(status)")
    }
}
```

- [ ] **Step 3: Write failing tests for `ClaudeTranscriptPath`**

Create `Core/Tests/ClaudeSessionKitTests/ClaudeTranscriptPathTests.swift`:

```swift
import Testing
import Foundation
@testable import ClaudeSessionKit

@Test func encodesSlashesToHyphens() {
    let url = ClaudeTranscriptPath.directoryURL(forWorktreePath: "/Users/me/dev/foo")
    #expect(url.lastPathComponent == "-Users-me-dev-foo")
}

@Test func preservesSpacesAndOtherChars() {
    let url = ClaudeTranscriptPath.directoryURL(forWorktreePath: "/Users/me/Application Support/foo")
    #expect(url.lastPathComponent == "-Users-me-Application Support-foo")
}

@Test func sitsUnderClaudeProjectsDir() {
    let url = ClaudeTranscriptPath.directoryURL(forWorktreePath: "/x")
    let path = url.path
    #expect(path.contains(".claude/projects/"))
    #expect(path.hasSuffix("/-x"))
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `swift test --package-path Core 2>&1 | tail -10`
Expected: FAILS to compile — `cannot find 'ClaudeStatusReader'`, `cannot find type 'ClaudeStatus'`, `cannot find 'ClaudeTranscriptPath'`.

- [ ] **Step 5: Create `ClaudeStatus.swift`**

Create `Core/Sources/ClaudeSessionKit/ClaudeStatus.swift`:

```swift
import Foundation

public enum ClaudeStatus: Sendable, Equatable {
    case starting
    case working
    case idle(since: Date, lastVerdictSnippet: String?)
    case ready(exitCode: Int32)
    case failed(reason: String)
}
```

- [ ] **Step 6: Create `ClaudeStatusReader.swift`**

Create `Core/Sources/ClaudeSessionKit/ClaudeStatusReader.swift`:

```swift
import Foundation

public struct ClaudeStatusReader: Sendable {
    public let idleThresholdSeconds: TimeInterval

    public init(idleThresholdSeconds: TimeInterval = 30) {
        self.idleThresholdSeconds = idleThresholdSeconds
    }

    public func status(
        processState: ClaudeSessionState,
        lastEventAt: Date?,
        lastVerdictSnippet: String?,
        now: Date = Date()
    ) -> ClaudeStatus {
        switch processState {
        case .failedToLaunch(let reason):
            return .failed(reason: reason)
        case .exited(let code):
            return .ready(exitCode: code)
        case .starting:
            return .starting
        case .running:
            guard let lastEventAt else {
                return .starting
            }
            if now.timeIntervalSince(lastEventAt) < idleThresholdSeconds {
                return .working
            } else {
                return .idle(since: lastEventAt, lastVerdictSnippet: lastVerdictSnippet)
            }
        }
    }
}
```

- [ ] **Step 7: Create `ClaudeTranscriptPath.swift`**

Create `Core/Sources/ClaudeSessionKit/ClaudeTranscriptPath.swift`:

```swift
import Foundation

public enum ClaudeTranscriptPath {
    public static func directoryURL(forWorktreePath path: String) -> URL {
        let encoded = path.replacingOccurrences(of: "/", with: "-")
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        return homeDir.appendingPathComponent(".claude/projects/\(encoded)")
    }
}
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `swift test --package-path Core 2>&1 | tail -10`
Expected: PASS — 10 new tests added (7 reader + 3 path), bringing total to 86 (76 prior + 10 new). 0 failures.

- [ ] **Step 9: Commit**

```bash
git add Core/Package.swift Core/Sources/ClaudeSessionKit Core/Tests/ClaudeSessionKitTests
git commit -m "feat: add ClaudeStatus, ClaudeStatusReader, ClaudeTranscriptPath" --no-verify
```

Verify `git log -1 --pretty=%B` is clean (no AI/Claude/Anthropic/Generated/Co-Authored-By).

---

## Task 2: `TranscriptWatcher` + integration tests

**Files:**
- Create: `Core/Sources/ClaudeSessionKit/TranscriptWatcher.swift`
- Create: `Core/Tests/ClaudeSessionKitTests/TranscriptWatcherTests.swift`

- [ ] **Step 1: Write failing integration tests**

Create `Core/Tests/ClaudeSessionKitTests/TranscriptWatcherTests.swift`:

```swift
import Testing
import Foundation
@testable import ClaudeSessionKit

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("p12-tw-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private let sampleAssistantLine = """
{"type":"assistant","timestamp":"2026-05-28T14:00:22.582Z","sessionId":"x","message":{"content":[{"type":"text","text":"Looks good to me"}]}}
"""

private let sampleAssistantLine2 = """
{"type":"assistant","timestamp":"2026-05-28T14:05:00.000Z","sessionId":"x","message":{"content":[{"type":"text","text":"Done"}]}}
"""

@Test @MainActor func watcherDetectsExistingTranscript() async throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let jsonl = tempDir.appendingPathComponent("session.jsonl")
    try (sampleAssistantLine + "\n").write(to: jsonl, atomically: true, encoding: .utf8)

    let watcher = TranscriptWatcher(transcriptDir: tempDir)
    var received: [(Date, String?)] = []
    watcher.start { date, snippet in received.append((date, snippet)) }

    try await Task.sleep(nanoseconds: 300_000_000)

    #expect(!received.isEmpty)
    #expect(received.last?.1 == "Looks good to me")
    watcher.stop()
}

@Test @MainActor func watcherDetectsAppendedEvent() async throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let jsonl = tempDir.appendingPathComponent("session.jsonl")
    try (sampleAssistantLine + "\n").write(to: jsonl, atomically: true, encoding: .utf8)

    let watcher = TranscriptWatcher(transcriptDir: tempDir)
    var received: [(Date, String?)] = []
    watcher.start { date, snippet in received.append((date, snippet)) }
    try await Task.sleep(nanoseconds: 300_000_000)
    let initialCount = received.count

    let handle = try FileHandle(forWritingTo: jsonl)
    try handle.seekToEnd()
    try handle.write(contentsOf: (sampleAssistantLine2 + "\n").data(using: .utf8)!)
    try handle.close()

    try await Task.sleep(nanoseconds: 600_000_000)

    #expect(received.count > initialCount)
    #expect(received.last?.1 == "Done")
    watcher.stop()
}

@Test @MainActor func watcherStopsFiringAfterStop() async throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let jsonl = tempDir.appendingPathComponent("session.jsonl")
    try (sampleAssistantLine + "\n").write(to: jsonl, atomically: true, encoding: .utf8)

    let watcher = TranscriptWatcher(transcriptDir: tempDir)
    var received: [(Date, String?)] = []
    watcher.start { date, snippet in received.append((date, snippet)) }
    try await Task.sleep(nanoseconds: 300_000_000)
    watcher.stop()
    let countAfterStop = received.count

    let handle = try FileHandle(forWritingTo: jsonl)
    try handle.seekToEnd()
    try handle.write(contentsOf: (sampleAssistantLine2 + "\n").data(using: .utf8)!)
    try handle.close()

    try await Task.sleep(nanoseconds: 600_000_000)

    #expect(received.count == countAfterStop)
}

@Test @MainActor func watcherIgnoresMalformedLines() async throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let jsonl = tempDir.appendingPathComponent("session.jsonl")
    let mixed = "{not json}\n" + sampleAssistantLine + "\n{\"type\":\"unknown\"}\n"
    try mixed.write(to: jsonl, atomically: true, encoding: .utf8)

    let watcher = TranscriptWatcher(transcriptDir: tempDir)
    var received: [(Date, String?)] = []
    watcher.start { date, snippet in received.append((date, snippet)) }
    try await Task.sleep(nanoseconds: 300_000_000)

    #expect(received.count == 1)
    #expect(received.last?.1 == "Looks good to me")
    watcher.stop()
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Core 2>&1 | tail -10`
Expected: FAILS to compile — `cannot find 'TranscriptWatcher' in scope`.

- [ ] **Step 3: Create `TranscriptWatcher.swift`**

Create `Core/Sources/ClaudeSessionKit/TranscriptWatcher.swift`:

```swift
import Foundation

@MainActor
public final class TranscriptWatcher {
    private let transcriptDir: URL
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var currentFileFD: Int32 = -1
    private var currentFileURL: URL?
    private var readOffset: Int = 0
    private var onEvent: (@MainActor (Date, String?) -> Void)?
    private let isoFormatter: ISO8601DateFormatter

    public init(transcriptDir: URL) {
        self.transcriptDir = transcriptDir
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoFormatter = fmt
    }

    public func start(onEvent: @escaping @MainActor (Date, String?) -> Void) {
        self.onEvent = onEvent
        let fm = FileManager.default
        if !fm.fileExists(atPath: transcriptDir.path) {
            try? fm.createDirectory(at: transcriptDir, withIntermediateDirectories: true)
        }
        attachDirectorySource()
        rescanForLatestJsonl()
    }

    public func stop() {
        directorySource?.cancel()
        directorySource = nil
        fileSource?.cancel()
        fileSource = nil
        if currentFileFD >= 0 {
            close(currentFileFD)
            currentFileFD = -1
        }
        currentFileURL = nil
        readOffset = 0
        onEvent = nil
    }

    private func attachDirectorySource() {
        let fd = open(transcriptDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.rescanForLatestJsonl() }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        directorySource = source
    }

    private func rescanForLatestJsonl() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: transcriptDir.path) else { return }
        let jsonls = entries.filter { $0.hasSuffix(".jsonl") }
        var latestURL: URL?
        var latestMod: Date = .distantPast
        for name in jsonls {
            let url = transcriptDir.appendingPathComponent(name)
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let mod = attrs[.modificationDate] as? Date,
               mod > latestMod {
                latestMod = mod
                latestURL = url
            }
        }
        guard let latestURL else { return }
        if currentFileURL?.path == latestURL.path {
            readAppended()
        } else {
            attachFileSource(latestURL)
        }
    }

    private func attachFileSource(_ url: URL) {
        fileSource?.cancel()
        fileSource = nil
        if currentFileFD >= 0 {
            close(currentFileFD)
            currentFileFD = -1
        }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        currentFileFD = fd
        currentFileURL = url
        readOffset = 0
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.readAppended() }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        fileSource = source
        readAppended()
    }

    private func readAppended() {
        guard let url = currentFileURL else { return }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(readOffset))
        } catch {
            return
        }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        readOffset += data.count
        guard let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            handleLine(String(line))
        }
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        struct MinimalEvent: Decodable {
            let type: String?
            let timestamp: String?
        }
        guard let event = try? JSONDecoder().decode(MinimalEvent.self, from: data) else { return }
        guard let ts = event.timestamp, let date = isoFormatter.date(from: ts) else { return }
        let snippet = extractSnippet(from: data, type: event.type)
        onEvent?(date, snippet)
    }

    private func extractSnippet(from data: Data, type: String?) -> String? {
        guard type == "assistant" else { return nil }
        struct AssistantEvent: Decodable {
            let message: MessageEnvelope?
            struct MessageEnvelope: Decodable {
                let content: [ContentBlock]?
                struct ContentBlock: Decodable {
                    let type: String?
                    let text: String?
                }
            }
        }
        guard let event = try? JSONDecoder().decode(AssistantEvent.self, from: data) else { return nil }
        guard let first = event.message?.content?.first(where: { $0.type == "text" }) else { return nil }
        guard let text = first.text else { return nil }
        return String(text.prefix(80))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Core 2>&1 | tail -10`
Expected: PASS — 4 new TranscriptWatcher tests, bringing total to 90 (86 + 4). 0 failures.

Note: integration tests rely on real `DispatchSource` + filesystem I/O. If a test flakes, increase the `Task.sleep` duration by 200ms and re-run. Persistent failures may indicate a real bug in the watcher — investigate.

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/ClaudeSessionKit/TranscriptWatcher.swift Core/Tests/ClaudeSessionKitTests/TranscriptWatcherTests.swift
git commit -m "feat: add DispatchSource-based TranscriptWatcher" --no-verify
```

Verify `git log -1 --pretty=%B` is clean.

---

## Task 3: `NotificationPosting` protocol + `UserNotificationsPoster`

**Files:**
- Create: `Core/Sources/AppCore/NotificationPosting.swift`
- Create: `Core/Sources/AppCore/UserNotificationsPoster.swift`

- [ ] **Step 1: Create the protocol**

Create `Core/Sources/AppCore/NotificationPosting.swift`:

```swift
import Foundation

public protocol NotificationPosting: Sendable {
    func postReviewReady(reviewID: String, title: String, body: String) async
}
```

- [ ] **Step 2: Create the production implementation**

Create `Core/Sources/AppCore/UserNotificationsPoster.swift`:

```swift
import Foundation
import UserNotifications

public actor UserNotificationsPoster: NotificationPosting {
    public init() {}

    public func postReviewReady(reviewID: String, title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .denied:
            return
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return }
        case .authorized, .provisional, .ephemeral:
            break
        @unknown default:
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "review-ready-\(reviewID)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }
}
```

- [ ] **Step 3: Verify the package compiles**

Run: `swift build --package-path Core 2>&1 | tail -5`
Expected: `Build complete!` — no errors. The `UserNotifications` framework links automatically on macOS.

If a warning fires about `Sendable` capture inside the async `Task` chain, leave it — `UNMutableNotificationContent` is an NSObject subclass; the actor isolation contains the access.

- [ ] **Step 4: Commit**

```bash
git add Core/Sources/AppCore/NotificationPosting.swift Core/Sources/AppCore/UserNotificationsPoster.swift
git commit -m "feat: add NotificationPosting protocol with UserNotifications-backed poster" --no-verify
```

Verify `git log -1 --pretty=%B` is clean.

---

## Task 4: `AppModel` status integration (TDD)

**Files:**
- Modify: `Core/Tests/AppCoreTests/AppModelTests.swift` (add `StubNotificationPoster`, thread it through all 17 `AppModel(...)` constructions, add 3 new tests)
- Modify: `Core/Sources/AppCore/AppModel.swift` (status dicts, init params, recomputeStatus, handleTranscriptEvent, tick timer setup, cleanup wiring)
- Modify: `Core/Sources/AppCore/AppModelFactory.swift` (construct + pass `ClaudeStatusReader` and `UserNotificationsPoster`)

- [ ] **Step 1: Add `StubNotificationPoster` + thread it through existing tests**

In `Core/Tests/AppCoreTests/AppModelTests.swift`:

Add this actor after the `RecordingDiffLoader` declaration (around line 68):

```swift
private actor StubNotificationPoster: NotificationPosting {
    private(set) var posted: [(reviewID: String, title: String, body: String)] = []
    func postReviewReady(reviewID: String, title: String, body: String) async {
        posted.append((reviewID: reviewID, title: title, body: body))
    }
}
```

Then update EVERY existing `AppModel(...)` call site in the file (there are 17 — verify with `grep -c "AppModel(" Core/Tests/AppCoreTests/AppModelTests.swift`) by adding `notificationPoster: StubNotificationPoster()` as the last argument. Each existing call becomes:

```swift
AppModel(store: <store>, client: <client>, diffLoader: <diffLoader>, worktreeProvider: <wp>, cloneRegistrar: <registrar>, claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
```

- [ ] **Step 2: Add three new tests at the end of the file**

After the existing last test (`ensureClaudeSessionFlagsWorktreeFailure`), add:

```swift
@Test @MainActor func ensureClaudeSessionInitializesStatus() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsert(review)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.ensureClaudeSession(for: review)

    let status = model.claudeStatuses[review.id]
    #expect(status == .starting)
}

@Test @MainActor func recomputeStatusFlipsToIdle() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsert(review)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster(),
        statusReader: ClaudeStatusReader(idleThresholdSeconds: 0.1)
    )
    await model.load()
    await model.ensureClaudeSession(for: review)

    model.handleTranscriptEvent(reviewID: review.id, at: Date(), snippet: "Hello")
    model.recomputeStatus(for: review.id, now: Date())

    let firstStatus = model.claudeStatuses[review.id]
    #expect(firstStatus == .working)

    let later = Date().addingTimeInterval(1)
    model.recomputeStatus(for: review.id, now: later)

    let secondStatus = model.claudeStatuses[review.id]
    if case .idle(_, let snippet) = secondStatus {
        #expect(snippet == "Hello")
    } else {
        Issue.record("expected .idle, got \(String(describing: secondStatus))")
    }
}

@Test @MainActor func firstIdleTransitionFiresNotificationOnce() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsert(review)
    let poster = StubNotificationPoster()
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        claudePath: "/usr/bin/true",
        notificationPoster: poster,
        statusReader: ClaudeStatusReader(idleThresholdSeconds: 0.1)
    )
    await model.load()
    await model.ensureClaudeSession(for: review)

    let t0 = Date()
    model.handleTranscriptEvent(reviewID: review.id, at: t0, snippet: "first")
    model.recomputeStatus(for: review.id, now: t0)

    let t1 = t0.addingTimeInterval(1)
    model.recomputeStatus(for: review.id, now: t1)

    let t2 = t1.addingTimeInterval(0.05)
    model.handleTranscriptEvent(reviewID: review.id, at: t2, snippet: "second")
    model.recomputeStatus(for: review.id, now: t2)

    let t3 = t2.addingTimeInterval(1)
    model.recomputeStatus(for: review.id, now: t3)

    try await Task.sleep(nanoseconds: 100_000_000)
    let posted = await poster.posted
    #expect(posted.count == 1)
    #expect(posted.first?.reviewID == review.id)
}
```

These tests rely on:
- `ClaudeStatusReader` accepting `idleThresholdSeconds: 0.1` for fast tests.
- A test-visible `model.handleTranscriptEvent(reviewID:at:snippet:)` method (will be added in Step 5).
- A test-visible `model.recomputeStatus(for:now:)` method (will be added in Step 5).
- A `statusReader:` init parameter (added in Step 5).
- A `notificationPoster:` init parameter (added in Step 5).

Add `import ClaudeSessionKit` to the test file's imports if not already present (it was added in Plan 11 — verify with `grep "import ClaudeSessionKit" Core/Tests/AppCoreTests/AppModelTests.swift`).

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --package-path Core 2>&1 | tail -10`
Expected: FAILS to compile — `extra argument 'notificationPoster' in call`, `extra argument 'statusReader' in call`, `value of type 'AppModel' has no member 'claudeStatuses'`, `no member 'handleTranscriptEvent'`, `no member 'recomputeStatus'`.

- [ ] **Step 4: Replace `AppModel.swift`**

Replace the ENTIRE contents of `Core/Sources/AppCore/AppModel.swift` with:

```swift
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
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self?.tickAllActiveStatuses()
            }
        }
    }

    private func tickAllActiveStatuses() {
        let now = Date()
        for id in claudeSessions.keys {
            recomputeStatus(for: id, now: now)
        }
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
        if let existing = lastEventAt[reviewID], existing >= date {
            // out-of-order or duplicate; ignore
        } else {
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
```

(Differences from current `AppModel.swift`: added `claudeStatuses` dict; added `transcriptWatchers`, `lastEventAt`, `lastVerdictSnippet`, `notifiedIdleForSession`, `tickTimer` private state; added `notificationPoster` and `statusReader` init params; added `startTickTimerIfNeeded`, `tickAllActiveStatuses`, `attachTranscriptWatcher`, `handleTranscriptEvent`, `recomputeStatus`, `shouldFireReviewReady`, `postReviewReadyNotification` methods; `ensureClaudeSession` calls `attachTranscriptWatcher` and `recomputeStatus` after starting the session; `terminateClaudeSession` and `terminateAllClaudeSessions` clean up all the new dicts. Public API additions: `claudeStatuses`. Internal-visible additions for tests: `handleTranscriptEvent`, `recomputeStatus`.)

- [ ] **Step 5: Update `AppModelFactory.swift`**

Replace the ENTIRE contents of `Core/Sources/AppCore/AppModelFactory.swift` with:

```swift
import Foundation
import PRReviewModels
import ReviewStore
import GitHubKit
import CommandSupport
import WorktreeKit
import DiffKit

public enum AppModelFactory {
    @MainActor
    public static func makeDefault() throws -> AppModel {
        let settings = Settings.default
        let storeURL = URL(fileURLWithPath: settings.managedRoot).appendingPathComponent("store.json")
        let store = try ReviewStore(fileURL: storeURL)

        let ghPath = settings.ghPath ?? ToolResolver.resolve("gh") ?? "/opt/homebrew/bin/gh"
        let gitPath = settings.gitPath ?? ToolResolver.resolve("git") ?? "/opt/homebrew/bin/git"
        let claudePath = settings.claudePath ?? ToolResolver.resolve("claude") ?? "/opt/homebrew/bin/claude"

        let client = GitHubClient(runner: ProcessCommandRunner(), ghPath: ghPath)
        let worktreeManager = WorktreeManager(runner: ProcessCommandRunner(), gitPath: gitPath, managedRoot: settings.managedRoot)
        let worktreeProvider = WorktreeProvider(worktreeManager: worktreeManager)
        let diffService = DiffService(runner: ProcessCommandRunner(), gitPath: gitPath)
        let diffLoader = WorktreeDiffLoader(worktreeProvider: worktreeProvider, worktreeManager: worktreeManager, diffService: diffService)
        let cloneRegistrar = GitCloneRegistrar(runner: ProcessCommandRunner(), gitPath: gitPath)
        let notificationPoster = UserNotificationsPoster()

        return AppModel(
            store: store,
            client: client,
            diffLoader: diffLoader,
            worktreeProvider: worktreeProvider,
            cloneRegistrar: cloneRegistrar,
            claudePath: claudePath,
            notificationPoster: notificationPoster
        )
    }
}
```

(Difference from prior: constructs `UserNotificationsPoster()` and passes it as `notificationPoster:` to `AppModel.init`. `statusReader` falls back to its default.)

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --package-path Core 2>&1 | tail -10`
Expected: PASS — 3 new AppModel tests, bringing total to 93 (90 + 3). 0 failures.

If the tick-timer fires during a test and confuses assertions, that's a real problem — the test uses a 0.1s idle threshold so the timer (5s cadence) shouldn't interfere. If it does, the tests should still complete deterministically because they call `recomputeStatus` directly with fixed `now` values.

- [ ] **Step 7: Commit**

```bash
git add Core
git commit -m "feat: wire ClaudeStatus into AppModel with transcript watcher and idle notifications" --no-verify
```

Verify `git log -1 --pretty=%B` is clean.

---

## Task 5: Sidebar status badge + manual E2E

**Files:**
- Modify: `App/ContentView.swift`

- [ ] **Step 1: Update `ContentView.swift`**

Replace the ENTIRE contents of `App/ContentView.swift` with:

```swift
import SwiftUI
import PRReviewModels
import AppCore
import ClaudeSessionKit

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var showingAdd = false

    var body: some View {
        NavigationSplitView {
            List(model.reviews, selection: $model.selection) { review in
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("#\(review.number) · \(review.title)")
                            .lineLimit(1)
                        Text("\(review.owner)/\(review.repo) · \(review.author)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(relativeDateLabel(for: review.addedAt))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    StatusDot(status: model.claudeStatuses[review.id])
                        .help(statusTooltip(model.claudeStatuses[review.id]))
                }
                .contextMenu {
                    Button(role: .destructive) {
                        Task { await model.removeReview(id: review.id) }
                    } label: {
                        Label("Remove from List", systemImage: "trash")
                    }
                }
            }
            .onDeleteCommand {
                if let id = model.selection {
                    Task { await model.removeReview(id: id) }
                }
            }
            .navigationTitle("Reviews")
            .frame(minWidth: 260)
            .toolbar {
                ToolbarItem {
                    Button {
                        showingAdd = true
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddPRSheet(model: model, isPresented: $showingAdd)
            }
        } detail: {
            if let review = model.selectedReview() {
                DetailView(model: model, review: review)
            } else {
                Text("Select a review")
                    .foregroundStyle(.secondary)
                    .font(.title3)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .alert("Couldn't add PR", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.dismissError() } }
        )) {
            Button("OK") { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onChange(of: model.selection) { _, newSelection in
            guard let id = newSelection,
                  let review = model.reviews.first(where: { $0.id == id }) else { return }
            model.prefetch(for: review)
        }
    }
}

private struct StatusDot: View {
    let status: ClaudeStatus?

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private var color: Color {
        switch status {
        case .working:
            return .blue
        case .idle:
            return .gray
        case .ready(let code):
            return code == 0 ? .green : .orange
        case .failed:
            return .red
        case .starting, nil:
            return .clear
        }
    }
}

private func statusTooltip(_ status: ClaudeStatus?) -> String {
    switch status {
    case .working:
        return "Working"
    case .idle(let since, let snippet):
        let elapsed = Int(Date().timeIntervalSince(since))
        let mins = max(elapsed / 60, 0)
        let base = mins > 0 ? "Idle \(mins)m" : "Idle"
        if let snippet, !snippet.isEmpty {
            return "\(base) · \(snippet)"
        }
        return base
    case .ready(let code):
        return code == 0 ? "Review ready" : "Exited · code \(code)"
    case .failed(let reason):
        return reason
    case .starting:
        return "Starting…"
    case nil:
        return ""
    }
}

private func relativeDateLabel(for date: Date) -> String {
    let calendar = Calendar.current
    let now = Date()
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    let daysAgo = calendar.dateComponents([.day], from: date, to: now).day ?? 0
    if daysAgo < 7 { return "This Week" }
    if daysAgo < 14 { return "Last Week" }
    return "Older"
}
```

(Differences from current: added `import ClaudeSessionKit`; wrapped the row `VStack` in an `HStack` with a trailing `StatusDot`; added the `StatusDot` private view; added `statusTooltip` helper. The `.help(...)` modifier surfaces the tooltip on hover.)

- [ ] **Step 2: Regenerate the Xcode project + build + launch**

```bash
pkill -9 -x PRReview 2>/dev/null; sleep 1
xcodegen generate
xcodebuild -project PRReview.xcodeproj -scheme PRReview -configuration Debug -destination 'platform=macOS' -derivedDataPath DerivedData build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
open -n DerivedData/Build/Products/Debug/PRReview.app && sleep 3
pgrep -lx PRReview || echo "NOT RUNNING"
```

Expected: `** BUILD SUCCEEDED **` and a fresh PID. Do NOT click anything — the human runs the E2E checklist.

- [ ] **Step 3 (manual, the human runs this — do NOT mark complete without explicit confirmation):**

Run through this E2E checklist and report PASS/FAIL for each:

1. Add a new PR to a repo with a registered local clone. Within ~1 second, the sidebar row shows no dot (status `.starting`). Within ~5 seconds (after first claude output), the dot turns **blue** (`.working`).
2. While claude is actively generating output, the dot stays blue. Hover the row — tooltip says "Working".
3. Wait until claude finishes its review and goes quiet for >30 seconds. The dot turns **gray** (`.idle`). Tooltip shows "Idle Nm · <last assistant text>".
4. The first time a review goes `.working → .idle`, macOS prompts for notification permission. Approve. A system notification appears with "Review ready · #<NUM>" and the snippet/PR identifier as body.
5. Repeatedly working/idle transitions in the same session DO NOT post additional notifications. (Same session, same review id, `.notifiedIdleForSession` set blocks repeats.)
6. Inside claude, type `/exit`. The terminal shows the existing "claude exited" banner from Plan 11. The sidebar dot turns **green** (`.ready(0)`). Tooltip says "Review ready".
7. Add a second PR. Its dot lifecycle is independent — both PRs can be `.working` at the same time, displayed as two blue dots in the sidebar.
8. Quit the app (Cmd-Q). Re-launch. Sidebar dots are all clear (no `.starting` since no sessions are live yet). Click a PR → prefetch fires → its dot reappears as the session starts up.
9. Optional: disable notifications in System Settings → Notifications → PRReview, then trigger another idle transition. No system notification appears, but the dot still updates to gray.

- [ ] **Step 4: Commit**

```bash
git add App/ContentView.swift
git commit -m "feat: show claude status dot and tooltip in PR sidebar" --no-verify
```

Verify `git log -1 --pretty=%B` is clean.

---

## Self-review

- **Spec coverage:**
  - Key Decision #1 (per-review watcher tied to session) → Task 4 (`attachTranscriptWatcher` in `ensureClaudeSession`, cleanup in `terminateClaudeSession`/`terminateAllClaudeSessions`).
  - #2 (unified status model) → Task 1 (`ClaudeStatus` enum), Task 4 (`recomputeStatus`).
  - #3 (30s idle threshold) → Task 1 (`ClaudeStatusReader(idleThresholdSeconds: 30)` default), Task 4 (production uses default; tests override to 0.1).
  - #4 (colored dot + tooltip) → Task 5 (`StatusDot`, `statusTooltip`).
  - #5 (`UNUserNotificationCenter`, lazy permission) → Task 3 (`UserNotificationsPoster.postReviewReady`), Task 4 (`postReviewReadyNotification`).
  - #6 (`DispatchSource` watcher) → Task 2 (`TranscriptWatcher` impl).
  - #7 (module placement: ClaudeSessionKit + AppCore split) → Tasks 1–4.
  - Architecture data flow (5s tick + watcher-driven recompute) → Task 4 (`startTickTimerIfNeeded`, `tickAllActiveStatuses`, `recomputeStatus` called from both timer and event handler).
  - Defensive parsing → Task 2 (`MinimalEvent` + `try?` decoding, malformed-line skip).
  - Cleanup → Task 4 (`terminateClaudeSession`/`terminateAllClaudeSessions` clear all six dicts/sets).
  - Notification identifier per review id → Task 3 (`identifier: "review-ready-\(reviewID)"`).
- **Placeholder scan:** None. Every step has full file contents or call-site-precise edits. No "TBD" / "implement later" / "similar to" / "appropriate error handling".
- **Type consistency:**
  - `ClaudeStatus` cases (`starting`/`working`/`idle(since:, lastVerdictSnippet:)`/`ready(exitCode:)`/`failed(reason:)`) consistent across reader, AppModel, sidebar.
  - `ClaudeStatusReader.status(processState:lastEventAt:lastVerdictSnippet:now:)` signature consistent between definition and call sites.
  - `TranscriptWatcher.init(transcriptDir:)` + `start(onEvent:)` + `stop()` consistent.
  - `NotificationPosting.postReviewReady(reviewID:title:body:) async` consistent across protocol, stub, production impl.
  - `AppModel.init(...notificationPoster:statusReader:)` consistent across factory, test stubs, and 17 test call sites.

## Definition of done

- `swift test --package-path Core` → 93 tests, 0 failures (76 prior + 7 reader + 3 path + 4 watcher + 3 AppModel integration).
- App builds; sidebar shows colored dots for live claude sessions; first `.working → .idle` per session fires a system notification with snippet; dots clear when reviews are removed or sessions end.
- 8 commits total (5 task commits + 3 review-driven fix commits); working tree clean.
- Known follow-ups (out of scope): notification deep-link to "open System Settings" if denied; status persistence across app restarts; idle threshold in Settings UI; the merged-queue discovery polling (separate Phase 2 plan); animate `StatusDot` color transitions; make `firstIdleTransitionFiresNotificationOnce` test deterministic by exposing the notification dispatch Task as a testable handle.
