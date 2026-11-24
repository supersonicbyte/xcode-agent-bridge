import Foundation

/// The repository's modified and untracked files with their modification dates. Comparing a
/// snapshot from before and after a run finds every file the agent touched, including edits
/// made through shell commands that never show up as tool calls.
public struct WorkingTreeSnapshot: Sendable, Equatable {
    public var entries: [String: Date]

    public init(entries: [String: Date]) {
        self.entries = entries
    }

    /// Returns nil when `root` is not inside a git repository.
    public static func capture(in root: URL) -> WorkingTreeSnapshot? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "status", "--porcelain=v1", "-z", "--untracked-files=all"]
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        var entries: [String: Date] = [:]
        for path in parse(String(decoding: data, as: UTF8.self)) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path)
            entries[path] = attributes?[.modificationDate] as? Date ?? .distantPast
        }
        return WorkingTreeSnapshot(entries: entries)
    }

    /// Paths, relative to the repository root, that differ between the two snapshots.
    public func changedFiles(since before: WorkingTreeSnapshot) -> [String] {
        let paths = Set(entries.keys).union(before.entries.keys)
        return paths.filter { entries[$0] != before.entries[$0] }.sorted()
    }

    static func parse(_ status: String) -> [String] {
        var paths: [String] = []
        var records = status.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let record = records.next() {
            guard record.count > 3 else { continue }
            let code = record.prefix(2)
            paths.append(String(record.dropFirst(3)))
            // Renames and copies are followed by the original path.
            if code.contains("R") || code.contains("C") { _ = records.next() }
        }
        return paths
    }
}
