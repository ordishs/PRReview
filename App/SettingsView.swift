import SwiftUI
import AppCore
import PRReviewModels

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            DiscoverySettingsTab(model: model)
                .tabItem { Label("Discovery", systemImage: "magnifyingglass") }

            ToolsSettingsTab(model: model)
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }

            ClaudeSettingsTab(model: model)
                .tabItem { Label("Claude", systemImage: "terminal") }
        }
        .frame(width: 540, height: 360)
        .padding(20)
    }
}

private struct DiscoverySettingsTab: View {
    let model: AppModel

    @State private var queriesText: String = ""
    @State private var pollIntervalSeconds: Int = 120

    var body: some View {
        Form {
            Section("Search queries (one per line)") {
                TextEditor(text: $queriesText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
                    .border(Color.secondary.opacity(0.3))
                Text("Each line is a separate `gh search prs` query. Include `is:open` to filter out closed PRs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Poll interval") {
                Stepper(value: $pollIntervalSeconds, in: 30...3600, step: 30) {
                    Text("\(pollIntervalSeconds) seconds")
                }
            }

            Section("Sidebar grouping") {
                Picker("Group PRs by", selection: Binding(
                    get: { model.settings.sidebarGrouping },
                    set: { newValue in
                        var updated = model.settings
                        updated.sidebarGrouping = newValue
                        Task { await model.updateSettings(updated) }
                    }
                )) {
                    ForEach(SidebarGrouping.allCases, id: \.self) { grouping in
                        Text(grouping.displayName).tag(grouping)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            queriesText = model.settings.discoveryQueries.joined(separator: "\n")
            pollIntervalSeconds = model.settings.pollIntervalSeconds
        }
        .onChange(of: queriesText) { _, newValue in commit() }
        .onChange(of: pollIntervalSeconds) { _, _ in commit() }
    }

    private func commit() {
        let lines = queriesText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var updated = model.settings
        updated.discoveryQueries = lines
        updated.pollIntervalSeconds = pollIntervalSeconds
        Task { await model.updateSettings(updated) }
    }
}

private struct ToolsSettingsTab: View {
    let model: AppModel

    @State private var ghPath: String = ""
    @State private var gitPath: String = ""
    @State private var claudePath: String = ""

    var body: some View {
        Form {
            Section("Tool paths") {
                pathRow(label: "gh", binding: $ghPath, placeholder: "/opt/homebrew/bin/gh")
                pathRow(label: "git", binding: $gitPath, placeholder: "/opt/homebrew/bin/git")
                pathRow(label: "claude", binding: $claudePath, placeholder: "/opt/homebrew/bin/claude")
                Text("Leave empty to auto-resolve from PATH.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            ghPath = model.settings.ghPath ?? ""
            gitPath = model.settings.gitPath ?? ""
            claudePath = model.settings.claudePath ?? ""
        }
        .onChange(of: ghPath) { _, _ in commit() }
        .onChange(of: gitPath) { _, _ in commit() }
        .onChange(of: claudePath) { _, _ in commit() }
    }

    @ViewBuilder
    private func pathRow(label: String, binding: Binding<String>, placeholder: String) -> some View {
        HStack {
            Text(label)
                .frame(width: 60, alignment: .trailing)
                .foregroundStyle(.secondary)
                .font(.system(.body, design: .monospaced))
            TextField(placeholder, text: binding)
                .textFieldStyle(.roundedBorder)
            Button("Choose…") {
                pickFile(into: binding)
            }
        }
    }

    private func pickFile(into binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
        }
    }

    private func commit() {
        var updated = model.settings
        updated.ghPath = ghPath.isEmpty ? nil : ghPath
        updated.gitPath = gitPath.isEmpty ? nil : gitPath
        updated.claudePath = claudePath.isEmpty ? nil : claudePath
        Task { await model.updateSettings(updated) }
    }
}

private struct ClaudeSettingsTab: View {
    let model: AppModel

    @State private var argsText: String = ""
    @State private var notificationsEnabled: Bool = true

    var body: some View {
        Form {
            Section("Launch arguments (one per line)") {
                TextEditor(text: $argsText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 100)
                    .border(Color.secondary.opacity(0.3))
                Text("Extra arguments prepended to the claude invocation. The app always appends --name, --effort max, --dangerously-skip-permissions, and the /review command.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle("Send notification when a review goes idle", isOn: $notificationsEnabled)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            argsText = model.settings.claudeLaunchArgs.joined(separator: "\n")
            notificationsEnabled = model.settings.notificationsEnabled
        }
        .onChange(of: argsText) { _, _ in commit() }
        .onChange(of: notificationsEnabled) { _, _ in commit() }
    }

    private func commit() {
        let lines = argsText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var updated = model.settings
        updated.claudeLaunchArgs = lines
        updated.notificationsEnabled = notificationsEnabled
        Task { await model.updateSettings(updated) }
    }
}
