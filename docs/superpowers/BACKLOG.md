# Backlog

All planned items are shipped. New ideas go here as they come up.

## Shipped

- [x] **Disable a PR without deleting it.** Context-menu Disable/Enable toggle. Disabled PRs are skipped by prefetch and rendered at 0.45 opacity. (`db5245e`)
- [x] **Date labels in PR nav.** Sidebar group-by-date uses Today / Yesterday / This Week / Last Week / Older buckets; per-row caption shows the same label. Default grouping is now `byDate` and the sidebar toolbar carries a grouping menu. (`8c21052`, `779afa6`)
- [x] **Group PRs by date, author, or status.** Toolbar menu + Settings panel. (`8c21052`, `779afa6`)
- [x] **WebView retention when hidden.** WKWebViews are cached per-review in `WebViewCache` and reparented on tab switch. (`6047187`)
- [x] **Skip auto-review when a PR has already been reviewed.** Resume the prior session by explicit ID (`claude --resume <uuid>`) when a transcript exists. (`60243e1`, `58d20a0`)
- [x] **Persist Claude session ID per PR for `claude --resume <id>`.** Resume now uses the explicit transcript filename as the session ID. (`58d20a0`)
- [x] **Pre-warm GitHub pages on launch.** `WebViewCache.ensure(for:)` is invoked for every non-disabled review at app start. (`41b9f29`)
- [x] **Pre-warm diffs on launch.** `AppModel.prewarmDiffs()` runs background diff loads for every non-disabled review at app start. (`41b9f29`)
- [x] **Homebrew formula.** Cask template committed at `Casks/prreview.rb` (placeholder URL/SHA256, populated at first signed release). (`3405ae5`)
- [x] **Single-instance enforcement.** Default macOS launcher behaviour — `open /path/to/PRReview.app` reactivates the running instance by bundle ID. The dev rebuild loop uses `open -n` explicitly to force a fresh instance. No code required.
