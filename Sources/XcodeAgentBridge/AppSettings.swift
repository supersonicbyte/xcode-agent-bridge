import Foundation
import BridgeCore
import Carbon.HIToolbox

enum HotKeyPreset: String, CaseIterable, Identifiable {
    case controlOptionSpace, controlOptionA, controlOptionCommandA, controlShiftSpace

    var id: String { rawValue }

    var label: String {
        switch self {
        case .controlOptionSpace: "⌃⌥Space"
        case .controlOptionA: "⌃⌥A"
        case .controlOptionCommandA: "⌃⌥⌘A"
        case .controlShiftSpace: "⌃⇧Space"
        }
    }

    var keyCode: Int {
        switch self {
        case .controlOptionSpace, .controlShiftSpace: kVK_Space
        case .controlOptionA, .controlOptionCommandA: kVK_ANSI_A
        }
    }

    var carbonModifiers: Int {
        switch self {
        case .controlOptionSpace, .controlOptionA: controlKey | optionKey
        case .controlOptionCommandA: controlKey | optionKey | cmdKey
        case .controlShiftSpace: controlKey | shiftKey
        }
    }
}

/// User preferences, persisted in UserDefaults.
@Observable final class AppSettings {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    var agent: AgentKind { didSet { defaults.set(agent.rawValue, forKey: "agent") } }
    var hotKey: HotKeyPreset {
        didSet {
            defaults.set(hotKey.rawValue, forKey: "hotKey")
            HotKeyCenter.shared.register(hotKey)
        }
    }
    var claudePath: String { didSet { defaults.set(claudePath, forKey: "claudePath") } }
    var codexPath: String { didSet { defaults.set(codexPath, forKey: "codexPath") } }
    var claudeModel: String { didSet { defaults.set(claudeModel, forKey: "claudeModel") } }
    var codexModel: String { didSet { defaults.set(codexModel, forKey: "codexModel") } }
    /// Save the file in Xcode before a Change so the agent edits what the user sees.
    var saveBeforeChange: Bool { didSet { defaults.set(saveBeforeChange, forKey: "saveBeforeChange") } }
    /// Send to a running session in the same project when there is one.
    var preferRunningSessions: Bool { didSet { defaults.set(preferRunningSessions, forKey: "preferRunningSessions") } }
    /// Start each new conversation from the agent's latest CLI session in the project.
    var continueLatestSession: Bool { didSet { defaults.set(continueLatestSession, forKey: "continueLatestSession") } }

    private init() {
        agent = AgentKind(rawValue: defaults.string(forKey: "agent") ?? "") ?? .claude
        hotKey = HotKeyPreset(rawValue: defaults.string(forKey: "hotKey") ?? "") ?? .controlOptionSpace
        claudePath = defaults.string(forKey: "claudePath") ?? ""
        codexPath = defaults.string(forKey: "codexPath") ?? ""
        claudeModel = defaults.string(forKey: "claudeModel") ?? ""
        codexModel = defaults.string(forKey: "codexModel") ?? ""
        saveBeforeChange = defaults.object(forKey: "saveBeforeChange") as? Bool ?? true
        continueLatestSession = defaults.bool(forKey: "continueLatestSession")
        preferRunningSessions = defaults.object(forKey: "preferRunningSessions") as? Bool ?? true
    }

    func pathOverride(for agent: AgentKind) -> String {
        agent == .claude ? claudePath : codexPath
    }

    func model(for agent: AgentKind) -> String {
        agent == .claude ? claudeModel : codexModel
    }
}
