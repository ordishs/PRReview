# Management UX — Design Spec

- **Date:** 2026-05-28
- **Status:** Approved (brainstorm) — ready for implementation planning
- **Builds on:** `docs/superpowers/specs/2026-05-28-diff-pane-enhancements-design.md`

## Summary

Three coordinated UX changes prompted by hands-on use of Plan 8:

1. **Move local-clone registration out of the Diff toolbar.** Registration is per-repo (project-scoped), not per-PR; it shouldn't live on a PR-specific surface.
2. **Add a "Manage Local Clones" sheet** reachable from a macOS menu, supporting both adding and removing repo→folder mappings, and auto-detecting *all* GitHub remotes in a picked clone (so a fork-with-upstream layout registers both repos in one click).
3. **Add a "Remove PR" action** in the sidebar (right-click + `⌫` keyboard shortcut), with best-effort worktree cleanup.

## Decisions (recorded from the brainstorm)

| # | Decision |
|---|----------|
| A | When the user picks a folder via "Manage Local Clones…", auto-detect *all* GitHub remotes (`git remote -v`) and register one `RegisteredRepo` per detected `owner/repo`, all pointing at the same path. |
| B | "Remove PR" performs **best-effort worktree cleanup** (`FileManager.default.removeItem(atPath:)` on `review.worktreePath` inside a `try?`) before removing the review from the store. Failure is non-fatal; the store removal proceeds. |
| C | macOS menu = top-level **`Repositories`** with one item **`Manage Local Clones…`** (`⌘⇧L`). |
| D | The Diff toolbar shows the `📁 local: <path>` badge **when registered**, and **nothing** when not. The "Use local clone…" button is removed. |

## Architecture

### `AppCore`

- **`CloneRegistering` protocol** gains a second method:
  ```swift
  func detectRepositories(at localPath: String) async throws -> [String]
  ```
  Returns the list of `"owner/repo"` strings derived from every `github.com` remote in the clone (via `git -C <path> remote -v` + `GitOriginParser`). Empty array means "no GitHub remotes." Throws `RegistrationError.notAGitRepository` if `git` exits non-zero (same shape as `validate`).
- **`GitCloneRegistrar`** implements `detectRepositories` by sharing the same parse loop as `validate`.
- **`AppModel`** gains three methods, no new init parameters:
  - `registerLocalClone(at localPath: String) async` — calls `detectRepositories`; if empty, sets `errorMessage = "No GitHub repositories found in <path>"`; otherwise upserts one `RegisteredRepo` per identity (`remoteIdentity = "github.com/<owner>/<repo>"`, `localClonePath = localPath`, `defaultBase = "main"`) and refreshes `registeredRepos`.
  - `removeRegisteredRepo(remoteIdentity: String) async` — `store.removeRepo(id:)` + refresh.
  - `removeReview(id: String) async` — looks up the review, performs `try? FileManager.default.removeItem(atPath: review.worktreePath)` if a worktree path exists on disk, then `store.removeReview(id:)`; clears `selection` if it matched; refreshes `reviews`. Errors from `removeReview` (not the file removal) populate `errorMessage`.

### `App`

- **`DiffToolbarView`** is simplified: keep the `Label("local: …", systemImage: "folder.fill")` badge branch; remove the `Button("Use local clone…")` branch and its `fileImporter`. **When no clone is registered, the entire toolbar (and its `Divider`) is hidden** — `DiffPaneView` conditionally renders `DiffToolbarView` + `Divider` only when `model.registeredClonePath(for: review) != nil`, so the Diff body starts flush against the segmented control when there's nothing to show.
- **`PRReviewApp`** adds a `.commands { CommandMenu("Repositories") { Button("Manage Local Clones…", action: { showingManage = true }).keyboardShortcut("L", modifiers: [.command, .shift]) } }` block at the `Scene` level, bound to an `@State var showingManage: Bool` flag. The `WindowGroup`'s root view presents the `ManageLocalClonesView` via `.sheet(isPresented: $showingManage)`. The menu item is disabled while `model == nil` (during startup).
- **`ManageLocalClonesView`** (new file `App/ManageLocalClonesView.swift`): a list of `model.registeredRepos` (showing `remoteIdentity` and `localClonePath`), with an **Add…** button (opens a folder `fileImporter` → calls `model.registerLocalClone(at:)`), a per-row **Remove** trash button (calls `model.removeRegisteredRepo(remoteIdentity:)`), and a **Done** button to dismiss. Empty-state copy: "No local clones registered. Click Add… to choose a folder."
- **`ContentView`'s sidebar `List`** gains two affordances on each row:
  - `.contextMenu { Button(role: .destructive) { Task { await model.removeReview(id: review.id) } } label: { Label("Remove from List", systemImage: "trash") } }`
  - `.onDeleteCommand { if let id = model.selection { Task { await model.removeReview(id: id) } } }` attached to the `List` (so `⌫` removes the selected review).

## Error handling and edge cases

- **Removing a review whose worktree path is missing on disk:** `FileManager.fileExists` guards before the call; the store removal proceeds regardless.
- **Removing the selected review:** `selection` is set to `nil`; the detail pane reverts to "Select a review".
- **Adding a folder that's not a git repo / has no GitHub remotes:** `errorMessage` populated; the existing alert UI surfaces it.
- **Add… after the same path is already registered for one of its repos:** `ReviewStore.upsert` for `RegisteredRepo` is keyed on `remoteIdentity`, so re-adding silently updates (last write wins). Acceptable.
- **Removing a `RegisteredRepo` does not delete the folder on disk.** This is a pointer mapping only.
- **`removeReview` does NOT remove the managed clone** at `managedRoot/repos/<owner>/<repo>` — other PRs from the same repo might still need it. Only the per-PR worktree dir is touched.

## Testing

- `GitCloneRegistrarTests.detectRepositoriesReturnsAllGitHubRemotes` — stub `remote -v` output with fork + upstream → returns `["ordishs/teranode", "bsv-blockchain/teranode"]`.
- `GitCloneRegistrarTests.detectRepositoriesReturnsEmptyWhenNoGitHubRemotes` — stub returns only non-github remotes → empty list.
- `GitCloneRegistrarTests.detectRepositoriesThrowsWhenNotAGitRepository` — stub exit 128 → throws.
- `AppModelTests.registerLocalCloneRegistersAllDetected` — stub registrar returns 2 identities → `model.registeredRepos` has 2 entries, both pointing at the same path; `errorMessage == nil`.
- `AppModelTests.registerLocalCloneSetsErrorWhenNoReposFound` — stub returns empty → `errorMessage` set, `registeredRepos` empty.
- `AppModelTests.removeRegisteredRepoDeletes` — seed a repo, call remove → `registeredRepos` empty, store also empty.
- `AppModelTests.removeReviewRemovesFromStoreAndClearsSelection` — seed a review, select it, call remove → store empty, `selection == nil`.
- `AppModelTests.removeReviewBestEffortRemovesWorktreeDir` — create a real temp dir, set it as `review.worktreePath`, call remove → temp dir is gone; the store-removal happens regardless of the file operation.
- The existing `StubRegistrar` gains a `detectedRepositories: [String] = []` field (default empty) and a `detectRepositories(at:)` implementation that returns it.
- All seven prior `AppModel(...)` constructions in `AppModelTests` continue to work unchanged (no new init parameter).
- Manual E2E: open Repositories ▸ Manage Local Clones…, click Add…, pick the teranode workspace, see both `ordishs/teranode` and `bsv-blockchain/teranode` appear; both teranode PRs now show the badge automatically. Remove a repo → badge disappears for affected PRs. Sidebar right-click on a PR → Remove from List → PR disappears, worktree dir is cleaned up.

## Plan sequencing

This work has nothing to do with the deferred Plan 9 (file tree + split-view diff UX); it can ship before, after, or alongside Plan 9. Recommend **this plan next** — it removes a real UX wart you hit immediately, and it's a single self-contained plan.

## Definition of done

- The "Use local clone…" button no longer appears in any Diff tab; the `📁 local: <path>` badge still appears when a clone is registered for the PR's repo.
- The macOS menu bar has a **Repositories ▸ Manage Local Clones…** item that opens a sheet listing the registered repos with Add… and per-row Remove buttons.
- Adding a folder that contains a fork + upstream registers *both* repos against that path automatically.
- Right-clicking a PR in the sidebar (or pressing `⌫` with one selected) removes it from the list and best-effort removes its worktree directory.
- `swift test --package-path Core` passes; new tests cover detection, both register flows, both remove flows, and worktree cleanup.
- One implementation plan; no `RegisteredRepo` schema change; no `AppModel` init signature change.
