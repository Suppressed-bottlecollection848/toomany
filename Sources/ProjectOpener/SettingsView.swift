import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var store: ProjectStore
    @State private var rootsText = ""
    @State private var excludesText = ""
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Section("Scanning") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Scan roots (one folder per line)")
                        .font(.system(size: 12, weight: .medium))
                    TextEditor(text: $rootsText)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 70)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
                    Text("Projects with Claude Code or Codex sessions are discovered automatically, even outside these roots.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Stepper("Scan depth: \(store.settings.maxDepth)",
                        value: $store.settings.maxDepth, in: 1...6)
                TextField("Excluded folder names (comma-separated)", text: $excludesText)
                    .font(.system(size: 12))
            }

            Section("Apps") {
                Picker("Default editor", selection: $store.settings.defaultAppID) {
                    ForEach(store.installedApps.filter { !$0.isTerminal }) { app in
                        Text(app.name).tag(Optional(app.id))
                    }
                }
                Picker("Terminal", selection: $store.settings.terminalAppID) {
                    ForEach(store.installedApps.filter(\.isTerminal)) { app in
                        Text(app.name).tag(Optional(app.id))
                    }
                }
                Toggle("Open with last-used editor when known (Cursor / VS Code)",
                       isOn: $store.settings.smartEditor)
            }

            Section("Behavior") {
                Picker("Global hotkey", selection: $store.settings.hotkeyPreset) {
                    ForEach(HotKeyPreset.allCases) { preset in
                        Text(preset.label).tag(preset.rawValue)
                    }
                }
                Toggle("Check remotes automatically (git fetch)", isOn: $store.settings.autoFetch)
                Picker("Auto-refresh on open", selection: $store.settings.refreshMinutes) {
                    Text("Manual only").tag(0)
                    Text("Every 5 min").tag(5)
                    Text("Every 15 min").tag(15)
                    Text("Every 30 min").tag(30)
                    Text("Every hour").tag(60)
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            HStack {
                Spacer()
                Button("Save & Rescan") {
                    commit()
                    store.rescan(thenCheckRemotes: store.settings.autoFetch)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 460)
        .onAppear {
            rootsText = store.settings.roots.joined(separator: "\n")
            excludesText = store.settings.excludedNames.joined(separator: ", ")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func commit() {
        let roots = rootsText.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !roots.isEmpty { store.settings.roots = roots }
        store.settings.excludedNames = excludesText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
