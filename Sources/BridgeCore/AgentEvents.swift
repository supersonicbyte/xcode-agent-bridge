import Foundation

/// One thing that happened in an agent's run, in the order it happened.
public enum AgentEvent: Sendable, Equatable {
    case session(String)
    /// Text to append to the reply.
    case text(String)
    /// A short description of a tool call, such as "Reading Foo.swift".
    case activity(String)
    /// A file the agent wrote (absolute, or relative to the working directory).
    case fileChanged(String)
    /// Something the user should know that is not part of the reply.
    case notice(String)
    case completed
    case failed(String)
}

public protocol AgentStreamParser {
    mutating func consume(_ line: String) -> [AgentEvent]
}

public enum AgentParsers {
    public static func make(for agent: AgentKind) -> any AgentStreamParser {
        agent == .claude ? ClaudeStreamParser() : CodexStreamParser()
    }
}

private func object(_ line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func shortened(_ text: String, limit: Int = 80) -> String {
    let single = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    return single.count > limit ? String(single.prefix(limit - 1)) + "…" : single
}

/// Parses `claude -p --output-format stream-json --verbose --include-partial-messages`.
public struct ClaudeStreamParser: AgentStreamParser {
    private var wroteText = false
    private var streamedCurrentMessage = false
    private var pendingEdits: [String: String] = [:]
    private var deniedTools: Set<String> = []

    public init() {}

    public mutating func consume(_ line: String) -> [AgentEvent] {
        guard let message = object(line), let type = message["type"] as? String else { return [] }
        switch type {
        case "system":
            if message["subtype"] as? String == "init", let id = message["session_id"] as? String { return [.session(id)] }
            return []
        case "stream_event":
            guard let event = message["event"] as? [String: Any], let kind = event["type"] as? String else { return [] }
            switch kind {
            case "message_start":
                streamedCurrentMessage = false
                return []
            case "content_block_start":
                guard (event["content_block"] as? [String: Any])?["type"] as? String == "text", wroteText else { return [] }
                return [.text("\n\n")]
            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                      let text = delta["text"] as? String, !text.isEmpty else { return [] }
                streamedCurrentMessage = true
                wroteText = true
                return [.text(text)]
            default:
                return []
            }
        case "assistant":
            let content = (message["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            var events: [AgentEvent] = []
            for block in content {
                switch block["type"] as? String {
                case "text":
                    // Older CLIs don't send partial messages; use the whole block instead.
                    guard !streamedCurrentMessage, let text = block["text"] as? String, !text.isEmpty else { continue }
                    if wroteText { events.append(.text("\n\n")) }
                    events.append(.text(text))
                    wroteText = true
                case "tool_use":
                    let name = block["name"] as? String ?? "tool"
                    let input = block["input"] as? [String: Any] ?? [:]
                    if ["Edit", "MultiEdit", "Write", "NotebookEdit"].contains(name),
                       let id = block["id"] as? String,
                       let path = (input["file_path"] ?? input["notebook_path"]) as? String {
                        pendingEdits[id] = path
                    }
                    events.append(.activity(Self.describe(tool: name, input: input)))
                default:
                    continue
                }
            }
            return events
        case "user":
            let content = (message["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return content.compactMap { block in
                guard block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String,
                      let path = pendingEdits.removeValue(forKey: id), block["is_error"] as? Bool != true else { return nil }
                return .fileChanged(path)
            }
        case "result":
            var events: [AgentEvent] = []
            if let id = message["session_id"] as? String { events.append(.session(id)) }
            for denial in message["permission_denials"] as? [[String: Any]] ?? [] {
                guard let tool = denial["tool_name"] as? String, deniedTools.insert(tool).inserted else { continue }
                events.append(.notice("Claude wasn't allowed to use \(tool) here."))
            }
            let isError = message["is_error"] as? Bool == true || (message["subtype"] as? String).map { $0 != "success" } == true
            if isError {
                let reason = (message["result"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (message["subtype"] as? String).map { "Claude stopped: \($0.replacingOccurrences(of: "_", with: " "))." }
                    ?? "Claude reported an error."
                events.append(.failed(reason))
            } else {
                if !wroteText, let text = message["result"] as? String, !text.isEmpty { events.append(.text(text)) }
                events.append(.completed)
            }
            return events
        default:
            return []
        }
    }

    static func describe(tool: String, input: [String: Any]) -> String {
        func file(_ key: String = "file_path") -> String {
            ((input[key] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }) ?? "a file"
        }
        switch tool {
        case "Read": return "Reading \(file())"
        case "Edit", "MultiEdit": return "Editing \(file())"
        case "Write": return "Writing \(file())"
        case "NotebookEdit": return "Editing \(file("notebook_path"))"
        case "Grep": return "Searching for “\(shortened(input["pattern"] as? String ?? "", limit: 50))”"
        case "Glob": return "Finding files matching \(input["pattern"] as? String ?? "a pattern")"
        case "Bash": return "Running `\(shortened(input["command"] as? String ?? ""))`"
        case "Task", "Agent": return "Running a subagent"
        case "WebFetch", "WebSearch": return "Searching the web"
        case "TodoWrite": return "Updating its plan"
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.split(separator: "__").dropFirst()
                return "Using \(parts.joined(separator: "."))"
            }
            return "Using \(tool)"
        }
    }
}

/// Parses `codex exec --json`.
public struct CodexStreamParser: AgentStreamParser {
    private var wroteText = false

    public init() {}

    public mutating func consume(_ line: String) -> [AgentEvent] {
        guard let message = object(line), let type = message["type"] as? String else { return [] }
        switch type {
        case "thread.started":
            return (message["thread_id"] as? String).map { [.session($0)] } ?? []
        case "item.started":
            guard let item = message["item"] as? [String: Any] else { return [] }
            switch item["type"] as? String {
            case "command_execution":
                return [.activity("Running `\(shortened(Self.unwrapShell(item["command"] as? String ?? "")))`")]
            case "mcp_tool_call":
                let name = [item["server"], item["tool"]].compactMap { $0 as? String }.joined(separator: ".")
                return [.activity("Using \(name.isEmpty ? "a tool" : name)")]
            case "web_search":
                return [.activity("Searching the web")]
            default:
                return []
            }
        case "item.completed":
            guard let item = message["item"] as? [String: Any] else { return [] }
            switch item["type"] as? String {
            case "agent_message":
                guard let text = item["text"] as? String, !text.isEmpty else { return [] }
                defer { wroteText = true }
                return wroteText ? [.text("\n\n"), .text(text)] : [.text(text)]
            case "file_change":
                guard (item["status"] as? String).map({ $0 == "completed" }) ?? true else { return [] }
                let changes = item["changes"] as? [[String: Any]] ?? []
                return changes.compactMap { ($0["path"] as? String).map(AgentEvent.fileChanged) }
            case "error":
                return (item["message"] as? String).map { [.notice($0)] } ?? []
            default:
                return []
            }
        case "turn.completed":
            return [.completed]
        case "turn.failed":
            let reason = ((message["error"] as? [String: Any])?["message"] as? String) ?? "Codex reported an error."
            return [.failed(reason)]
        case "error":
            return (message["message"] as? String).map { [.notice($0)] } ?? []
        default:
            return []
        }
    }

    /// Codex wraps commands as `/bin/zsh -lc '…'`; show only the command itself.
    static func unwrapShell(_ command: String) -> String {
        for prefix in ["/bin/zsh -lc ", "/bin/bash -lc ", "bash -lc ", "zsh -lc ", "/bin/sh -c "] where command.hasPrefix(prefix) {
            var inner = String(command.dropFirst(prefix.count))
            if inner.count >= 2, let first = inner.first, first == inner.last, first == "'" || first == "\"" {
                inner = String(inner.dropFirst().dropLast())
            }
            return inner
        }
        return command
    }
}
