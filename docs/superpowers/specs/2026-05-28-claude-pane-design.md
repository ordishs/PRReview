# PR Review — Plan 11: Claude Pane Design Spec

- **Date:** 2026-05-28
- **Status:** Implemented with amendments — see "Post-implementation amendments" below
- **Plan number:** 11 (Phase 1, follows Plan 10 management UX)
- **Master spec:** `docs/superpowers/specs/2026-05-27-pr-review-app-design.md`

> **Post-implementation amendments**
>
> The original brainstorm-time decisions below are preserved for context. Manual
> E2E surfaced behavior the brainstorm assumed but Claude Code didn't deliver,
> and the user asked us to match the legacy `~/.local/bin/review` zsh script's
> invocation exactly. The following amendments override the original decisions
> and are the authoritative contract for Plan 12 onwards:
>
> 1. **Resume strategy (overrides Decision #1):** `--continue` is **not** passed.
>    Each launch is a fresh `claude` session in the worktree cwd. The session is
>    named via `--name "<NUM> - <AUTHOR>"` so the user can find it later via
>    `claude --resume` if needed. We trialled gated `--continue` (probe
>    `~/.claude/projects/<encoded-cwd>`) but dropped it to match the script.
> 2. **Launch invocation (refines Decisions #1, #7):** The exact args, in order,
>    are: `settings.claudeLaunchArgs` (prepended), `--name <SESSION>`,
>    `--effort max`, `--dangerously-skip-permissions`,
>    `review.claudeFlags` (per-review), then `/review <URL>` as the trailing
>    positional argument (a single string containing the URL).
> 3. **Shell wrapper:** `/bin/zsh -l -c "cd <cwd> && exec <claude> <args>..."`
>    (login shell so `.zshenv`/`.zprofile` are sourced for the full user env).
>    Originally `/bin/sh -c`.
> 4. **Exit overlay layout (refines Decision #4):** The exit banner is rendered
>    in a `VStack` above the terminal, not a `ZStack` overlapping the top of it.
>    The original layout obscured the very text the banner was reporting on.
> 5. **Pre-warm (new):** `AppModel.prefetch(for:)` fires `ensureClaudeSession` and
>    `loadDiff` as fire-and-forget tasks when a PR is added (`addPR`) or
>    selection changes in the sidebar (`ContentView.onChange(of: selection)`).
>    Matches the legacy script's eager-all-three behavior.
> 6. **Concurrency guards (new):** `ensureClaudeSession` and `loadDiff` re-check
>    state after their `await` suspension points to handle concurrent prefetch
>    races and in-flight-during-removeReview. Without these, prefetch could
>    double-start a session or resurrect a removed review in the store.
> 7. **Terminal focus on attach (new):** `TerminalHost.makeNSView` calls
>    `terminal.window?.makeFirstResponder(terminal)` on the next runloop tick so
>    the terminal grabs focus as soon as the Claude tab is mounted.
> 8. **Stale worktree handling (refines worktree gating):**
>    `WorktreeManager.createWorktree` and `WorktreeProvider.ensureWorktree` both
>    return early when the target worktree path already exists on disk. If the
>    directory is a stale leftover (not a registered git worktree), downstream
>    git ops surface the error inline — acceptable degradation, tracked as
>    follow-up.
> 9. **Session-name detail (deferred):** The legacy script's optional
>    `/#<ISSUE>` segment in the session name is not implemented — `Review` does
>    not currently carry `closingIssuesReferences`. Tracked as a GitHubKit
>    follow-up.

## Summary

Replace the placeholder in `DetailView.swift` for the **Claude Review** tab with a real
embedded terminal: a SwiftTerm `NSView` hosting a PTY that runs the `claude` CLI in the
PR's worktree. The worktree is materialised lazily — same mechanism the Diff pane uses
today — and the same first-half of that mechanism is refactored into a shared
`WorktreeProvider` so both panes go through one resolution path.

Sessions are kept alive across tab switches and PR switches; context is rehydrated
across app launches via `claude --continue`. Transcript tailing for sidebar status
badges is **out of scope** here and lands in Plan 12 behind the `ClaudeStatus`
interface from the master spec.

## Goals

- Working Claude Review tab for any selected PR: terminal renders, `claude` runs in
  the worktree, scrollback survives tab/PR switches.
- One session per review, kept alive for the lifetime of the app, rehydrated on next
  launch via `claude --continue`.
- Shared lazy-worktree path with the Diff pane — one resolution, one persisted
  `Review.worktreePath`.
- Clean exit UX (process exited / failed to launch / `claude` not found) with an
  inline Restart action.
- No orphan `claude` processes after app quit or PR removal.

## Non-goals (this plan)

- Transcript tailing → sidebar status badges or "review ready" notifications (Plan 12).
- Settings UI for editing `claudeLaunchArgs` / `claudePath` (Phase 3).
- Per-review flag-editing UI (the field is honored if set, not editable through UI).
- Force-push / worktree-vanished detection while a session is live.
- Suspend-on-pane-switch policy for PTYs (Risk #4 in the master spec; revisit when it
  bites).
- Unit-test coverage of the launch-arg builder and state machine (de-scoped from this
  plan; the existing `AppModel` tests are kept passing through the refactor and one
  new claude-pane-state test is added).

## Key decisions

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| 1 | Resume strategy | Always pass `--continue` (last arg) | Simplest; Claude Code handles the no-prior-session case; no transcript-format coupling in Plan 11 |
| 2 | SwiftTerm placement | Imported by `ClaudeSessionKit`; `ClaudeSession` owns the `TerminalView` instance | Hides SwiftTerm types behind the package; App stays thin |
| 3 | Worktree gating | Extract a `WorktreeProvider` shared with `WorktreeDiffLoader` | One source of truth for lazy resolution; Claude path doesn't pay for diff parsing |
| 4 | Exit UX | Inline overlay with "exited · code N" + Restart button; terminal stays visible | User keeps scrollback; one click recovers |
| 5 | Session lifecycle | One session per review, kept alive across tab/PR switches, killed on review removal and app quit | Matches master spec; orphan prevention is explicit |
| 6 | View keep-alive | `ClaudeSession` holds a strong reference to a single `TerminalView`; an `NSViewRepresentable` reparents it across SwiftUI rebuilds | Survives tab switches without losing buffer or restarting the PTY |
| 7 | Per-review args | `Review.claudeFlags` honored if present (appended after global args, before `--continue`) | Field already on model; no schema change, no UI yet |

## Architecture

### Modules touched

- **`ClaudeSessionKit`** (Core package) — grows from an empty namespace into the home of
  `ClaudeSession`, `ClaudeSessionState`, `ClaudeLaunchSpec`, `ClaudeLaunchBuilder`.
  Imports `SwiftTerm` and `PRReviewModels`.
- **`AppCore`** (Core package) — gains `WorktreeProviding` + concrete `WorktreeProvider`,
  refactors `WorktreeDiffLoader` to compose it, extends `AppModel` with
  `ensureClaudeSession(for:)`, a `claudeSessions: [String: ClaudeSession]` registry,
  and a `claudePaneState: [String: ClaudePaneState]` dict. Adds `ClaudeSessionKit` to
  its dependencies.
- **`App`** target — new `ClaudePaneView.swift` (the SwiftUI view, `TerminalHost`
  representable, exit/launch-failure overlay). `DetailView.swift` is edited to call it.
  `PRReviewApp.swift` wires app-quit cleanup. `project.yml` gains the
  `ClaudeSessionKit` product dependency.

### `ClaudeSessionKit` shape

```swift
public enum ClaudeSessionState: Sendable, Equatable {
    case starting
    case running
    case exited(code: Int32)
    case failedToLaunch(String)
}

public struct ClaudeLaunchSpec: Sendable, Equatable {
    public let executable: String
    public let cwd: String
    public let arguments: [String]
}

public enum ClaudeLaunchBuilder {
    public static func build(
        settings: Settings,
        review: Review,
        worktreePath: String,
        resolvedClaudePath: String
    ) -> ClaudeLaunchSpec {
        let args = settings.claudeLaunchArgs
            + (review.claudeFlags ?? [])
            + ["--continue"]
        return ClaudeLaunchSpec(
            executable: resolvedClaudePath,
            cwd: worktreePath,
            arguments: args
        )
    }
}

@MainActor
@Observable
public final class ClaudeSession {
    public private(set) var state: ClaudeSessionState = .starting
    public let terminalView: TerminalView          // SwiftTerm
    public let spec: ClaudeLaunchSpec

    public init(spec: ClaudeLaunchSpec) { /* construct TerminalView, wire delegate */ }
    public func start()       { /* spawn LocalProcess; first byte → .running */ }
    public func restart()     { /* terminate if running, then start() */ }
    public func terminate()   { /* SIGTERM, wait 500ms, SIGKILL if still alive */ }
}
```

`ClaudeSession` is both the `LocalProcessDelegate` and the owner of the `TerminalView`.
Data from the PTY is forwarded to `TerminalView` so it renders normally, with a hook
for our state-machine bookkeeping. `--continue` is always the last argument so it
can't be accidentally overridden by an earlier flag in `claudeLaunchArgs` or
`claudeFlags`.

### `WorktreeProvider` extraction

New file `Core/Sources/AppCore/WorktreeProviding.swift`:

```swift
public protocol WorktreeProviding: Sendable {
    func ensureWorktree(for review: Review, registeredClonePath: String?) async throws -> String
}

public struct WorktreeProvider: WorktreeProviding {
    private let worktreeManager: WorktreeManager
    public init(worktreeManager: WorktreeManager) { self.worktreeManager = worktreeManager }

    public func ensureWorktree(for review: Review, registeredClonePath: String?) async throws -> String {
        let remoteURL = "https://github.com/\(review.owner)/\(review.repo).git"
        let clonePath = try await worktreeManager.resolveClone(
            owner: review.owner, repo: review.repo,
            remoteURL: remoteURL, registeredClonePath: registeredClonePath
        )
        if let existing = review.worktreePath, FileManager.default.fileExists(atPath: existing) {
            return existing
        }
        return try await worktreeManager.createWorktree(
            clonePath: clonePath, owner: review.owner, repo: review.repo, number: review.number
        )
    }
}
```

`WorktreeDiffLoader` is refactored to take `WorktreeProviding` in its init and call
`ensureWorktree(...)` instead of duplicating that logic; the merge-base + diff steps
stay where they are.

### `AppModel` extensions

```swift
public private(set) var claudeSessions: [String: ClaudeSession] = [:]
public private(set) var claudePaneState: [String: ClaudePaneState] = [:]

public enum ClaudePaneState: Sendable {
    case idle
    case preparingWorktree
    case worktreeFailed(String)
    case sessionLive
}

private let worktreeProvider: WorktreeProviding
private let claudePath: String          // resolved at construction; nil → "" sentinel for "not found"

public init(
    store: ReviewStore,
    client: GitHubClient,
    diffLoader: DiffLoading,
    worktreeProvider: WorktreeProviding,
    cloneRegistrar: CloneRegistering,
    claudePath: String
) { ... }

public func ensureClaudeSession(for review: Review) async {
    if claudeSessions[review.id] != nil { claudePaneState[review.id] = .sessionLive; return }
    claudePaneState[review.id] = .preparingWorktree
    do {
        let path = try await worktreeProvider.ensureWorktree(
            for: review,
            registeredClonePath: registeredClonePath(for: review)
        )
        if review.worktreePath != path {
            var updated = review; updated.worktreePath = path
            try await store.upsert(updated)
            reviews = await store.allReviews()
        }
        let spec = ClaudeLaunchBuilder.build(
            settings: .default, review: review,
            worktreePath: path, resolvedClaudePath: claudePath
        )
        let session = ClaudeSession(spec: spec)
        claudeSessions[review.id] = session
        claudePaneState[review.id] = .sessionLive
        session.start()
    } catch {
        claudePaneState[review.id] = .worktreeFailed(String(describing: error))
    }
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
```

`removeReview(id:)` calls `terminateClaudeSession(for: id)` before deleting the
worktree and persisted review. App quit (via `NSApplication.willTerminateNotification`
in `PRReviewApp`) calls `terminateAllClaudeSessions()`.

The `claudePath` is resolved once in `AppModelFactory` using the same pattern as
`gh`/`git`: `Settings.default.claudePath ?? ToolResolver.resolve("claude") ?? "/opt/homebrew/bin/claude"`.
If the resolved path doesn't exist on disk, `ClaudeSession.start()` reports
`.failedToLaunch("claude not found at <path>")` and the pane renders the
"claude not found" banner copy.

### View hosting (`App/ClaudePaneView.swift`)

```swift
struct ClaudePaneView: View {
    let model: AppModel
    let review: Review

    var body: some View {
        Group {
            switch model.claudePaneState[review.id] ?? .idle {
            case .idle, .preparingWorktree:
                ProgressView("Preparing worktree…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .worktreeFailed(let msg):
                ErrorBanner(message: msg, actionTitle: "Retry") {
                    Task { await model.ensureClaudeSession(for: review) }
                }
            case .sessionLive:
                if let session = model.claudeSessions[review.id] {
                    ZStack(alignment: .top) {
                        TerminalHost(session: session)
                        exitOverlay(session)
                    }
                }
            }
        }
        .task(id: review.id) { await model.ensureClaudeSession(for: review) }
    }

    @ViewBuilder
    private func exitOverlay(_ session: ClaudeSession) -> some View { /* renders for .exited and .failedToLaunch */ }
}

struct TerminalHost: NSViewRepresentable {
    let session: ClaudeSession

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let terminal = session.terminalView
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
```

Switching tabs tears down the wrapping `container` NSView, but the `TerminalView` is
strongly held by `ClaudeSession` and survives. Re-entering the pane reparents the same
`TerminalView` into a new container — scrollback intact, process untouched.

The exit overlay renders only when `session.state` is `.exited(code:)` or
`.failedToLaunch(msg:)`. It floats at the top of the terminal so the user can still
read the previous output. The Restart button calls `session.restart()`. For
"claude not found" (detected by `failedToLaunch` containing `ENOENT` or by the
resolved path not existing on disk), the copy changes to point at Settings.

### Launch and exit handling inside `ClaudeSession`

1. `start()` sets state to `.starting`, constructs a `SwiftTerm.LocalProcess` with
   `self` as `LocalProcessDelegate`, and calls
   `startProcess(executable: spec.executable, args: spec.arguments, environment: ProcessInfo.processInfo.environment, execName: nil)` with `cwd` configured via `chdir` before spawn or via
   `LocalProcess`'s working-directory option (depending on SwiftTerm API version pinned).
2. The first `processStdoutData` (or `dataReceived`) callback flips state to `.running`.
3. The same delegate callback forwards data to `terminalView` so it renders.
4. `processTerminated(source:exitCode:)` sets state to `.exited(code)`.
5. If `startProcess` throws synchronously, state becomes
   `.failedToLaunch(error.localizedDescription)`. ENOENT (resolved path doesn't exist
   or kernel returns ENOENT) drives the "claude not found" banner branch.
6. `terminate()` sends `SIGTERM` via `kill(pid, SIGTERM)`, waits up to ~500 ms, then
   sends `SIGKILL` if the process hasn't exited. Used by `removeReview` and app-quit.
7. `restart()` calls `terminate()` if running, then `start()` — reuses the same
   `TerminalView` so previous output stays in the buffer.

## Data model

No schema changes. `Review.claudeFlags: [String]?` already exists and is honored.
`Review.worktreePath: String?` is still persisted by the worktree-ensure path, now
shared with the Diff loader.

## Error handling

| Failure | Surface | Recovery |
|---------|---------|----------|
| Worktree ensure fails (clone auth, git error) | `.worktreeFailed(msg)` rendered as a banner with stderr | Retry button re-runs `ensureClaudeSession` |
| `claude` not found (path doesn't exist or ENOENT) | `.failedToLaunch` with "claude not found" copy | Restart button after the user fixes their setup |
| `claude` crashes / `/exit` | `.exited(code)` overlay with code | Restart button spawns a fresh `claude --continue` |
| App quit with live sessions | `terminateAllClaudeSessions()` walks the registry | SIGTERM then SIGKILL after 500ms |
| Review removed with live session | `terminateClaudeSession(for:)` runs before worktree deletion | n/a |

Out of scope for Plan 11: worktree directory deleted underneath a running session, the
PR force-pushed under a running session, child processes failing because of
environment issues. These are revisited if they show up in real use.

## Build phasing context

This plan is the last unimplemented vertical of **Phase 1 · Core loop** from the
master spec ("Claude pane (SwiftTerm)"). After it lands:

- **Plan 12 (queued):** transcript tailing → sidebar status badges + "review ready"
  notification, behind the `ClaudeStatus` interface. Will read transcripts from
  `~/.claude/projects/<encoded-cwd>/*.jsonl`; the encoded-cwd is derivable from
  `Review.worktreePath` which Plan 11 already populates.
- **Plan 9 (deferred):** Diff pane enhancements (file tree, Unified/Split toggle,
  `@@` headers) — independent.

## File inventory

**Created:**

- `Core/Sources/ClaudeSessionKit/ClaudeSession.swift`
- `Core/Sources/ClaudeSessionKit/ClaudeSessionState.swift`
- `Core/Sources/ClaudeSessionKit/ClaudeLaunchBuilder.swift`
- `Core/Sources/AppCore/WorktreeProviding.swift`
- `App/ClaudePaneView.swift`

**Modified:**

- `Core/Package.swift` — add SwiftTerm SPM dep (pinned to a specific tag); add
  `ClaudeSessionKit` deps on `SwiftTerm` + `PRReviewModels`; add `AppCore` dep on
  `ClaudeSessionKit`.
- `Core/Sources/AppCore/WorktreeDiffLoader.swift` — compose `WorktreeProviding` and
  call `ensureWorktree(...)` instead of doing it inline.
- `Core/Sources/AppCore/AppModel.swift` — add `worktreeProvider`, `claudePath`,
  `claudeSessions`, `claudePaneState`, `ensureClaudeSession(for:)`,
  `terminateClaudeSession(for:)`, `terminateAllClaudeSessions()`; have
  `removeReview(id:)` call `terminateClaudeSession(for:)`.
- `Core/Sources/AppCore/AppModelFactory.swift` — build a single `WorktreeProvider`,
  share it with the diff loader and `AppModel`; resolve `claudePath`.
- `Core/Tests/AppCoreTests/AppModelTests.swift` — add a `StubWorktreeProvider`,
  thread it through the four `AppModel(...)` construction sites; add one
  `ensureClaudeSession` worktree-failure-state test.
- `App/DetailView.swift` — replace the `.claude` placeholder with
  `ClaudePaneView(model: model, review: review)`.
- `App/PRReviewApp.swift` — observe `NSApplication.willTerminateNotification` and call
  `model.terminateAllClaudeSessions()`.
- `project.yml` — `PRReview` target deps += `ClaudeSessionKit` product.

## Testing strategy

- `swift test --package-path Core` must still pass after the `WorktreeProvider`
  refactor. Existing diff-related `AppModel` tests are kept passing by injecting a
  `StubWorktreeProvider` alongside the existing `StubDiffLoader`. Net delta: **+1
  new test** (`ensureClaudeSession` flips `claudePaneState[id]` to `.worktreeFailed`
  when the provider throws). All other existing tests continue to pass unchanged.
- `ClaudeSessionKit` itself is **manually verified** in Plan 11 — no unit tests for
  the launch-arg builder or state machine in this plan. Rationale: the launch builder
  is trivial pure string concatenation, the state machine is exercised end-to-end by
  the manual E2E, and the process-spawn paths require a real PTY anyway.

## Manual E2E checklist

1. `swift test --package-path Core` → all tests pass, including the one new
   `ensureClaudeSession`-worktree-failure assertion.
2. `pkill -9 -x PRReview; xcodegen generate; xcodebuild ... build CODE_SIGNING_ALLOWED=NO`
   succeeds.
3. `open -n DerivedData/Build/Products/Debug/PRReview.app` → fresh PID.
4. Select a PR whose worktree already exists (from earlier diff testing). Click
   **Claude Review**. Verify: terminal renders, prompt appears, `claude` is running
   in the worktree (visible via `ps` or by issuing `pwd` to claude).
5. Tab to **Diff**, then back to **Claude Review**. Verify: same terminal, scrollback
   intact, no respawn.
6. Type `/exit` inside `claude`. Verify: "claude exited · code 0" overlay appears;
   clicking Restart spawns a new session in the same `TerminalView`.
7. Pick a different PR in the sidebar, then back. Verify: each PR keeps its own
   session running independently; sidebar switch is fast.
8. Quit the app. In Activity Monitor: confirm no orphan `claude` processes remain.
9. Move `claude` off PATH (or temporarily edit `Settings.default.claudePath` to a
   bogus value in code), relaunch. Verify: "claude not found" banner renders inside
   the pane with the Restart button enabled.
10. Re-open one of the PRs from step 4. Verify: terminal launches with `--continue`
    and shows prior context (visible as the previous prompt in scrollback or a
    "Continuing previous session" line from claude).

## Open questions / risks

- **SwiftTerm `LocalProcess` cwd API** — confirm the exact API used to set the
  working directory at process spawn time (varies between versions). The
  implementation plan pins a specific SwiftTerm tag and uses that version's API.
- **N live PTYs** — Risk #4 from the master spec. Phase 1 manual E2E with a handful
  of reviews is fine; a suspend-on-pane-switch policy is a follow-up if it becomes a
  resource issue.
- **`claude --continue` from a fresh cwd** — relies on Claude Code starting a new
  session cleanly when no prior transcript exists in `~/.claude/projects/<cwd>`. If
  it errors instead of starting fresh, fall back to spawning without `--continue` on
  the first try and adding it back on restart.

## Out of scope (explicit non-goals)

- Transcript tailing → sidebar status badges, "review ready" notification (Plan 12).
- Settings UI to edit `claudeLaunchArgs` / `claudePath` (Phase 3).
- Per-review claude flag editing UI (the field is honored if set programmatically;
  no editor yet).
- Force-push / worktree-vanished detection while a session is running.
- Suspend-on-pane-switch lifecycle policy for live PTYs.
- ClaudeSessionKit unit tests for launch builder / state machine.
