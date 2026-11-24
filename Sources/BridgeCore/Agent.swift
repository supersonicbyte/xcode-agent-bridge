import Foundation

public enum AgentKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude, codex
    public var id: String { rawValue }
    public var displayName: String { self == .claude ? "Claude Code" : "Codex" }
    public var shortName: String { self == .claude ? "Claude" : "Codex" }
    public var executableName: String { rawValue }
}

public enum RequestMode: String, CaseIterable, Codable, Sendable {
    /// Read-only: the agent may read files but not edit them.
    case ask
    /// The agent edits files in the working directory.
    case change
}

public enum SessionReference: Sendable, Equatable {
    case new
    case resume(String)
    /// Continue the agent's most recent session in the working directory.
    case continueLatest
}

public enum InvocationBuilder {
    /// Command-line arguments for a non-interactive run. The prompt is always written to
    /// standard input, so it can never be mistaken for an option.
    public static func arguments(agent: AgentKind, mode: RequestMode, session: SessionReference, model: String? = nil) -> [String] {
        let model = model?.trimmingCharacters(in: .whitespaces) ?? ""
        switch agent {
        case .claude:
            var arguments = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                             "--append-system-prompt", PromptBuilder.systemNote]
            switch session {
            case .new: break
            case .resume(let id): arguments += ["--resume", id]
            // Forking leaves the terminal session untouched if it is still open.
            case .continueLatest: arguments += ["--continue", "--fork-session"]
            }
            switch mode {
            case .ask: arguments += ["--permission-mode", "default", "--disallowedTools", "Edit,Write,MultiEdit,NotebookEdit"]
            case .change: arguments += ["--permission-mode", "acceptEdits"]
            }
            if !model.isEmpty { arguments += ["--model", model] }
            return arguments
        case .codex:
            var arguments = ["exec"]
            if session != .new { arguments.append("resume") }
            arguments += ["--json", "--skip-git-repo-check",
                          "-c", "sandbox_mode=\"\(mode == .ask ? "read-only" : "workspace-write")\"",
                          "-c", "approval_policy=\"never\""]
            if !model.isEmpty { arguments += ["-m", model] }
            switch session {
            case .new: break
            case .resume(let id): arguments.append(id)
            case .continueLatest: arguments.append("--last")
            }
            arguments.append("-")
            return arguments
        }
    }
}

public struct PromptContext: Sendable, Equatable {
    public var selection: EditorSelection
    public var relativePath: String
    public var hasUnsavedChanges: Bool

    public init(selection: EditorSelection, relativePath: String, hasUnsavedChanges: Bool) {
        self.selection = selection
        self.relativePath = relativePath
        self.hasUnsavedChanges = hasUnsavedChanges
    }
}

public enum PromptBuilder {
    public static let maxCodeLength = 24_000
    public static let defaultQuestion = "Explain what this code does and point out anything surprising or risky."
    public static let systemNote = "The user is asking from Xcode through xcode-agent-bridge. Your reply is shown in a small floating panel next to their code, so keep it concise and use short Markdown."

    /// Builds the prompt for one turn. `context` is nil for a follow-up in a session that
    /// already has the selection.
    /// The tag appended to messages for running sessions, so the reply can be found in the
    /// session's transcript.
    public static func referenceLine(_ reference: String) -> String {
        "(Sent from Xcode by xcode-agent-bridge · ref \(reference))"
    }

    public static func prompt(request: String, mode: RequestMode, context: PromptContext?, reference: String? = nil) -> String {
        var parts: [String] = []
        if let context {
            let selection = context.selection
            let lines = selection.lines
            let location = if selection.isEmpty {
                "The cursor is on line \(lines.lowerBound) of `\(context.relativePath)` in Xcode:"
            } else if lines.count == 1 {
                "I selected line \(lines.lowerBound) of `\(context.relativePath)` in Xcode:"
            } else {
                "I selected lines \(lines.lowerBound)–\(lines.upperBound) of `\(context.relativePath)` in Xcode:"
            }
            var code = selection.code
            let truncated = (code as NSString).length > maxCodeLength
            if truncated { code = (code as NSString).substring(to: maxCodeLength) }
            let fence = code.contains("```") ? "````" : "```"
            parts.append("\(location)\n\n\(fence)\(selection.language)\n\(code)\n\(fence)")
            if truncated { parts.append("(The selection was cut off here; read the file for the rest.)") }
            if context.hasUnsavedChanges {
                parts.append("The file has unsaved edits in Xcode, so the file on disk may differ from the code above.")
            }
        }
        let request = request.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .ask:
            parts.append(request.isEmpty ? defaultQuestion : request)
            parts.append("Answer concisely; your reply appears in a small panel next to the code. Don't modify any files.")
        case .change:
            parts.append("Make this change by editing the files directly: \(request.isEmpty ? "improve this code" : request)")
            parts.append("Keep the change focused on the selected code unless the request needs more. When you're done, summarize what you changed in one or two sentences.")
        }
        if let reference { parts.append(referenceLine(reference)) }
        return parts.joined(separator: "\n\n")
    }
}
