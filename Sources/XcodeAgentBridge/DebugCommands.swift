import AppKit
import SwiftUI
import BridgeCore

/// Command-line flags for checking the setup without the panel:
///   --probe                     print what the app reads from Xcode
///   --ask claude|codex "text"   ask about the current selection and print the result
///   --show                      open the panel for the current selection
///   --render file.png           draw a sample panel offscreen, without showing a window
///   --agents                    list running Claude and Codex sessions
///   --send NAME "text"          send a question about the selection to a running session
enum DebugCommands {
    static func handle(_ arguments: [String]) -> Bool {
        if arguments.contains("--probe") {
            probe()
            exit(0)
        }
        if let index = arguments.firstIndex(of: "--ask"), arguments.count > index + 1 {
            let agent = AgentKind(rawValue: arguments[index + 1]) ?? .claude
            let question = arguments.count > index + 2 ? arguments[index + 2] : ""
            Task { await ask(agent: agent, question: question) }
            return true
        }
        if arguments.contains("--agents") {
            Task {
                await RunningAgents.shared.refresh()
                print("Codex background server:", RunningAgents.shared.codexServerRunning ? "running" : "not running")
                for agent in RunningAgents.shared.agents {
                    print("\(agent.agent.shortName)\t\(agent.name)\t\(agent.isBusy ? "busy" : "idle")\t\(agent.directory)\t\(agent.id)")
                }
                exit(0)
            }
            return true
        }
        if let index = arguments.firstIndex(of: "--send"), arguments.count > index + 2 {
            let name = arguments[index + 1], question = arguments[index + 2]
            Task { await send(to: name, question: question) }
            return true
        }
        if let index = arguments.firstIndex(of: "--render"), arguments.count > index + 1 {
            render(to: URL(fileURLWithPath: arguments[index + 1]))
            exit(0)
        }
        if arguments.contains("--selftest-comments") {
            selfTestComments()
            exit(0)
        }
        if arguments.contains("--show") {
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                PanelManager.shared.hotKeyPressed()
            }
        }
        return false
    }

    private static func render(to url: URL) {
        let source = "struct ReviewQueue {\n    private(set) var comments: [Comment] = []\n\n    mutating func append(_ comment: Comment) {\n        comments.append(comment)\n    }\n\n    func pending() -> [Comment] { comments.filter { !$0.sent } }\n}\n"
        let file = URL(fileURLWithPath: "/tmp/DemoProject/Sources/Review/ConfigurationBundleMetadata.ReviewQueue.swift")
        let range = (source as NSString).range(of: "    mutating func append(_ comment: Comment) {\n        comments.append(comment)\n    }\n")
        let capture = XcodeCapture(selection: EditorSelection(fileURL: file, buffer: source, range: range), anchor: nil, xcode: .current)
        let conversation = Conversation(capture: capture)
        let running = RunningAgent(id: "claude:1", agent: .claude, name: "myapp-7e", directory: "/tmp/DemoProject", isBusy: false, updatedAt: .now, address: .claude(pid: 1, socket: "/tmp/x.sock"))
        var ask = Conversation.Turn(request: "", mode: .ask, target: .running(running))
        ask.activities = ["Reading ReviewQueue.swift", "Searching for “append(”"]
        ask.reply = "`append(_:)` adds a comment to the queue **without any validation**, so duplicates and empty bodies are accepted.\n\nA guard would fix it:\n\n```swift\nguard !comment.body.isEmpty, !comments.contains(comment) else { return }\n```\n\nCallers in `ReviewModel.swift` assume the queue stays unique."
        ask.state = .done
        var change = Conversation.Turn(request: "Add that guard", mode: .change, target: .new(.codex))
        change.activities = ["Running `sed -n 1,40p Sources/Review/ReviewQueue.swift`"]
        change.reply = "Added the guard to `append(_:)` so empty and duplicate comments are ignored."
        change.changedFiles = ["Sources/Review/ReviewQueue.swift"]
        change.state = .done
        let comments = ProcessInfo.processInfo.environment["XAB_COMMENTS"] == "1"
        if comments {
            let other = EditorSelection(fileURL: URL(fileURLWithPath: "/tmp/DemoProject/Sources/Review/ReviewModel.swift"), buffer: "a\nb\nc\nlet queue = ReviewQueue()\n", range: NSRange(location: 6, length: 10))
            let queue = CommentQueue.shared
            queue.clear()
            queue.add(ReviewComment(selection: other, workingDirectory: URL(fileURLWithPath: "/tmp/DemoProject"), text: "Inject this instead of creating it here"))
            queue.add(ReviewComment(selection: capture.selection, workingDirectory: URL(fileURLWithPath: "/tmp/DemoProject"), text: "Ignore duplicates and empty comments"))
            var review = Conversation.Turn(request: "", mode: .change, target: .running(running))
            review.comments = [ReviewComment(selection: other, workingDirectory: URL(fileURLWithPath: "/tmp/DemoProject"), text: "Rename to reviewQueue"),
                               ReviewComment(selection: capture.selection, workingDirectory: URL(fileURLWithPath: "/tmp/DemoProject"), text: "Make this throw on a closed queue")]
            review.reply = "1. Renamed `queue` to `reviewQueue`.\n2. `append(_:)` now throws `QueueError.closed`."
            review.changedFiles = ["Sources/Review/ReviewModel.swift", "Sources/Review/ReviewQueue.swift"]
            review.state = .done
            conversation.appendPreviewTurn(review)
        } else {
            conversation.appendPreviewTurn(ask)
            conversation.appendPreviewTurn(change)
        }
        defer { if comments { CommentQueue.shared.clear() } }
        let model = PanelModel()
        model.content = .conversation(conversation)
        model.isKey = ProcessInfo.processInfo.environment["XAB_COLLAPSED"] != "1"
        model.mode = .ask
        model.target = .running(running)
        if comments, let first = CommentQueue.shared.comments.first {
            if ProcessInfo.processInfo.environment["XAB_EDIT"] == "1" { CommentQueue.shared.beginEditing(first) }
            CommentQueue.shared.flagAdded(CommentQueue.shared.comments.last!.id)
        }
        let review = ReviewModel()
        review.target = .running(running)
        review.project = "/tmp/DemoProject"
        let hosting: NSView = ProcessInfo.processInfo.environment["XAB_LIST"] == "1"
            ? NSHostingView(rootView: ReviewView(model: review, close: {}).frame(width: 620, height: 520))
            : NSHostingView(rootView: PanelView(model: model, close: {}))
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -4000, y: -4000), size: hosting.fittingSize), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: ProcessInfo.processInfo.environment["XAB_LIGHT"] == "1" ? .aqua : .darkAqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hosting
        // The transcript measures itself after the first layout pass; settle, then resize.
        for _ in 0..<3 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            window.setContentSize(hosting.fittingSize)
        }
        let size = hosting.fittingSize
        hosting.display()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        print("Rendered \(Int(size.width))×\(Int(size.height)) to \(url.path)")
    }

    /// Opens the panel view offscreen on one selection, switches it to another, and presses
    /// ⌘⏎: the comment must land on the second selection.
    private static func selfTestComments() {
        let source = (1...10).map { "let line\($0) = \($0)" }.joined(separator: "\n")
        func capture(_ line: Int) -> XcodeCapture {
            let range = EditorSelection.range(ofLines: line...line, in: source as NSString)!
            return XcodeCapture(selection: EditorSelection(fileURL: URL(fileURLWithPath: "/tmp/SelfTest/A.swift"), buffer: source, range: range),
                                anchor: nil, xcode: .current, editor: nil)
        }
        let queue = CommentQueue.shared
        let saved = queue.takeAll()
        defer { queue.clear(); queue.restore(saved) }
        let model = PanelModel()
        model.isKey = true
        model.content = .conversation(Conversation(capture: capture(2)))
        let hosting = NSHostingView(rootView: PanelView(model: model, close: {}))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 580, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        func settle() { for _ in 0..<3 { hosting.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.1)) } }
        func pressCommandReturn() {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
                                         context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            print("handled:", window.performKeyEquivalent(with: event))
            settle()
        }
        settle()
        model.draft = "first"
        settle()
        pressCommandReturn()
        model.content = .conversation(Conversation(capture: capture(7)))
        settle()
        model.draft = "second"
        settle()
        pressCommandReturn()
        for comment in queue.comments { print(comment.lineLabel, comment.text) }
    }

    private static func send(to name: String, question: String) async {
        await RunningAgents.shared.refresh()
        guard let agent = RunningAgents.shared.agents.first(where: { $0.name == name || $0.id == name }) else {
            print("No running session named \(name). Use --agents to list them.")
            exit(1)
        }
        do {
            let conversation = Conversation(capture: try XcodeAccessibility.capture())
            print("Sending to \(agent.agent.shortName) · \(agent.name) about \(conversation.relativePath) \(conversation.selection.lineLabel)…")
            conversation.send(question, mode: .ask, target: .running(agent))
            while conversation.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
            guard let turn = conversation.turns.last else { exit(1) }
            for activity in turn.activities { print("·", activity) }
            print(turn.reply)
            for notice in turn.notices { print("!", notice) }
            print("State:", turn.state)
            exit(turn.state == .done ? 0 : 1)
        } catch {
            print("Capture failed:", error.localizedDescription)
            exit(1)
        }
    }

    private static func probe() {
        print("Accessibility trusted:", XcodeAccessibility.isTrusted(prompt: false))
        do {
            let capture = try XcodeAccessibility.capture()
            let selection = capture.selection
            let root = ProjectLocator.workingDirectory(for: selection.fileURL)
            print("File:", selection.fileURL.path)
            print("Working directory:", root.path)
            print("Lines:", selection.lineLabel, selection.isEmpty ? "(cursor only)" : "")
            print("Anchor:", capture.anchor.map { NSStringFromRect($0) } ?? "none")
            if let editor = capture.editor {
                print("Editor visible frame:", XcodeAccessibility.visibleFrame(of: editor).map { NSStringFromRect($0) } ?? "none")
                print("Document:", XcodeAccessibility.document(of: editor) ?? "none")
                let started = Date()
                for _ in 0..<100 { _ = XcodeAccessibility.selectionBounds(in: editor, selection: selection) }
                print(String(format: "Selection bounds lookup: %.2f ms", Date().timeIntervalSince(started) * 10))
                let length = (selection.buffer as NSString).length
                for location in [0, length - 1] where location >= 0 {
                    let probe = EditorSelection(fileURL: selection.fileURL, buffer: selection.buffer, range: NSRange(location: location, length: 0))
                    print("Bounds at \(location):", XcodeAccessibility.selectionBounds(in: editor, selection: probe).map { NSStringFromRect($0) } ?? "none")
                }
            }
            print("Code:\n" + String(selection.code.prefix(400)))
        } catch {
            print("Capture failed:", error.localizedDescription)
        }
    }

    private static func ask(agent: AgentKind, question: String) async {
        await AgentEnvironment.shared.load()
        do {
            let conversation = Conversation(capture: try XcodeAccessibility.capture())
            print("Asking \(agent.displayName) about \(conversation.relativePath) \(conversation.selection.lineLabel)…")
            conversation.send(question, mode: .ask, target: .new(agent))
            while conversation.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
            guard let turn = conversation.turns.last else { exit(1) }
            for activity in turn.activities { print("·", activity) }
            print(turn.reply)
            for notice in turn.notices { print("!", notice) }
            print("State:", turn.state)
            exit(turn.state == .done ? 0 : 1)
        } catch {
            print("Capture failed:", error.localizedDescription)
            exit(1)
        }
    }
}
