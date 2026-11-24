import Foundation
import Testing
@testable import BridgeCore

/// Runs the real `claude` and `codex` CLIs in a scratch repository. Opt in with
/// `XAB_LIVE=1 swift test --filter LiveAgentTests` (uses your agent accounts).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["XAB_LIVE"] == "1"))
struct LiveAgentTests {
    @Test(arguments: AgentKind.allCases)
    func changeThenFollowUp(agent: AgentKind) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xab-live-\(agent.rawValue)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try run("/usr/bin/git", ["init", "-q"], in: root)
        let file = root.appendingPathComponent("Math.swift")
        let source = "func double(_ value: Int) -> Int {\n    let total = value + value\n    return total\n}\n"
        try source.write(to: file, atomically: true, encoding: .utf8)

        let home = NSHomeDirectory()
        let executable = try #require(ShellEnvironment.resolve(agent.executableName, in: ShellEnvironment.searchPath(shellPath: ProcessInfo.processInfo.environment["PATH"], home: home)))
        let selection = EditorSelection(fileURL: file, buffer: source, range: (source as NSString).range(of: "    let total = value + value\n    return total\n"))
        let context = PromptContext(selection: selection, relativePath: "Math.swift", hasUnsavedChanges: false)

        // 1. Change: the agent edits the file, found through events or the working tree.
        let before = try #require(WorkingTreeSnapshot.capture(in: root))
        let change = try events(executable, InvocationBuilder.arguments(agent: agent, mode: .change, session: .new),
                                PromptBuilder.prompt(request: "Rename the local `total` to `sum`.", mode: .change, context: context), agent: agent, in: root)
        #expect(change.contains(.completed))
        let after = try #require(WorkingTreeSnapshot.capture(in: root))
        #expect(after.changedFiles(since: before) == ["Math.swift"])
        let edited = try String(contentsOf: file, encoding: .utf8)
        #expect(edited.contains("sum") && !edited.contains("total"))

        // 2. Read-only follow-up in the same session.
        let session = try #require(change.compactMap { if case .session(let id) = $0 { id } else { nil } }.last)
        let followUp = try events(executable, InvocationBuilder.arguments(agent: agent, mode: .ask, session: .resume(session)),
                                  PromptBuilder.prompt(request: "Which identifier did you just rename? Answer with one word.", mode: .ask, context: nil), agent: agent, in: root)
        let reply = followUp.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined()
        #expect(followUp.contains(.completed))
        #expect(reply.lowercased().contains("total"))
        #expect(try String(contentsOf: file, encoding: .utf8) == edited)
    }

    private func events(_ executable: String, _ arguments: [String], _ prompt: String, agent: AgentKind, in directory: URL) throws -> [AgentEvent] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let output = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(prompt.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var parser = AgentParsers.make(for: agent)
        return String(decoding: data, as: UTF8.self).split(separator: "\n").flatMap { parser.consume(String($0)) }
    }

    private func run(_ executable: String, _ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
    }
}
