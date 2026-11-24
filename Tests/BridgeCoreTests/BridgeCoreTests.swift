import Foundation
import Testing
@testable import BridgeCore

private let source = "import Foundation\n\nstruct Queue {\n    var items: [Int] = []\n}\n"
private let file = URL(fileURLWithPath: "/repo/Sources/Queue.swift")

@Test func selectionLinesAndCode() {
    let text = source as NSString
    let structLine = text.range(of: "struct Queue {\n    var items: [Int] = []\n")
    let selection = EditorSelection(fileURL: file, buffer: source, range: structLine)
    // A selection ending right after a newline does not include the next line.
    #expect(selection.lines == 3...4)
    #expect(selection.lineLabel == "L3–4")
    #expect(selection.language == "swift")

    let cursor = EditorSelection(fileURL: file, buffer: source, range: NSRange(location: text.range(of: "items").location, length: 0))
    #expect(cursor.isEmpty && cursor.lines == 4...4)
    #expect(cursor.code == "    var items: [Int] = []")

    let first = EditorSelection(fileURL: file, buffer: source, range: NSRange(location: 0, length: 6))
    #expect(first.lines == 1...1 && first.code == "import")
    // Out-of-range values from Accessibility are clamped instead of crashing.
    let clamped = EditorSelection(fileURL: file, buffer: source, range: NSRange(location: 999, length: 5))
    #expect(clamped.range == NSRange(location: text.length, length: 0))
}

@Test func promptIncludesSelectionAndRules() {
    let range = (source as NSString).range(of: "struct Queue {")
    let context = PromptContext(selection: EditorSelection(fileURL: file, buffer: source, range: range),
                                relativePath: "Sources/Queue.swift", hasUnsavedChanges: true)
    let ask = PromptBuilder.prompt(request: "  ", mode: .ask, context: context)
    #expect(ask.hasPrefix("I selected line 3 of `Sources/Queue.swift` in Xcode:\n\n```swift\nstruct Queue {\n```"))
    #expect(ask.contains(PromptBuilder.defaultQuestion))
    #expect(ask.contains("unsaved edits"))
    #expect(ask.contains("Don't modify any files."))

    let change = PromptBuilder.prompt(request: "Make it generic", mode: .change, context: nil)
    #expect(change.hasPrefix("Make this change by editing the files directly: Make it generic"))
    #expect(!change.contains("```"))
}

@Test func claudeArguments() {
    let ask = InvocationBuilder.arguments(agent: .claude, mode: .ask, session: .new)
    #expect(ask.starts(with: ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages"]))
    #expect(ask.contains("--disallowedTools") && !ask.contains("acceptEdits"))
    let change = InvocationBuilder.arguments(agent: .claude, mode: .change, session: .resume("abc"), model: "opus")
    #expect(change.suffix(6) == ["--resume", "abc", "--permission-mode", "acceptEdits", "--model", "opus"])
    let latest = InvocationBuilder.arguments(agent: .claude, mode: .ask, session: .continueLatest)
    #expect(latest.contains("--continue") && latest.contains("--fork-session"))
}

@Test func codexArguments() {
    #expect(InvocationBuilder.arguments(agent: .codex, mode: .ask, session: .new) ==
            ["exec", "--json", "--skip-git-repo-check", "-c", "sandbox_mode=\"read-only\"", "-c", "approval_policy=\"never\"", "-"])
    #expect(InvocationBuilder.arguments(agent: .codex, mode: .change, session: .resume("t1"), model: "gpt-5") ==
            ["exec", "resume", "--json", "--skip-git-repo-check", "-c", "sandbox_mode=\"workspace-write\"", "-c", "approval_policy=\"never\"", "-m", "gpt-5", "t1", "-"])
    #expect(InvocationBuilder.arguments(agent: .codex, mode: .ask, session: .continueLatest).suffix(2) == ["--last", "-"])
}

@Test func claudeStreamParsing() {
    let lines = [
        #"{"type":"system","subtype":"hook_started","session_id":"s1"}"#,
        #"{"type":"system","subtype":"init","session_id":"s1","tools":["Read"]}"#,
        #"{"type":"stream_event","event":{"type":"message_start"}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"tool_use","name":"Edit"}}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/repo/Sources/Queue.swift"}},{"type":"tool_use","id":"t2","name":"Write","input":{"file_path":"/repo/Denied.swift"}}]}}"#,
        #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"},{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":"denied"}]}}"#,
        #"{"type":"stream_event","event":{"type":"message_start"}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text","text":""}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Made it "}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"generic."}}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"text","text":"Made it generic."}]}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text","text":""}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Done."}}}"#,
        #"{"type":"result","subtype":"success","is_error":false,"result":"Made it generic.\n\nDone.","session_id":"s1","permission_denials":[{"tool_name":"Bash"},{"tool_name":"Bash"}]}"#,
        "not json",
    ]
    var parser = ClaudeStreamParser()
    let events = lines.flatMap { parser.consume($0) }
    #expect(events == [
        .session("s1"),
        .activity("Editing Queue.swift"), .activity("Writing Denied.swift"),
        .fileChanged("/repo/Sources/Queue.swift"),
        .text("Made it "), .text("generic."), .text("\n\n"), .text("Done."),
        .session("s1"), .notice("Claude wasn't allowed to use Bash here."), .completed,
    ])

    var failing = ClaudeStreamParser()
    #expect(failing.consume(#"{"type":"result","subtype":"error_max_turns","is_error":true}"#) == [.failed("Claude stopped: error max turns.")])
    // Without partial messages the full assistant text is used.
    var plain = ClaudeStreamParser()
    #expect(plain.consume(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Hi"}]}}"#) == [.text("Hi")])
}

@Test func codexStreamParsing() {
    let lines = [
        #"{"type":"thread.started","thread_id":"th"}"#,
        #"{"type":"turn.started"}"#,
        #"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"I’ll read it."}}"#,
        #"{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc 'cat a.swift'","status":"in_progress"}}"#,
        #"{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc 'cat a.swift'","exit_code":0}}"#,
        #"{"type":"item.completed","item":{"id":"item_2","type":"file_change","status":"completed","changes":[{"path":"/repo/a.swift","kind":"update"}]}}"#,
        #"{"type":"item.completed","item":{"id":"item_3","type":"agent_message","text":"Done."}}"#,
        #"{"type":"turn.completed","usage":{}}"#,
    ]
    var parser = CodexStreamParser()
    #expect(lines.flatMap { parser.consume($0) } == [
        .session("th"), .text("I’ll read it."), .activity("Running `cat a.swift`"),
        .fileChanged("/repo/a.swift"), .text("\n\n"), .text("Done."), .completed,
    ])
    #expect(parser.consume(#"{"type":"turn.failed","error":{"message":"Not logged in"}}"#) == [.failed("Not logged in")])
}

@Test func shellPathAndResolution() throws {
    let output = "zsh noise\n\(ShellEnvironment.marker)/a:/b:/a\(ShellEnvironment.marker)\nmore noise"
    let path = try #require(ShellEnvironment.parsePath(fromShellOutput: output))
    #expect(path == "/a:/b:/a")
    let search = ShellEnvironment.searchPath(shellPath: path, home: "/Users/me")
    #expect(search.prefix(3) == ["/a", "/b", "/Users/me/.local/bin"])
    #expect(ShellEnvironment.parsePath(fromShellOutput: "no markers") == nil)
    #expect(ShellEnvironment.resolve("sh", in: ["/nonexistent", "/bin"]) == "/bin/sh")
    #expect(ShellEnvironment.resolve("/bin/sh", in: []) == "/bin/sh")
}

@Test func projectLocatorPrefersGitRoot() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("xab-" + UUID().uuidString)
    let nested = root.appendingPathComponent("App/Sources")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let swiftFile = nested.appendingPathComponent("Main.swift")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("App/App.xcodeproj"), withIntermediateDirectories: true)
    #expect(ProjectLocator.workingDirectory(for: swiftFile).lastPathComponent == "App")
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
    let directory = ProjectLocator.workingDirectory(for: swiftFile)
    #expect(directory.standardizedFileURL.path == root.standardizedFileURL.path)
    #expect(ProjectLocator.relativePath(of: swiftFile, in: directory) == "App/Sources/Main.swift")
}

@Test func workingTreeSnapshotFindsShellEdits() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("xab-snap-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let git = Process()
    git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    git.arguments = ["-C", root.path, "init", "-q"]
    try git.run()
    git.waitUntilExit()
    try "dirty\n".write(to: root.appendingPathComponent("Dirty.swift"), atomically: true, encoding: .utf8)
    try "same\n".write(to: root.appendingPathComponent("Same.swift"), atomically: true, encoding: .utf8)
    let before = try #require(WorkingTreeSnapshot.capture(in: root))
    #expect(before.entries.keys.sorted() == ["Dirty.swift", "Same.swift"])
    // Already-dirty files count when touched again; new files count too.
    let dirty = root.appendingPathComponent("Dirty.swift")
    try "dirty again\n".write(to: dirty, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: dirty.path)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("New"), withIntermediateDirectories: true)
    try "new\n".write(to: root.appendingPathComponent("New/File.swift"), atomically: true, encoding: .utf8)
    let after = try #require(WorkingTreeSnapshot.capture(in: root))
    #expect(after.changedFiles(since: before) == ["Dirty.swift", "New/File.swift"])
    #expect(WorkingTreeSnapshot.parse("R  new.swift\0old.swift\0 M a.swift\0") == ["new.swift", "a.swift"])
    #expect(WorkingTreeSnapshot.capture(in: URL(fileURLWithPath: "/")) == nil)
}

@Test func replySegments() {
    let reply = "Use a generic:\n\n```swift\nstruct Queue<T> {\n}\n```\nThat's it.\n```bash\necho streaming"
    #expect(ReplySegment.parse(reply) == [
        .prose("Use a generic:"),
        .code(language: "swift", body: "struct Queue<T> {\n}"),
        .prose("That's it."),
        .code(language: "bash", body: "echo streaming"),
    ])
}
