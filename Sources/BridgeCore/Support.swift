import Foundation

/// GUI apps don't inherit the shell's PATH, so agents installed with npm, Homebrew or
/// their own installers are found through the login shell plus common locations.
public enum ShellEnvironment {
    public static let marker = "__XCODE_AGENT_BRIDGE_PATH__"

    public static var probeCommand: String { "printf '\(marker)%s\(marker)' \"$PATH\"" }

    public static func parsePath(fromShellOutput output: String) -> String? {
        let parts = output.components(separatedBy: marker)
        guard parts.count >= 3 else { return nil }
        let path = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    public static func searchPath(shellPath: String?, home: String) -> [String] {
        let fallbacks = [
            "\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin",
            "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.volta/bin", "\(home)/.cargo/bin",
            "/usr/bin", "/bin",
        ]
        var seen = Set<String>()
        return ((shellPath ?? "").split(separator: ":").map(String.init) + fallbacks).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public static func resolve(_ name: String, in directories: [String], fileManager: FileManager = .default) -> String? {
        if name.contains("/") {
            let path = (name as NSString).expandingTildeInPath
            return fileManager.isExecutableFile(atPath: path) ? path : nil
        }
        return directories.lazy.map { ($0 as NSString).appendingPathComponent(name) }.first { fileManager.isExecutableFile(atPath: $0) }
    }
}

/// Splits a reply into prose and fenced code blocks so the panel can style code.
public enum ReplySegment: Equatable, Sendable {
    case prose(String)
    case code(language: String, body: String)

    public static func parse(_ text: String) -> [ReplySegment] {
        var segments: [ReplySegment] = []
        var prose: [Substring] = [], code: [Substring] = []
        var fence: Substring?
        var language = ""
        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { segments.append(.prose(joined)) }
            prose.removeAll()
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " }
            if let open = fence {
                if trimmed.hasPrefix(open), trimmed.drop(while: { $0 == "`" || $0 == "~" }).allSatisfy(\.isWhitespace) {
                    segments.append(.code(language: language, body: code.joined(separator: "\n")))
                    code.removeAll()
                    fence = nil
                } else {
                    code.append(line)
                }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushProse()
                let marker = trimmed.prefix { $0 == trimmed.first }
                fence = marker
                language = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            } else {
                prose.append(line)
            }
        }
        // An unclosed fence is still streaming; show what arrived as code.
        if fence != nil { segments.append(.code(language: language, body: code.joined(separator: "\n"))) }
        flushProse()
        return segments
    }
}
