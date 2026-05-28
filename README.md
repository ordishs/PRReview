# PR Review

A native macOS app for reviewing GitHub pull requests. One window, a sidebar of
in-progress PRs, and a detail panel that flips between an embedded Claude Code
terminal, a native local diff, and the GitHub PR web view.

Replaces the manual iTerm-plus-browser workflow with a single tool: PRs are
auto-discovered (or added by URL), worktrees are created lazily on first open,
and `claude` runs inside the worktree without leaving the app.

## Status

Greenfield. Phase 1 is largely complete — scaffold, review store, GitHub/git
integration, native diff pane, registered local clones, management UX, and the
SwiftTerm-backed Claude pane are all wired up. Outstanding work includes diff UX
polish (file tree, unified/split toggle, hunk headers) and transcript-tailing
status badges.

## The three panes

- **Claude** — `SwiftTerm` `NSView` running the `claude` CLI in a PTY rooted at
  the PR's worktree. One session per review, kept alive after first view,
  rehydrated with `--resume` across launches.
- **Diff** — `git diff <merge-base>...<head>` parsed natively and rendered
  inline. No round trip to github.com.
- **GitHub** — a `WKWebView` on the PR page with a persistent data store so the
  session sticks.

All three bind to the same selected review; the segmented control only swaps
which view is visible.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 26 / Swift 6
- [`gh`](https://cli.github.com), `git`, and [`claude`](https://claude.com/claude-code)
  on `PATH`, with `gh auth login` already completed
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) —
  only needed to regenerate the project file

## Build

```sh
# Generate the Xcode project (gitignored, regenerate any time project.yml changes)
xcodegen generate

# Build and run from Xcode
open PRReview.xcodeproj

# Or build from the command line
xcodebuild -project PRReview.xcodeproj -scheme PRReview -configuration Debug \
  -derivedDataPath DerivedData build

# Launch the built app (use -n to force a fresh instance)
open -n DerivedData/Build/Products/Debug/PRReview.app
```

## Tests

The headless logic lives in the Swift package under `Core/` and carries the
tests:

```sh
cd Core
swift test
```

## Project layout

```
App/                       SwiftUI views and app shell
Core/                      Swift package — headless, unit-testable logic
  Sources/
    PRReviewModels/        Value types shared across modules
    CommandSupport/        Injectable command-runner abstraction
    ReviewStore/           Actor-backed durable state (JSON on disk)
    GitHubKit/             Wraps `gh` (discovery, add-by-URL, metadata)
    WorktreeKit/           Wraps `git` (clone resolution, worktrees)
    DiffKit/               Parses `git diff` into a renderable model
    ClaudeSessionKit/      SwiftTerm-backed PTY session for `claude`
    AppCore/               View-model layer composing the modules
docs/                      Design specs and per-phase implementation plans
project.yml                XcodeGen input that generates PRReview.xcodeproj
```

## Design

The full design spec, decision log, and per-phase plans live under
`docs/superpowers/`. Start with
`docs/superpowers/specs/2026-05-27-pr-review-app-design.md`.

## License

MIT — see [LICENSE](LICENSE).
