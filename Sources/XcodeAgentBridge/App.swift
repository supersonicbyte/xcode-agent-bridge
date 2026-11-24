import AppKit
import SwiftUI
import BridgeCore

@main
struct XcodeAgentBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Xcode Agent Bridge", systemImage: "text.bubble") {
            MenuContent()
        }
        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if DebugCommands.handle(CommandLine.arguments) { return }
        HotKeyCenter.shared.action = { PanelManager.shared.hotKeyPressed() }
        HotKeyCenter.shared.register(AppSettings.shared.hotKey)
        Task { await AgentEnvironment.shared.load() }
        if !XcodeAccessibility.isTrusted(prompt: false) {
            _ = XcodeAccessibility.isTrusted(prompt: true)
        }
    }
}

private struct MenuContent: View {
    @Bindable var settings = AppSettings.shared
    private let comments = CommentQueue.shared

    var body: some View {
        Button("Ask About Selection in Xcode (\(settings.hotKey.label))") {
            PanelManager.shared.hotKeyPressed()
        }
        Button(comments.isEmpty ? "Pending Comments…" : "Pending Comments (\(comments.comments.count))…") {
            ReviewWindowController.shared.show()
        }
        Divider()
        Picker("Agent", selection: $settings.agent) {
            ForEach(AgentKind.allCases) { agent in
                Text(AgentEnvironment.shared.executable(for: agent) == nil ? "\(agent.displayName) (not found)" : agent.displayName)
                    .tag(agent)
            }
        }
        .pickerStyle(.inline)
        Divider()
        if !XcodeAccessibility.isTrusted(prompt: false) {
            Button("Grant Accessibility Access…") {
                _ = XcodeAccessibility.isTrusted(prompt: true)
                XcodeAccessibility.openAccessibilitySettings()
            }
        }
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Quit Xcode Agent Bridge") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

private struct SettingsView: View {
    @Bindable var settings = AppSettings.shared
    private let environment = AgentEnvironment.shared
    @State private var trusted = XcodeAccessibility.isTrusted(prompt: false)

    var body: some View {
        Form {
            Section("General") {
                Picker("Agent for new sessions", selection: $settings.agent) {
                    ForEach(AgentKind.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Shortcut", selection: $settings.hotKey) {
                    ForEach(HotKeyPreset.allCases) { Text($0.label).tag($0) }
                }
                Toggle(isOn: $settings.preferRunningSessions) {
                    Text("Send to a running session in the same project")
                    Text("When Claude or Codex is already running in the project, questions go to it and its terminal shows them. Otherwise the app starts a new session.")
                }
                Toggle("Save the file in Xcode before a Change", isOn: $settings.saveBeforeChange)
                Toggle(isOn: $settings.continueLatestSession) {
                    Text("Continue my latest CLI session")
                    Text("New conversations pick up the agent's most recent session in the project. Claude forks it so your terminal session is untouched; Codex appends to it.")
                }
            }
            agentSection(.claude, path: $settings.claudePath, model: $settings.claudeModel, modelHint: "e.g. opus, sonnet")
            agentSection(.codex, path: $settings.codexPath, model: $settings.codexModel, modelHint: "e.g. gpt-5-codex")
            Section("Permissions") {
                LabeledContent("Accessibility") {
                    if trusted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Open Settings…") {
                            _ = XcodeAccessibility.isTrusted(prompt: true)
                            XcodeAccessibility.openAccessibilitySettings()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .onAppear {
            NSApp.activate()
            trusted = XcodeAccessibility.isTrusted(prompt: false)
        }
    }

    private func agentSection(_ agent: AgentKind, path: Binding<String>, model: Binding<String>, modelHint: String) -> some View {
        Section(agent.displayName) {
            TextField("Command", text: path, prompt: Text(agent.executableName))
            LabeledContent("Found") {
                Text(environment.executable(for: agent) ?? "Not found — set the full path above")
                    .foregroundStyle(environment.executable(for: agent) == nil ? .red : .secondary)
                    .textSelection(.enabled)
            }
            TextField("Model", text: model, prompt: Text("Default (\(modelHint))"))
        }
    }
}
