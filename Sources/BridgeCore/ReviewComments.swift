import Foundation

/// A comment the user left on code in Xcode, waiting to be sent together with others.
public struct ReviewComment: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var filePath: String
    public var relativePath: String
    public var workingDirectory: String
    public var firstLine: Int
    public var lastLine: Int
    public var code: String
    /// Set when `code` covers more than the commented lines: a comment on a blank line
    /// carries the code around it.
    public var codeStartLine: Int?
    public var language: String
    public var isCursorLine: Bool
    public var text: String

    public init(id: UUID = UUID(), selection: EditorSelection, workingDirectory: URL, text: String) {
        self.id = id
        filePath = selection.fileURL.standardizedFileURL.path
        self.workingDirectory = workingDirectory.path
        relativePath = ProjectLocator.relativePath(of: selection.fileURL, in: workingDirectory)
        firstLine = selection.lines.lowerBound
        lastLine = selection.lines.upperBound
        // Whole lines, so a selection that starts mid-line keeps its indentation and markers.
        let all = selection.buffer.components(separatedBy: "\n")
        func slice(_ lines: ClosedRange<Int>) -> String {
            let lower = max(1, lines.lowerBound), upper = min(all.count, lines.upperBound)
            guard lower <= upper else { return "" }
            return all[(lower - 1)...(upper - 1)].map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }.joined(separator: "\n")
        }
        let commented = selection.lines
        if slice(commented).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lower = max(1, commented.lowerBound - Self.contextLines)
            code = slice(lower...(commented.upperBound + Self.contextLines))
            codeStartLine = lower
        } else {
            code = slice(commented)
            codeStartLine = nil
        }
        language = selection.language
        isCursorLine = selection.isEmpty
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let contextLines = 3

    public var fileName: String { (filePath as NSString).lastPathComponent }
    public var lineLabel: String { firstLine == lastLine ? "L\(firstLine)" : "L\(firstLine)–\(lastLine)" }

    /// Whether this comment is on any of the lines `selection` covers.
    public func matches(_ selection: EditorSelection) -> Bool {
        filePath == selection.fileURL.standardizedFileURL.path && (firstLine...lastLine).overlaps(selection.lines)
    }
}

extension PromptBuilder {
    /// Code longer than this is cut per comment; the agent can read the file for the rest.
    public static let maxCommentCodeLength = 6_000

    /// One prompt carrying every comment, ordered by file and line and numbered so the agent
    /// can answer them one by one.
    public static func reviewPrompt(comments: [ReviewComment], mode: RequestMode, reference: String? = nil) -> String {
        let ordered = sortedForReview(comments)
        let count = ordered.count
        var parts = ["I left \(count) comment\(count == 1 ? "" : "s") on code in Xcode."]
        for (index, comment) in ordered.enumerated() {
            var lines = comment.firstLine == comment.lastLine
                ? "line \(comment.firstLine)" : "lines \(comment.firstLine)–\(comment.lastLine)"
            if let start = comment.codeStartLine {
                let end = start + comment.code.components(separatedBy: "\n").count - 1
                lines += " (blank; lines \(start)–\(end) shown around it)"
            }
            var code = comment.code
            let truncated = (code as NSString).length > maxCommentCodeLength
            if truncated { code = (code as NSString).substring(to: maxCommentCodeLength) }
            let fence = code.contains("```") ? "````" : "```"
            var block = "## \(index + 1). `\(comment.relativePath)` \(lines)\n\n\(fence)\(comment.language)\n\(code)\n\(fence)"
            if truncated { block += "\n(Cut off here; read the file for the rest.)" }
            block += "\n\n\(comment.text)"
            parts.append(block)
        }
        switch mode {
        case .ask:
            parts.append("Answer each comment by its number. Keep each answer short; the replies appear in a small panel next to the code. Don't modify any files.")
        case .change:
            parts.append("Address every comment by editing the files directly. Line numbers are from when the comments were written, so read the files before editing. When you're done, give one short line per comment number saying what you changed, or why you didn't.")
        }
        if let reference { parts.append(referenceLine(reference)) }
        return parts.joined(separator: "\n\n")
    }

    public static func sortedForReview(_ comments: [ReviewComment]) -> [ReviewComment] {
        comments.enumerated().sorted { a, b in
            if a.element.relativePath != b.element.relativePath { return a.element.relativePath < b.element.relativePath }
            if a.element.firstLine != b.element.firstLine { return a.element.firstLine < b.element.firstLine }
            return a.offset < b.offset
        }.map(\.element)
    }
}
