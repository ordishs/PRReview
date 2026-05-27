# PR Review — Phase 1, Plan 6 (thin slice): App integration — Add flow

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the app usable — add a PR by URL, see it appear in the sidebar, select it, and view it in an embedded GitHub web pane. The Diff and Claude panes are placeholders for now.

**Architecture:** The add-flow logic lives in a new `AppCore` package module as an `@MainActor @Observable AppModel` (parse URL → `GitHubClient.fetchReview` → `ReviewStore.upsert` → refresh list), unit-tested with a stub runner and a temp store. The `App` target holds thin SwiftUI views observing `AppModel`: a sidebar `List`, an Add sheet, and a segmented detail with a `WKWebView` GitHub pane plus placeholder Diff/Claude panes. A `ToolResolver` (in `CommandSupport`) finds the `gh` binary.

**Tech Stack:** Swift 6, SwiftUI, Observation, WebKit (`WKWebView`), XcodeGen, the existing `Core` packages.

**Companion spec:** `docs/superpowers/specs/2026-05-27-pr-review-app-design.md`.

**Plan sequence (Phase 1):** 1-scaffold ✅ · 2-reviewstore ✅ · 3-githubkit ✅ · 4-worktreekit ✅ · **6-app-integration (thin, this)** · then 5-diffkit + worktree/Claude wiring to fill the placeholders.

---

## Scope notes

- **Deliberately thin.** Delivers: Add-by-URL → sidebar → select → GitHub web pane. **Defers:** local worktree checkout, the native Diff pane (needs `DiffKit`/Plan 5), and the Claude terminal pane (needs SwiftTerm wiring). Those fill the placeholders in later slices.
- **No worktree creation in this slice.** The GitHub pane only needs the PR URL, so we avoid the `git clone` credential dependency for now. Worktree wiring arrives with the Diff/Claude panes that actually need local code.
- **Verification is split:** `AppCore` logic is unit-tested via `swift test`; the SwiftUI app is verified by building, launching, and **adding a real PR by hand** (E2E checklist at the end).
- **First plan to touch `project.yml` and `App/`.**

---

## Task 1: `AppCore` module (`AppModel`) + `ToolResolver`

**Files:**
- Create: `Core/Sources/CommandSupport/ToolResolver.swift`
- Create: `Core/Tests/CommandSupportTests/ToolResolverTests.swift`
- Create: `Core/Sources/AppCore/AppModel.swift`
- Create: `Core/Sources/AppCore/AppModelFactory.swift`
- Create: `Core/Tests/AppCoreTests/AppModelTests.swift`
- Modify: `Core/Package.swift`

- [ ] **Step 1: Write the failing tests**

Create `Core/Tests/CommandSupportTests/ToolResolverTests.swift`:

```swift
import Testing
import CommandSupport

@Test func toolResolverReturnsFirstExistingCandidate() {
    let resolved = ToolResolver.resolve("x", candidates: ["/nonexistent/x", "/bin/echo"])
    #expect(resolved == "/bin/echo")
}

@Test func toolResolverReturnsNilWhenNoneExist() {
    #expect(ToolResolver.resolve("x", candidates: ["/nope/a", "/nope/b"]) == nil)
}
```

Create `Core/Tests/AppCoreTests/AppModelTests.swift`:

```swift
import Testing
import Foundation
import PRReviewModels
import GitHubKit
import CommandSupport
import ReviewStore
@testable import AppCore

private actor StubRunner: CommandRunner {
    let result: CommandResult
    init(result: CommandResult) { self.result = result }
    func run(executable: String, arguments: [String]) async throws -> CommandResult { result }
}

private func tempStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("appcore-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("store.json")
}

private let prJSON = """
{
  "number": 944,
  "title": "centrifuge fix",
  "url": "https://github.com/bsv-blockchain/teranode/pull/944",
  "state": "OPEN",
  "isDraft": false,
  "author": { "login": "icellan" },
  "headRefName": "fix/centrifuge",
  "baseRefName": "main"
}
"""

@Test @MainActor func addPRFetchesStoresAndSelects() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let client = GitHubClient(runner: StubRunner(result: CommandResult(exitCode: 0, standardOutput: prJSON, standardError: "")), ghPath: "gh")
    let model = AppModel(store: store, client: client)

    await model.addPR(urlString: "https://github.com/bsv-blockchain/teranode/pull/944")

    #expect(model.reviews.count == 1)
    #expect(model.reviews.first?.id == "bsv-blockchain/teranode#944")
    #expect(model.selection == "bsv-blockchain/teranode#944")
    #expect(model.errorMessage == nil)
}

@Test @MainActor func addPRSetsErrorOnInvalidURL() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let client = GitHubClient(runner: StubRunner(result: CommandResult(exitCode: 0, standardOutput: "", standardError: "")), ghPath: "gh")
    let model = AppModel(store: store, client: client)

    await model.addPR(urlString: "not a pr url")

    #expect(model.reviews.isEmpty)
    #expect(model.errorMessage != nil)
}

@Test @MainActor func loadReadsExistingReviews() async throws {
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    try await seedStore.upsert(Review(
        owner: "bsv-blockchain", repo: "teranode", number: 901,
        url: URL(string: "https://github.com/bsv-blockchain/teranode/pull/901")!,
        title: "prune", author: "jad", headBranch: "prune", baseBranch: "main",
        origin: .added, prState: .open, addedAt: Date(timeIntervalSince1970: 1_700_000_000)
    ))
    let client = GitHubClient(runner: StubRunner(result: CommandResult(exitCode: 0, standardOutput: "", standardError: "")), ghPath: "gh")
    let model = AppModel(store: try ReviewStore(fileURL: url), client: client)

    await model.load()

    #expect(model.reviews.count == 1)
    #expect(model.reviews.first?.number == 901)
}
```

- [ ] **Step 2: Add the targets to the manifest**

Replace the ENTIRE contents of `Core/Package.swift` with:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PRReviewCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PRReviewModels", targets: ["PRReviewModels"]),
        .library(name: "CommandSupport", targets: ["CommandSupport"]),
        .library(name: "ReviewStore", targets: ["ReviewStore"]),
        .library(name: "GitHubKit", targets: ["GitHubKit"]),
        .library(name: "WorktreeKit", targets: ["WorktreeKit"]),
        .library(name: "DiffKit", targets: ["DiffKit"]),
        .library(name: "ClaudeSessionKit", targets: ["ClaudeSessionKit"]),
        .library(name: "AppCore", targets: ["AppCore"]),
    ],
    targets: [
        .target(name: "PRReviewModels"),
        .target(name: "CommandSupport"),
        .target(name: "ReviewStore", dependencies: ["PRReviewModels"]),
        .target(name: "GitHubKit", dependencies: ["PRReviewModels", "CommandSupport"]),
        .target(name: "WorktreeKit", dependencies: ["CommandSupport"]),
        .target(name: "DiffKit", dependencies: ["PRReviewModels"]),
        .target(name: "ClaudeSessionKit", dependencies: ["PRReviewModels"]),
        .target(name: "AppCore", dependencies: ["PRReviewModels", "ReviewStore", "GitHubKit", "CommandSupport"]),
        .testTarget(name: "PRReviewModelsTests", dependencies: ["PRReviewModels"]),
        .testTarget(name: "ReviewStoreTests", dependencies: ["ReviewStore", "PRReviewModels"]),
        .testTarget(name: "GitHubKitTests", dependencies: ["GitHubKit", "PRReviewModels", "CommandSupport"]),
        .testTarget(name: "CommandSupportTests", dependencies: ["CommandSupport"]),
        .testTarget(name: "WorktreeKitTests", dependencies: ["WorktreeKit", "CommandSupport"]),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore", "PRReviewModels", "ReviewStore", "GitHubKit", "CommandSupport"]),
    ]
)
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --package-path Core`
Expected: FAILS to compile — `cannot find 'ToolResolver' in scope` and `cannot find 'AppModel' in scope`.

- [ ] **Step 4: Implement `ToolResolver`**

Create `Core/Sources/CommandSupport/ToolResolver.swift`:

```swift
import Foundation

public enum ToolResolver {
    public static func resolve(_ name: String, candidates: [String]? = nil, fileManager: FileManager = .default) -> String? {
        let paths = candidates ?? ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        return paths.first { fileManager.isExecutableFile(atPath: $0) }
    }
}
```

- [ ] **Step 5: Implement `AppModel`**

Create `Core/Sources/AppCore/AppModel.swift`:

```swift
import Foundation
import Observation
import PRReviewModels
import ReviewStore
import GitHubKit

@MainActor
@Observable
public final class AppModel {
    public private(set) var reviews: [Review] = []
    public var selection: String?
    public private(set) var errorMessage: String?
    public private(set) var isAdding = false

    private let store: ReviewStore
    private let client: GitHubClient

    public init(store: ReviewStore, client: GitHubClient) {
        self.store = store
        self.client = client
    }

    public func load() async {
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
        } catch {
            errorMessage = String(describing: error)
        }
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

- [ ] **Step 6: Implement the production factory**

Create `Core/Sources/AppCore/AppModelFactory.swift`:

```swift
import Foundation
import PRReviewModels
import ReviewStore
import GitHubKit
import CommandSupport

public enum AppModelFactory {
    @MainActor
    public static func makeDefault() throws -> AppModel {
        let settings = Settings.default
        let storeURL = URL(fileURLWithPath: settings.managedRoot).appendingPathComponent("store.json")
        let store = try ReviewStore(fileURL: storeURL)
        let ghPath = settings.ghPath ?? ToolResolver.resolve("gh") ?? "/opt/homebrew/bin/gh"
        let client = GitHubClient(runner: ProcessCommandRunner(), ghPath: ghPath)
        return AppModel(store: store, client: client)
    }
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test --package-path Core`
Expected: PASS — 36 tests total (31 prior + 2 `ToolResolver` + 3 `AppModel`), 0 failures.

- [ ] **Step 8: Commit**

```bash
git add Core
git commit -m "feat: add AppCore AppModel add-flow and ToolResolver"
```

---

## Task 2: Wire the SwiftUI app

**Files:**
- Modify: `project.yml` (app depends on `AppCore` + `PRReviewModels`)
- Modify: `App/PRReviewApp.swift`
- Modify: `App/ContentView.swift`
- Create: `App/AddPRSheet.swift`
- Create: `App/DetailView.swift`
- Create: `App/WebPane.swift`

- [ ] **Step 1: Point the app target at the package products**

Replace the ENTIRE contents of `project.yml` with:

```yaml
name: PRReview
options:
  bundleIdPrefix: com.ordishs
  deploymentTarget:
    macOS: "14.0"
  createIntermediateGroups: true
packages:
  PRReviewCore:
    path: Core
targets:
  PRReview:
    type: application
    platform: macOS
    sources:
      - App
    dependencies:
      - package: PRReviewCore
        product: PRReviewModels
      - package: PRReviewCore
        product: AppCore
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.ordishs.PRReview
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
        GENERATE_INFOPLIST_FILE: YES
        SWIFT_VERSION: "6.0"
        CODE_SIGNING_REQUIRED: NO
        CODE_SIGNING_ALLOWED: NO
schemes:
  PRReview:
    build:
      targets:
        PRReview: all
    run:
      config: Debug
```

- [ ] **Step 2: Rewrite the app entry point**

Replace the ENTIRE contents of `App/PRReviewApp.swift` with:

```swift
import SwiftUI
import AppCore

@main
struct PRReviewApp: App {
    @State private var model: AppModel?
    @State private var startupError: String?

    var body: some Scene {
        WindowGroup {
            Group {
                if let model {
                    ContentView(model: model)
                } else if let startupError {
                    Text(startupError)
                        .foregroundStyle(.red)
                        .padding()
                        .frame(minWidth: 900, minHeight: 600)
                } else {
                    ProgressView().frame(minWidth: 900, minHeight: 600)
                }
            }
            .task {
                guard model == nil, startupError == nil else { return }
                do {
                    let created = try AppModelFactory.makeDefault()
                    await created.load()
                    model = created
                } catch {
                    startupError = "Failed to start: \(error)"
                }
            }
        }
    }
}
```

- [ ] **Step 3: Rewrite `ContentView`**

Replace the ENTIRE contents of `App/ContentView.swift` with:

```swift
import SwiftUI
import PRReviewModels
import AppCore

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var showingAdd = false

    var body: some View {
        NavigationSplitView {
            List(model.reviews, selection: $model.selection) { review in
                VStack(alignment: .leading, spacing: 2) {
                    Text("#\(review.number) · \(review.title)")
                        .lineLimit(1)
                    Text("\(review.owner)/\(review.repo) · \(review.author)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                DetailView(review: review)
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
    }
}
```

- [ ] **Step 4: Create the Add sheet**

Create `App/AddPRSheet.swift`:

```swift
import SwiftUI
import AppCore

struct AddPRSheet: View {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool
    @State private var urlString = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a pull request")
                .font(.headline)
            TextField("https://github.com/owner/repo/pull/123", text: $urlString)
                .textFieldStyle(.roundedBorder)
                .frame(width: 440)
            HStack {
                if model.isAdding {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Add") {
                    Task {
                        await model.addPR(urlString: urlString)
                        if model.errorMessage == nil {
                            isPresented = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(urlString.isEmpty || model.isAdding)
            }
        }
        .padding(20)
    }
}
```

- [ ] **Step 5: Create the detail view**

Create `App/DetailView.swift`:

```swift
import SwiftUI
import PRReviewModels

struct DetailView: View {
    let review: Review
    @State private var pane: Pane = .github

    enum Pane: String, CaseIterable, Identifiable {
        case claude = "Claude Review"
        case github = "GitHub"
        case diff = "Diff"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $pane) {
                ForEach(Pane.allCases) { pane in
                    Text(pane.rawValue).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            switch pane {
            case .github:
                WebPane(url: review.url)
            case .diff:
                placeholder(title: "Diff viewer", subtitle: "Native diff lands with DiffKit.")
            case .claude:
                placeholder(title: "Claude review", subtitle: "The embedded terminal lands with the Claude pane.")
            }
        }
        .navigationTitle("#\(review.number) \(review.title)")
    }

    private func placeholder(title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.title3)
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 6: Create the WebKit pane**

Create `App/WebPane.swift`:

```swift
import SwiftUI
import WebKit

struct WebPane: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }
}
```

- [ ] **Step 7: Generate, build, and launch**

```bash
xcodegen generate
xcodebuild -project PRReview.xcodeproj -scheme PRReview -configuration Debug -destination 'platform=macOS' -derivedDataPath DerivedData build CODE_SIGNING_ALLOWED=NO
open DerivedData/Build/Products/Debug/PRReview.app
```

Expected: `** BUILD SUCCEEDED **`, then the app launches with an empty "Reviews" sidebar and a ＋ toolbar button.

- [ ] **Step 8: Manual E2E — add a real PR**

With the app open:
1. Click the **＋** button. A sheet appears with a URL field.
2. Paste a real PR URL you have `gh` access to (e.g. a public PR like `https://github.com/cli/cli/pull/1`), click **Add**.
3. Expected: the sheet closes, a row appears in the sidebar (`#1 · <title>` / `owner/repo · author`), and it becomes selected.
4. The detail shows the **GitHub** segment selected with the PR page loaded in the web view. Switch to **Diff**/**Claude** to see the placeholders.
5. Quit (⌘Q), relaunch, and confirm the PR is still listed (persistence).

If the GitHub web view shows a login page (private repo), log in once — the persistent data store keeps you signed in.

If "Add" shows an error alert, read it: a bad URL is rejected by `PRRef.parse`; a `gh` failure (auth/not-found) surfaces as `commandFailed` with stderr.

- [ ] **Step 9: Commit**

```bash
git add project.yml App
git commit -m "feat: wire Add-by-URL flow, sidebar, and GitHub pane into the app"
```

---

## Self-review (this plan vs. the slice's intent)

- **Coverage:** delivers the user-facing "add a PR and see it" loop — `AppModel.addPR` (parse → fetch → persist → select), a sidebar bound to the store, an Add sheet, and a segmented detail whose GitHub pane renders the PR. The deferred panes are explicit placeholders, and worktree checkout is consciously out of this slice (the GitHub pane needs only the URL).
- **Placeholder scan:** the only "placeholders" are intentional UI panes with explicit copy; all code and commands are complete. `AppModel` logic is genuinely unit-tested (add success, invalid-URL error, load) with a stub runner + temp store; the SwiftUI layer is verified by the manual E2E checklist, which is the right tool for GUI wiring.
- **Type consistency:** views use `AppModel`'s API (`reviews`, `selection`, `selectedReview()`, `addPR(urlString:)`, `isAdding`, `errorMessage`, `dismissError()`); `List(_:selection:)` binds `String?` to `Review.id` (Review is `Identifiable`); `AppModelFactory.makeDefault()` uses `Settings.default`, `ReviewStore(fileURL:)`, `ToolResolver.resolve`, `GitHubClient(runner:ghPath:)`, `ProcessCommandRunner()` — all matching their definitions. `project.yml` adds the `AppCore` + `PRReviewModels` products the app imports.

## Definition of done

- `swift test --package-path Core` → 36 tests passing, 0 failures.
- App builds, launches, and adding a real PR populates the sidebar; selecting it shows the PR in the GitHub web pane; the entry persists across relaunch.
- Two commits; working tree clean.
- Known follow-ups (next slices): local worktree checkout, the native Diff pane (`DiffKit`/Plan 5), the Claude terminal pane, gh-discovery polling, and status badges.
