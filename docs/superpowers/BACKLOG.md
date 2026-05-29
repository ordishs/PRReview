# Backlog

Items captured for later planning. Status tracked below.

## Shipped

- [x] **Disable a PR without deleting it.** Context-menu Disable/Enable toggle. Disabled PRs are skipped by prefetch and rendered at 0.45 opacity. (`db5245e`)
- [x] **Date labels in PR nav.** Sidebar group-by-date uses Today / Yesterday / This Week / Last Week / Older buckets. (`8c21052`)
- [x] **Group PRs by date, author, or status.** Sidebar grouping mode in Settings, persists across launches. (`8c21052`)
- [x] **WebView retention when hidden.** WKWebViews are cached per-review in `WebViewCache` and reparented on tab switch; scroll, form, and load state survive switches. (`6047187`)
- [x] **Skip auto-review when a PR has already been reviewed.** If a transcript exists for the worktree's encoded cwd, launch with `--continue`; otherwise launch with `/review <URL>`. Re-checks at session creation, so new commits with a fresh worktree get a new review. (`60243e1`)
- [x] **Homebrew formula.** Cask template committed at `Casks/prreview.rb` (placeholder URL/SHA256, populated at first signed release). (`3405ae5`)

## Deferred — flagged as too aggressive in earlier review

- [ ] **Pre-warm GitHub pages on launch.** Background-load each PR's GitHub web view so switching feels instant. Skip disabled PRs.
- [ ] **Pre-warm diffs on launch.** For each PR with a local worktree, read the diff into the cache in the background. Skip disabled PRs.

Both items eagerly use network and disk for every PR in the sidebar on every launch. Current behaviour is to warm on selection, which is fast enough in practice and respects the user's intent.

## Default macOS behaviour — no work needed

- [x] **Single-instance enforcement.** `open /path/to/PRReview.app` reactivates the running instance by bundle ID (`com.ordishs.PRReview`) — this is the default macOS launcher behaviour. The rebuild loop uses `open -n` explicitly to force a fresh instance during development. No code required.

## Open — not yet shipped

- [ ] **Persist Claude session ID per PR for `claude --resume <id>`.** Today the resume path uses `--continue`, which picks up the most recent transcript in the encoded-cwd directory. `--resume <id>` would be more explicit and survive multiple parallel sessions or non-default transcript locations. Already partly anticipated in `specs/2026-05-28-claude-pane-design.md`.
