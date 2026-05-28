# Diff Pane Enhancements — Design Spec

- **Date:** 2026-05-28
- **Status:** Approved (brainstorm) — ready for implementation planning
- **Builds on:** `docs/superpowers/specs/2026-05-27-pr-review-app-design.md`

## Summary

Three user-requested enhancements to the running Diff pane, observed after first hands-on use:

1. **Unified and Split diff modes**, toggled by the user.
2. **A changed-files tree** alongside the diff, so a multi-file PR is navigable as it is on GitHub's "Files changed" page.
3. **Tying a PR's repo to a local git clone** so the app makes worktrees off the user's existing checkout rather than cloning the whole repo again.

Target: GitHub's "Files changed" layout, **rendered natively from local git** for native speed and offline capability.

## Decomposition

The work splits cleanly along "speed" and "UX," yielding two implementation plans:

- **Plan 8 — Registered local clone** (small, ships fast; mostly wiring).
- **Plan 9 — Native diff UX upgrade** (the visible GitHub-style layout: tree + split + hunk/file headers).

Recommended order: **Plan 8 first**, then Plan 9. Plan 8 is self-contained and immediately removes the "slow clone of an already-local repo" pain on every new add; Plan 9 then replaces the current placeholder-shaped Diff view with the GitHub-like layout.

## Key decisions

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| 1 | Diff layout | GitHub "Files changed": file tree on the left, diff content on the right, per-file collapsible sections, `@@` hunk header rows | The user's explicit reference |
| 2 | Unified vs Split | Both, toggleable; toggle persists in `Settings.diffMode` (the field already exists) | Already modeled |
| 3 | File tree contents | Changed files only, organised as a directory tree with status glyphs; click → scroll diff to that file | Matches reference; deferring full-repo browse |
| 4 | Repo registration UX | **Folder picker on demand** — when a PR's repo has no registered clone, the Diff toolbar offers "Use local clone…" → `NSOpenPanel` → validate → persist `RegisteredRepo` | Explicit, per-repo, one-time |
| 5 | Local clone validation | Run `git -C <picked> remote get-url origin` and require it points at the PR's `owner/repo` on github.com (allow `.git` suffix / SSH form / https form) | Prevents pointing the wrong dir at a PR |
| 6 | Toggle persistence | The Unified/Split toggle writes to `Settings.diffMode` via `ReviewStore.updateSettings(_:)` | Single source of truth, already persisted |

## Plan 8 — Registered local clone

### What changes

- **`WorktreeDiffLoader`** (in `AppCore`) gains a `ReviewStore` reference. In `loadDiff(for:)` it looks up `await store.repo(forRemote: "github.com/\(review.owner)/\(review.repo)")` and passes the resulting `localClonePath` (or `nil`) to `WorktreeManager.resolveClone(...)`. Today it unconditionally passes `nil`, which forces an auto-clone.
- **`AppModel`** gains:
  - `registeredClonePath(for review: Review) -> String?` (synchronous read of the persisted set, refreshed on `load()` alongside `reviews`).
  - `registerClone(for review: Review, localPath: String) async` — validates the path is a git repo whose `origin` matches the review's GitHub repo, then `store.upsert(RegisteredRepo(...))`; on validation failure sets `errorMessage`.
- **Clone validation** uses the existing `CommandRunner` to run `git -C <path> remote get-url origin`, parses the URL (matching `https://github.com/<owner>/<repo>(.git)?`, `git@github.com:<owner>/<repo>(.git)?`, or the bare form), and confirms `<owner>/<repo>` matches the review.

### UI

A small toolbar control inside the Diff pane:
- If a registered clone exists for the PR's repo → a static badge `📁 local: <tilde-shortened path>`.
- If not → a button `📁 Use local clone…` → `NSOpenPanel` (directories only) → on selection, call `model.registerClone(for: review, localPath: …)`; on success, the next `loadDiff` automatically uses it.

### Tests

- `registerCloneSucceedsWhenOriginMatches` — stubbed runner returns matching origin URL → `RegisteredRepo` persisted; `registeredClonePath(for:)` returns it.
- `registerCloneRejectsMismatchedOrigin` — stubbed runner returns a different owner/repo → not persisted; `errorMessage` set.
- `registerCloneAcceptsSshAndHttpsAndDotGitForms` — three URL shapes for the same repo all validate.
- `WorktreeDiffLoader` uses the registered clone — a (compact) integration variant in `AppCoreTests`: a stubbed `DiffLoading`-adjacent assertion that the loader passes the registered path through.

### Non-goals (this plan)

- Editing/removing registered repos via UI (read-only display + add). A future settings screen handles that.
- Cross-fork PRs whose head is on a *different* repo than the registered base. Out of scope; worktrees still fetch `refs/pull/N/head` from origin.

## Plan 9 — Native diff UX upgrade

### What changes

- **`AppCore`** — a pure `FileTreeBuilder` that folds `[DiffFile]` into a `FileTreeNode` (folders + file leaves; each leaf carries `path`, `addedCount`, `removedCount`, and `changeKind`). Fixture-tested over the model.
- **`App/DiffPaneView.swift`** is restructured into:
  - **Toolbar:** Unified/Split toggle bound to `Settings.diffMode` via the model (small `AppModel.diffMode` getter + `setDiffMode(_:)` async setter calling `store.updateSettings(...)`), the `+N −M, K files` aggregate stats, and the `📁 local` badge / register button from Plan 8.
  - **Two-column body** in an `HSplitView` (or a fixed-rail `HStack`): a `FileTreeView` on the left and a scrolling `DiffContentView` on the right wired with `ScrollViewReader`. Clicking a tree leaf scrolls the diff to its `DiffFileSection` (anchored by file id).
- **`DiffFileSection`** — sticky per-file header (path + `+N`/`−M` counts; collapse chevron) followed by the file's hunks.
- **`HunkHeaderRow`** — the `@@ -a,b +c,d @@ …` row in a subtle blue band (fixes today's "hunks run together" gap).
- **`UnifiedRows`** / **`SplitRows`** — current unified rendering kept and improved; new split rendering as a 4-column grid (`oldNo`, `oldText`, `newNo`, `newText`) where context appears on both sides, removed on the left only, added on the right only.

### Tests

- `fileTreeBuilderGroupsByDirectory` — `[DiffFile]` with mixed paths → expected nested tree.
- `fileTreeBuilderAggregatesStatsAtFolders` — folder nodes carry sum of child `addedCount` / `removedCount`.
- `setDiffModePersists` — `AppModel.setDiffMode(.split)` writes to the store; reload returns `.split`.
- SwiftUI views are validated by the manual E2E (the GitHub-style layout renders for a real PR, both modes look right, the tree click scrolls).

### Non-goals (this plan)

- Tree-sitter **syntax highlighting** — deferred (the most involved piece; needs `SwiftTreeSitter` and language grammars).
- **Expand-context** (⤒/⤓) — needs either re-running `git diff` with a larger `-U` or reading the underlying files; deferred.
- **"Viewed" checkboxes** and **inline comments** — Phase 4 of the master spec.
- **Row virtualization for huge diffs** beyond the existing `LazyVStack` — deferred until a real perf problem.
- **Full-repo file browse** (vs. changed-files-only tree) — deferred.

## Cross-cutting

- **Concurrency:** all model methods stay on `@MainActor`; the store is an actor (so reads are `await`); the toggle setter writes through `store.updateSettings` then re-reads. No new actor boundaries.
- **Error handling:** clone validation failure → `errorMessage` alert (re-uses the existing add-PR error UI). `NSOpenPanel` cancel is a no-op.
- **Persistence:** registered repos and `diffMode` already live in `store.json`. No schema change.
- **Conventions:** no code comments, no AI attribution in commits, follow TDD where unit tests apply, manual E2E for SwiftUI rendering.

## Open considerations / risks

- **Owner/repo extraction from `origin`** — needs to handle https with/without `.git`, ssh (`git@github.com:owner/repo[.git]`), and uppercase host. A small dedicated parser with fixture tests handles it.
- **`HSplitView` vs fixed-width rail** — `HSplitView` gives the user a draggable divider (nicer); fixed-width is simpler. Plan 9 will pick whichever proves more stable in macOS 14+; either way both modes render the same content.
- **Stat re-aggregation cost** — `FileTreeBuilder` is `O(files × pathDepth)`, negligible at PR scale.

## Definition of done (across both plans)

- Adding a PR whose repo has a known local clone (via the "Use local clone…" picker) **does not trigger a fresh `git clone`**; worktrees are created off the registered path.
- The Diff tab renders GitHub-style: a changed-files tree, a Unified/Split toggle that persists across launches, per-file headers with stats, `@@` hunk headers, and dual-gutter side-by-side rows in Split.
- Clicking a file in the tree scrolls the diff to that file.
- All prior tests stay green; new tests cover the file-tree builder, the diff-mode persistence, and the clone validation/URL parsing.
