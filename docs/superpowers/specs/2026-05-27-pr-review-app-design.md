# PR Review — Design Spec

- **Date:** 2026-05-27
- **Status:** Approved (brainstorm) — ready for implementation planning
- **Working title:** PR Review (macOS app); repo `code-reviewer`

## Summary

A native macOS application that replaces the current PR-review workflow — a manually
coupled iTerm2 pane (running the `claude` CLI in a per-PR worktree) beside a browser
pane on the GitHub PR page. Today those panes are arranged by hand, one window per PR,
and the GitHub view is slow because it is remote.

The app gives a single window with a **left sidebar listing PR reviews** and a **right
panel that flips between three views of the selected PR**: the Claude Code review
(embedded terminal), the GitHub PR page (web view), and a **locally-rendered native
diff** modeled on GitHub's "Files changed." Code is available locally via a git
worktree of the PR branch, so the diff is native-speed. Reviews are added by URL and
also auto-discovered from GitHub.

## Goals

- One window, fast switching between many in-progress PR reviews.
- Keep the exact interactive Claude Code experience the user trusts today.
- Native-speed local diff viewing instead of the slow remote GitHub UI.
- Low-friction: a PR shows up (discovered or added), open it, review it.

## Non-goals (for now)

- Replacing GitHub entirely — the web view remains the escape hatch for conversation,
  checks, and merge.
- A general multi-user / team product. This is a single-user power tool.
- Cross-platform. macOS only.

## Key decisions (decision log)

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| 1 | Overall layout | Sidebar (PR list) + right panel with 3-way segmented control (Claude / GitHub / Diff); selection swaps all three | Matches the user's proven mental model |
| 2 | Claude Code integration | **Hybrid**: embedded terminal (SwiftTerm) runs the `claude` CLI in the worktree, **plus** tail the session transcript on disk for native status | Faithful + robust, without reimplementing Claude's TUI |
| 3 | PR list source | **Both, merged**: auto-discover via `gh` (review-requested / assignee) **and** manual Add-by-URL, deduped by id | Convenience of a queue + control of manual adds |
| 4 | Worktree model | **Hybrid**: use a registered local clone if present, otherwise auto-clone into a managed dir; one worktree per PR | Reuses existing checkouts, still works for unknown repos |
| 5 | Diff viewer | **Native render**: parse `git diff`, AppKit/SwiftUI, tree-sitter highlighting | The point of going native; enables clickable lines |
| 6 | Scope | **Full vision**, built as usable vertical slices (phases 1–4) | Ambitious target, incremental delivery |
| 7 | Project structure | **Hybrid modular**: headless logic in 5 Swift packages, thin SwiftUI app on top | Isolates risky/testable logic without over-ceremony |

## Assumptions

- **GitHub access via the `gh` CLI** for discovery, metadata, and (later) posting
  comments — reuses existing auth; no OAuth app to build.
- **GitHub tab = `WKWebView`** pointed at the PR page, with a persistent website data
  store so login sticks.
- **Target macOS 14+**, SwiftUI app lifecycle; AppKit (`NSViewRepresentable`) hosts the
  terminal, web, and diff surfaces.
- `git`, `gh`, and `claude` are installed and on `PATH` (paths auto-resolved,
  overridable in Settings).

## Architecture

Three layers:

1. **Native App (SwiftUI + AppKit)** — thin. `Sidebar` (merged PR list, Add, status
   badges) and `Detail` (segmented control hosting the three panes).
2. **Core (Swift Package modules, headless, unit-testable)** — `GitHubKit`,
   `WorktreeKit`, `ClaudeSessionKit`, `DiffKit`, `ReviewStore`.
3. **System / external** — `gh`, `git`, `claude` CLIs, `~/.claude/projects/*.jsonl`
   transcripts, and `github.com` (in the web view).

**Data flow:** modules perform side effects and own truth; `ReviewStore` holds durable
state; an app-level `@Observable` view-model composes module outputs (via `AsyncStream`
/ Combine) and views observe it. One direction: user action → view-model → module →
state update → view refresh.

## Data model & persistence (`ReviewStore`)

Core principle: **separate durable facts from derived state.** Disk already holds the
truth for volatile data (Claude transcript, git, GitHub), so it is recomputed, not
persisted.

**Durable (persisted) — small, changes rarely:**

```
Review
  id            "owner/repo#number"   (stable key)
  owner, repo, number, url
  title, author, headBranch, baseBranch     (cached metadata)
  origin        .discovered | .added | both (why it's in the list)
  worktreePath? (set once a worktree exists)
  prState       cached: open | draft | merged | closed
  notes?        freeform
  claudeFlags?  per-review overrides (model, recaps, etc.)
  addedAt, lastOpenedAt

RegisteredRepo
  remoteIdentity   e.g. github.com/bsv-blockchain/teranode
  localClonePath   existing clone (hybrid: preferred source)
  defaultBase

Settings
  managedRoot      default ~/Library/Application Support/PRReview
  discoveryQueries [review-requested:@me, assignee:@me, …], pollInterval
  toolPaths        gh / git / claude (auto-resolved, overridable)
  claudeLaunchArgs e.g. --dangerously-skip-permissions, model
  notificationsEnabled
  diffDefaults     unified | split, ignoreWhitespace
```

**Derived at runtime (never persisted — disk is source of truth):**

- **Claude status** (running / idle / done, last verdict, duration) ← tailed transcript.
- **Live PR state & metadata** ← `gh`.
- **Diff model** ← `git`.

**Persistence:** `ReviewStore` is an `actor` exposing plain `Codable` value types,
writing one atomic JSON document at `managedRoot/store.json`. At this scale JSON is
sufficient and trivially testable; behind the store's protocol it can be swapped for
SQLite/SwiftData later without touching the UI. Volatile status stays in memory,
recomputed from disk and optionally cached for offline display.

## PR pipeline (`GitHubKit` + `WorktreeKit`)

A PR becomes a local, reviewable thing through this pipeline; **worktrees are created
lazily, on first open.**

```
Discovery poll (gh)  ─┐
Add by URL           ─┴─▶ GitHubKit (fetch metadata, dedup by id, origin flags)
                              │
                              ▼
                         ReviewStore (upsert Review) ──▶ appears in sidebar
                              │   (on first open — lazy)
                              ▼
                         WorktreeKit: resolve clone (hybrid)
                            registered clone?  → use local checkout
                            otherwise          → auto-clone into managedRoot/repos
                            then: fetch refs/pull/N/head → git worktree add
                              │
                              ▼
                         ✓ Worktree ready  →  Claude / GitHub / Diff panes
```

**`GitHubKit`** — wraps `gh` behind an injectable command runner (tests feed canned JSON):

- **Discovery:** runs configured `gh search prs` queries on a timer; returns PR
  identities + metadata.
- **Add-by-URL:** parses `owner/repo/number`; fetches via `gh pr view --json`.
- **Merge/dedup:** one set keyed by `id`; `origin` flags so a both-discovered-and-added
  PR appears once.
- **Lifecycle:** each refresh updates `prState`; merged/closed PRs are **badged, not
  auto-removed** (user dismisses).
- **Comments (Phase 4):** posts inline review comments via `gh api`.

**`WorktreeKit`** — wraps `git` behind an injectable runner:

- **Hybrid clone resolution** as above.
- **Worktree creation:** fetch `refs/pull/N/head` (fork-safe), then `git worktree add`
  at `managedRoot/worktrees/<owner>-<repo>-prN`.
- **Diff base:** merge-base(head, target) so the Diff tab matches GitHub's 3-dot
  "Files changed."
- **Refresh:** on branch advance, fetch + fast-forward; **warn (never clobber)** if the
  worktree has local edits.
- **Cleanup:** removing a review runs `git worktree remove` + prune; the managed clone
  is kept for reuse.
- **Transactional:** build worktrees in a temp location, validate, then commit; clean up
  on failure so there are never half-made worktrees.

## The three panes

**🤖 Claude pane (`ClaudeSessionKit`)** — the hybrid, in two halves:

- *Interaction:* a `SwiftTerm` `NSView` runs a PTY with `claude` in the worktree using
  the configured launch args (`--dangerously-skip-permissions`, model, per-review
  flags). Spawned on first view of the tab, kept alive after; `--resume` rehydrates
  context across app restarts. One session per review.
- *Status:* a file-watcher tails the session transcript
  (`~/.claude/projects/<encoded-cwd>/*.jsonl`), parses events defensively, and emits a
  `ClaudeStatus` stream that drives sidebar badges and the "review ready" notification
  (fires on running→idle).
- *Honest constraints:* the transcript is a Claude Code **internal format**, making this
  the main coupling risk — it is isolated behind the `ClaudeStatus` interface and
  degrades to "no badge" if the format changes. Reliable LGTM/needs-work classification
  from prose is fuzzy, so the badge shows **objective facts** (✓ run finished, duration,
  last activity) and the last verdict line as a subtitle/tooltip — no sentiment
  detection is promised.

**± Diff pane (`DiffKit`)** — pure, testable core:

- `git diff <merge-base>...<head>` → parsed model (files → hunks → lines with old/new
  line numbers and origin).
- tree-sitter highlighting (SwiftTreeSitter) mapped onto diff lines, cached per file.
- Native rendering: file rail + unified/split toggle, collapsed unchanged regions, and
  **row virtualization** so multi-thousand-line diffs stay smooth.
- Clickable lines → (Phase 1) reveal/open the file in the worktree; (Phase 4) select
  range → compose → `GitHubKit` posts the review comment. The diff-line→GitHub-position
  mapping is the fiddly part of Phase 4.

**🌐 GitHub pane** — a `WKWebView` with a persistent data store (log in once, session
sticks), loading the PR URL, with reload and "open in real browser." Minimal logic.

All three bind to the **same selected review**; the segmented control only swaps which
view is visible.

## Error handling

Typed errors per module, rendered inline per-pane — never crash the app:

- **Missing/unauthed tools** (`gh`/`git`/`claude`) detected at launch → actionable banner
  ("run `gh auth login`"); manual Add still works from cache.
- **Worktree ops transactional** (see above); dirty/diverged → warn, never clobber.
- **Force-push/rebase** detected via head-SHA change on refresh → offers "update worktree."
- **Offline** → cached metadata + last diff; web view shows its own error.
- **No transcript yet** → status "not started," no badge, no error.
- **Big/binary diffs** → virtualized; binaries and huge files collapsed with "load anyway."

## Testing strategy

Most logic lives in the packages, so they carry the tests:

- `DiffKit` & URL/JSON parsing — pure functions, fixture-driven (strongest coverage).
- `ClaudeSessionKit` — fixture JSONL transcripts → assert `ClaudeStatus` transitions;
  file-watch tested with temp files.
- `WorktreeKit` — integration tests against throwaway temp git repos; pure path/base
  functions unit-tested.
- `GitHubKit` — injected command runner with canned `gh --json`.
- `ReviewStore` — Codable round-trip + atomic write + actor concurrency.
- UI stays thin → minimal snapshot tests; real `gh`/`git`/`claude` covered by a manual
  E2E checklist.

## Build phasing (full vision, delivered as vertical slices)

| Phase | Delivers | Usable at end? |
|------|----------|----------------|
| **1 · Core loop** | App shell, sidebar, segmented detail, `ReviewStore`, Add-by-URL, `WorktreeKit` (hybrid/lazy), Claude pane (SwiftTerm), GitHub pane, native Diff (view-only) | Add a PR → worktree → 3 working tabs |
| **2 · Intelligence** | `GitHubKit` discovery/polling + dedup (the merged queue), transcript tailing → sidebar badges + verdict snippet | Full sidebar + live status |
| **3 · Notifications & polish** | Review-ready notifications, worktree refresh on force-push, Settings UI, session resume | Hands-off awareness |
| **4 · Comments** | Clickable diff line → compose → post review comment via `gh`; diff-line→position mapping | Review without leaving the app |

Each phase is independently usable and can take its own plan → implementation cycle.

## Open questions / risks

- **Transcript format coupling** (Claude Code internal) — isolated in `ClaudeSessionKit`;
  needs a fixture-based regression suite and graceful degradation. Validate the
  `~/.claude/projects/<encoded-cwd>` mapping early.
- **Diff-line → GitHub review position mapping** (Phase 4) — GitHub's review API uses
  diff position/line+side; this is the known-fiddly part of comment posting.
- **WKWebView GitHub auth** — confirm a persistent data store gives a durable login
  without an in-app OAuth flow.
- **SwiftTerm session lifecycle** across many open reviews — confirm keeping N live PTYs
  is acceptable, else suspend/resume policy.

## Appendix — layout reference

Single window. Left sidebar: "Open Reviews" header with **＋ Add**, then rows showing
`#number · title`, `owner/repo · author`, and a status line/badge (e.g.,
"✓ reviewed · LGTM w/ 1 nit") for the selected/active review. Right panel: a segmented
control **🤖 Claude Review | 🌐 GitHub | ± Diff** with the worktree path shown at the
trailing edge; the content area below renders the active pane for the selected review.
