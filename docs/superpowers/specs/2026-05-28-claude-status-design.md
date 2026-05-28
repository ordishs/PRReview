# PR Review — Plan 12: Claude Status Design Spec

- **Date:** 2026-05-28
- **Status:** Approved (brainstorm) — ready for implementation planning
- **Plan number:** 12 (Phase 2 entry, follows Plan 11 Claude pane)
- **Master spec:** `docs/superpowers/specs/2026-05-27-pr-review-app-design.md`
- **Prior plan:** `docs/superpowers/specs/2026-05-28-claude-pane-design.md` (Plan 11)

## Summary

Extend `ClaudeSessionKit` with a transcript-tailing layer that derives a per-review
`ClaudeStatus` from two sources: the `ClaudeSession.state` process state (already
tracked) and the most-recent event timestamp scraped from
`~/.claude/projects/<encoded-cwd>/*.jsonl`. The status drives a colored dot in the
sidebar PR rows and a "review ready" system notification (via
`UNUserNotificationCenter`) when a review transitions `.working → .idle` for the
first time in its session. Built behind the `ClaudeStatus` interface the master spec
called out as the isolation boundary for Claude Code's internal transcript format.

## Goals

- Sidebar at-a-glance signal of which PRs have running, idle, ready, or failed reviews.
- "Review ready" system notification on first `.working → .idle` per session — the
  user can leave the app in the background and get pinged when claude is done.
- Defensive transcript parsing — degrades cleanly to "no badge" if Claude Code's
  jsonl schema changes; no crashes.
- Per-review watcher lifecycle tied to `ClaudeSession`: start with session, stop on
  termination.

## Non-goals

- Sentiment / LGTM detection from prose. Badge shows objective signals only
  (working / idle / clean exit / failed).
- Persisting status across app restarts. Status is derived at runtime; the transcript
  is the source of truth.
- Watching transcripts for PRs whose sessions haven't been started this app run.
- Notification preferences UI (Settings UI is a separate deferred follow-up).
- Background process management of orphaned claude sessions from prior app runs.

## Key decisions

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| 1 | Watcher scope and lifecycle | Per-review, starts with `ensureClaudeSession`, stops with session termination | Natural ownership boundary; no global state |
| 2 | Status model | Unified enum combining process state and transcript activity (`.starting / .working / .idle / .ready / .failed`) | Single source of truth for the sidebar; "review ready" notification fires on `.working → .idle` |
| 3 | Idle threshold | 30 seconds without transcript events | Long enough to absorb tool-call pauses, short enough to feel responsive |
| 4 | Badge UX | Colored dot at trailing edge of PR row + tooltip | Compact, scannable, doesn't change row layout |
| 5 | Notification API | `UNUserNotificationCenter`, permission requested on first `.working → .idle` per app run | Modern; just-in-time permission with user context |
| 6 | File-watch mechanism | `DispatchSource.makeFileSystemObjectSource` on the project dir + current jsonl | Native, low overhead, fires on append |
| 7 | Module placement | Extend `ClaudeSessionKit` with `TranscriptWatcher`, `ClaudeStatus`, `ClaudeStatusReader`. Notification posting in `AppCore` behind a `NotificationPosting` protocol | One package owns the claude integration; status posting test-injectable |

## Architecture

### New types in `ClaudeSessionKit`

```swift
public enum ClaudeStatus: Sendable, Equatable {
    case starting
    case working
    case idle(since: Date, lastVerdictSnippet: String?)
    case ready(exitCode: Int32)
    case failed(reason: String)
}

public struct ClaudeStatusReader: Sendable {
    public let idleThresholdSeconds: TimeInterval

    public init(idleThresholdSeconds: TimeInterval = 30)

    public func status(
        processState: ClaudeSessionState,
        lastEventAt: Date?,
        lastVerdictSnippet: String?,
        now: Date = Date()
    ) -> ClaudeStatus
}

@MainActor
public final class TranscriptWatcher {
    public init(transcriptDir: URL)
    public func start(onEvent: @escaping @MainActor (Date, String?) -> Void)
    public func stop()
}

public enum ClaudeTranscriptPath {
    public static func directoryURL(forWorktreePath path: String) -> URL
}
```

`ClaudeStatusReader` is a pure derivation: given process state, the most recent
transcript event time, an optional snippet, and the clock, it returns a status. No
side effects, trivially unit-testable with table-driven fixtures.

`TranscriptWatcher` is the side-effecty piece. On `start`, it ensures the transcript
dir exists (creating it is **not** our job — Claude Code creates it; we tolerate
absence), opens a `DispatchSource.makeFileSystemObjectSource` on the directory FD to
detect new `.jsonl` files appearing, and on the current latest `.jsonl` to detect
appends. On each append, it reads the new bytes, parses each new line as JSON, and
calls `onEvent(timestamp, snippet?)` with the latest event's timestamp and (best
effort) an assistant message snippet. `stop` cancels both sources and closes both
FDs.

`ClaudeTranscriptPath.directoryURL(forWorktreePath:)` is the encoded-cwd transform:
`/Users/me/foo` → `-Users-me-foo`. Slashes become hyphens; nothing else is touched.

### Defensive parsing

The line parser is intentionally minimal. For each new line:

```swift
struct MinimalEvent: Decodable {
    let type: String?
    let timestamp: String?           // ISO 8601 string
    let message: AnyDecodableMessage?
}
```

`timestamp` is `try?`-decoded with `ISO8601DateFormatter`; failure yields `nil`. The
assistant-message snippet is extracted only for `type == "assistant"` events, using
a best-effort traversal that tolerates schema changes. If the format diverges from
expectations, parsing yields `(timestamp: nil, snippet: nil)` for that line and
processing continues with the next line.

The watcher exposes only the `(Date, String?)` tuple to its consumer — Claude Code's
internal schema does not leak past the package boundary.

### `AppModel` integration

`AppModel` gains four parallel dicts keyed by review id:

```swift
public private(set) var claudeStatuses: [String: ClaudeStatus] = [:]
private var transcriptWatchers: [String: TranscriptWatcher] = [:]
private var lastEventAt: [String: Date] = [:]
private var lastVerdictSnippet: [String: String] = [:]
private var notifiedIdleForSession: Set<String> = []
```

Plus two new dependencies:

```swift
private let statusReader: ClaudeStatusReader
private let notificationPoster: NotificationPosting
```

`NotificationPosting` is a small protocol so `AppModel` doesn't have to import
`UserNotifications` directly and so tests can record without actually posting:

```swift
public protocol NotificationPosting: Sendable {
    func postReviewReady(reviewID: String, title: String, body: String) async
}
```

Production impl in `AppCore`:

```swift
public actor UserNotificationsPoster: NotificationPosting {
    public init() {}
    public func postReviewReady(reviewID: String, title: String, body: String) async {
        // Lazy-request permission on first call. If denied, return silently.
        // Otherwise post a UNNotificationRequest with identifier "review-ready-<id>"
        // so subsequent notifications for the same review overwrite the previous.
    }
}
```

### Status update flow

```
ensureClaudeSession(for: review)
    └─ after session insert →
       │   create TranscriptWatcher(transcriptDir: derived from worktreePath)
       │   transcriptWatchers[review.id] = watcher
       │   watcher.start { date, snippet in
       │       lastEventAt[review.id] = date
       │       if let snippet { lastVerdictSnippet[review.id] = snippet }
       │       recomputeStatus(for: review.id)
       │   }
       │   recomputeStatus(for: review.id)         // initial .starting

5-second tick (Timer.publish on AppModel.load) →
    for id in claudeSessions.keys: recomputeStatus(for: id)

recomputeStatus(for: id) →
    let newStatus = statusReader.status(
        processState: claudeSessions[id]?.state ?? .starting,
        lastEventAt: lastEventAt[id],
        lastVerdictSnippet: lastVerdictSnippet[id]
    )
    let oldStatus = claudeStatuses[id]
    claudeStatuses[id] = newStatus
    if shouldFireReviewReady(old: oldStatus, new: newStatus, id: id) {
        notifiedIdleForSession.insert(id)
        Task { await notificationPoster.postReviewReady(reviewID: id, title:..., body:...) }
    }
```

`shouldFireReviewReady` returns true iff:
- `newStatus` is `.idle(...)`, AND
- `oldStatus` was `.working`, AND
- `notifiedIdleForSession.contains(id) == false`.

### Cleanup

`terminateClaudeSession(for: id)` and `terminateAllClaudeSessions()` both call:

```swift
transcriptWatchers[id]?.stop()
transcriptWatchers.removeValue(forKey: id)
claudeStatuses.removeValue(forKey: id)
lastEventAt.removeValue(forKey: id)
lastVerdictSnippet.removeValue(forKey: id)
notifiedIdleForSession.remove(id)
```

### Sidebar badge

In `App/ContentView.swift`, the existing row's `VStack` is wrapped in an `HStack`
with a trailing `StatusDot` (filled `Circle` 8x8). Color mapping:

| Status | Color |
|---|---|
| `.starting`, `nil` | `.clear` (no visible dot) |
| `.working` | `.blue` |
| `.idle` | `.gray` |
| `.ready(0)` | `.green` |
| `.ready(non-zero)` | `.orange` |
| `.failed` | `.red` |

Tooltip via `.help(...)`:
- `.working` → "Working"
- `.idle(since: t, snippet: s)` → "Idle 2m · <s>" (snippet truncated to 80 chars)
- `.ready(0)` → "Review ready"
- `.ready(n)` → "Exited · code n"
- `.failed(reason)` → reason text

### Notification flow

`UserNotificationsPoster.postReviewReady` handles permission internally:

```
fetch UNUserNotificationCenter.notificationSettings()
switch authorizationStatus:
    case .notDetermined:
        request authorization for [.alert, .sound]
        if denied: return silently
    case .denied:
        return silently
    case .authorized, .provisional, .ephemeral:
        // proceed

build UNMutableNotificationContent
    title = "Review ready · #<NUM>"
    body  = lastVerdictSnippet ?? "<owner>/<repo> · <author>"
    sound = .default
identifier = "review-ready-<reviewID>"
add UNNotificationRequest
```

The identifier per review id means subsequent notifications for the same review
replace the previous one in Notification Center (no stacking spam).

## Data model

No schema changes. `Review.worktreePath` is the input to
`ClaudeTranscriptPath.directoryURL`. Status itself is volatile / runtime-only.

## Error handling

| Failure | Surface | Recovery |
|---|---|---|
| Transcript dir doesn't exist yet | Watcher waits for directory creation event | Silently waits; status stays `.starting` until first event |
| Malformed jsonl line | Skipped; next line attempted | Logged at debug; no user-facing error |
| Schema mismatch (no `timestamp` field) | Event yields `(nil, nil)` | Status derivation falls back to process state alone |
| Notification permission denied | `postReviewReady` returns silently | Badge still updates; user can re-enable via System Settings |
| DispatchSource cancellation while we hold the FD | Cleaned up in `stop()` and `deinit` | n/a |

## Testing strategy

A new test target `ClaudeSessionKitTests` is added (the package previously had no
test target):

- **`ClaudeStatusReader`** — table-driven unit tests for the seven-row state matrix
  in the design discussion. Pure function, zero I/O.
- **`TranscriptWatcher`** — integration tests against a temp directory:
  - Fixture jsonl committed under `Core/Tests/ClaudeSessionKitTests/Fixtures/`
    (PII-scrubbed real-format event lines).
  - Write the fixture, start watcher, assert callback fires with latest timestamp.
  - Append a new line, assert callback fires again.
  - Stop watcher, append, assert no callback.
- **`ClaudeTranscriptPath.directoryURL`** — unit test the encoding for a few paths
  including spaces.

`AppCoreTests` gets:

- `ensureClaudeSessionStartsTranscriptWatch` — given the stub provider, watcher is
  registered and initial status is `.starting`.
- `recomputeStatusFlipsToIdleAfterThreshold` — inject a stub `now` (or expose a
  `recomputeStatus(now:)` test seam), simulate a transcript event, advance the clock
  past threshold, assert `.idle`.
- `firstIdleTransitionFiresNotificationOnce` — recording `NotificationPosting` stub;
  trigger working → idle twice in one session, assert one post.

**Coverage delta:** Plan 12 adds ~6 new tests. Current 76 → roughly 82.

**Out of test scope:**
- Real `UNUserNotificationCenter` permission flows (manual E2E).
- DispatchSource kqueue behavior under high event rates (relies on system).
- Multi-watcher interaction across many simultaneous PRs (covered by manual E2E).

## File inventory

**Created (`Core`):**
- `Core/Sources/ClaudeSessionKit/ClaudeStatus.swift`
- `Core/Sources/ClaudeSessionKit/ClaudeStatusReader.swift`
- `Core/Sources/ClaudeSessionKit/TranscriptWatcher.swift`
- `Core/Sources/ClaudeSessionKit/ClaudeTranscriptPath.swift`
- `Core/Sources/AppCore/NotificationPosting.swift` (protocol)
- `Core/Sources/AppCore/UserNotificationsPoster.swift` (production impl)
- `Core/Tests/ClaudeSessionKitTests/` (new test target — `ClaudeStatusReaderTests.swift`,
  `TranscriptWatcherTests.swift`, `ClaudeTranscriptPathTests.swift`,
  `Fixtures/sample-transcript.jsonl`)

**Modified (`Core`):**
- `Core/Package.swift` — register the new `ClaudeSessionKitTests` test target.
- `Core/Sources/AppCore/AppModel.swift` — add the four dicts, the `statusReader` +
  `notificationPoster` init params, `handleTranscriptEvent`, `recomputeStatus`, the
  tick timer, the `shouldFireReviewReady` helper. Modify `ensureClaudeSession`,
  `terminateClaudeSession`, `terminateAllClaudeSessions` to wire/unwire the watcher.
- `Core/Sources/AppCore/AppModelFactory.swift` — construct
  `ClaudeStatusReader()` and `UserNotificationsPoster()`, pass to `AppModel`.
- `Core/Tests/AppCoreTests/AppModelTests.swift` — add `StubNotificationPoster`,
  thread it through existing `AppModel(...)` constructions, add the three new tests.

**Modified (`App`):**
- `App/ContentView.swift` — wrap PR row `VStack` in an `HStack`, add `StatusDot`
  view + `.help(...)` tooltip.

## Build phasing context

This plan begins **Phase 2 · Intelligence** from the master spec:

> "`GitHubKit` discovery/polling + dedup (the merged queue), transcript tailing →
> sidebar badges + verdict snippet"

Discovery/polling is a separate later plan; this one delivers the transcript-tailing
half of Phase 2. After it lands, Phase 2 is half complete; Phase 3 (Notifications &
polish) is partly delivered (the review-ready notification half).

## Open questions / risks

- **Claude Code transcript schema drift.** The `assistant` event's `message` field
  structure is internal. The minimal-event parser only requires `timestamp`; the
  snippet extraction is best-effort. If the schema changes incompatibly, the badge
  still works (status derivation uses transcript timestamps alone); only the
  snippet display degrades.
- **Encoded-cwd transform.** Verified empirically against the user's home dir; not
  formally documented by Claude Code. If the encoding changes (e.g., new escaping
  for special characters), the watcher will watch an empty dir and never fire — the
  badge would stay `.starting` indefinitely while the process actually runs. A
  fallback "scan `~/.claude/projects/` for any dir matching the latest activity"
  is possible but adds complexity; defer until/unless the simple encoding breaks.
- **5-second tick on `Timer.publish`** — energy cost is minimal but not zero. If the
  app is backgrounded with no live sessions, the timer still ticks; we could gate
  it on `!claudeSessions.isEmpty` but the cost isn't worth the complexity.
- **Notification permission denied flow.** If the user denies once, every subsequent
  `.working → .idle` is silent. We don't surface this state anywhere yet. A future
  Settings UI could show "Notifications: off — open System Settings" with a deep
  link. Not in Plan 12.

## Out of scope (explicit non-goals)

- Persisting `lastEventAt` / `lastVerdictSnippet` across app restarts (these are
  recomputed from the transcript file on session start).
- Surfacing the verdict snippet in the sidebar text itself (only via tooltip).
- Re-running stale transcripts to compute "what was the LAST status" for reviews
  whose sessions aren't live this app run.
- Background-discovery polling and the merged queue (separate Phase 2 plan).
- Force-push detection while a session is live (Plan 11 deferred).
- Settings UI for the idle threshold or notification toggle.
- Localized notification copy.
