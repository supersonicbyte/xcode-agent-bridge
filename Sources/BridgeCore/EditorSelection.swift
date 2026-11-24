import Foundation

/// What the user is pointing at in Xcode: the editor's text, the selected UTF-16 range and the file.
public struct EditorSelection: Sendable, Equatable {
    public var fileURL: URL
    public var buffer: String
    public var range: NSRange

    public init(fileURL: URL, buffer: String, range: NSRange) {
        self.fileURL = fileURL
        self.buffer = buffer
        let length = (buffer as NSString).length
        let location = min(max(0, range.location), length)
        self.range = NSRange(location: location, length: min(max(0, range.length), length - location))
    }

    public var isEmpty: Bool { range.length == 0 }

    /// One-based line numbers covered by the selection.
    public var lines: ClosedRange<Int> { Self.lineSpan(in: buffer as NSString, range: range) }

    /// The selected text, or the cursor's line when nothing is selected.
    public var code: String {
        let text = buffer as NSString
        guard isEmpty else { return text.substring(with: range) }
        var line = text.substring(with: text.lineRange(for: NSRange(location: range.location, length: 0)))
        while line.hasSuffix("\n") || line.hasSuffix("\r") { line.removeLast() }
        return line
    }

    public var fileName: String { fileURL.lastPathComponent }
    public var language: String { Self.language(forExtension: fileURL.pathExtension) }
    public var lineLabel: String {
        lines.count == 1 ? "L\(lines.lowerBound)" : "L\(lines.lowerBound)–\(lines.upperBound)"
    }

    /// The text range of whole lines, without the last line's line break.
    public static func range(ofLines lines: ClosedRange<Int>, in text: NSString) -> NSRange? {
        var line = 1, start: Int?, location = 0
        while location <= text.length {
            let lineRange = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
            if line == lines.lowerBound { start = lineRange.location }
            if line == lines.upperBound, let start {
                var end = NSMaxRange(lineRange)
                while end > start, [10, 13].contains(text.character(at: end - 1)) { end -= 1 }
                return NSRange(location: start, length: end - start)
            }
            if NSMaxRange(lineRange) >= text.length { break }
            location = NSMaxRange(lineRange)
            line += 1
        }
        return nil
    }

    public static func lineSpan(in text: NSString, range: NSRange) -> ClosedRange<Int> {
        let start = min(range.location, text.length)
        var end = min(range.location + range.length, text.length)
        // A selection of whole lines usually ends just after the last newline.
        if range.length > 0, end > start, text.character(at: end - 1) == 10 { end -= 1 }
        let first = newlineCount(in: text, before: start) + 1
        let last = newlineCount(in: text, before: max(start, end)) + 1
        return first...max(first, last)
    }

    static func newlineCount(in text: NSString, before index: Int) -> Int {
        var count = 0
        var search = NSRange(location: 0, length: min(index, text.length))
        while search.length > 0 {
            let found = text.range(of: "\n", options: .literal, range: search)
            if found.location == NSNotFound { break }
            count += 1
            search = NSRange(location: found.location + 1, length: NSMaxRange(search) - found.location - 1)
        }
        return count
    }

    public static func language(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "swift": "swift"
        case "m", "h": "objective-c"
        case "mm": "objective-c++"
        case "c": "c"
        case "cc", "cpp", "cxx", "hpp": "cpp"
        case "metal": "metal"
        case "py": "python"
        case "js", "mjs": "javascript"
        case "ts", "tsx": "typescript"
        case "json": "json"
        case "plist", "xml", "storyboard", "xib", "entitlements": "xml"
        case "sh", "zsh", "bash": "bash"
        case "md": "markdown"
        case "yml", "yaml": "yaml"
        default: ""
        }
    }
}

public enum ProjectLocator {
    /// The directory agents run in: the enclosing git repository, else the nearest
    /// Swift package or Xcode project, else the file's own folder.
    public static func workingDirectory(for file: URL, fileManager: FileManager = .default) -> URL {
        // Path strings stop at "/"; URL.deletingLastPathComponent() would keep adding "..".
        let start = (file.standardizedFileURL.path as NSString).deletingLastPathComponent
        var directory = start
        var project: String?
        while true {
            if fileManager.fileExists(atPath: (directory as NSString).appendingPathComponent(".git")) {
                return URL(fileURLWithPath: directory, isDirectory: true)
            }
            if project == nil, isProjectRoot(directory, fileManager: fileManager) { project = directory }
            let parent = (directory as NSString).deletingLastPathComponent
            if parent == directory || parent.isEmpty { break }
            directory = parent
        }
        return URL(fileURLWithPath: project ?? start, isDirectory: true)
    }

    public static func relativePath(of file: URL, in root: URL) -> String {
        let path = file.resolvingSymlinksInPath().standardizedFileURL.path
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
    }

    private static func isProjectRoot(_ directory: String, fileManager: FileManager) -> Bool {
        if fileManager.fileExists(atPath: (directory as NSString).appendingPathComponent("Package.swift")) { return true }
        let names = (try? fileManager.contentsOfDirectory(atPath: directory)) ?? []
        return names.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
    }
}
