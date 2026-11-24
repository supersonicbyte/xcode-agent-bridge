import AppKit
import BridgeCore

/// One exchange with an agent about a selection in Xcode, including follow-ups.
@Observable final class Conversation {
    struct Turn: Identifiable {
        enum State: Equatable { case running, done, failed(String), stopped }
        let id = UUID()
        var request: String
        var mode: RequestMode
        var target: AgentTarget
        var reply = ""
        var activities: [String] = []
        var notices: [String] = []
        var changedFiles: [String] = []
        /// The comments sent in this turn, for a batch of review comments.
        var comments: [ReviewComment] = []
        var state = State.running
    }

    let capture: XcodeCapture
    let workingDirectory: URL
    let relativePath: String
    private(set) var turns: [Turn] = []
    private var sessions: [AgentKind: String] = [:]
    /// Running sessions that have already been sent the selection.
    private var briefedTargets: Set<String> = []
    private var task: Task<Void, Never>?

    var selection: EditorSelection { capture.selection }
    var isRunning: Bool { task != nil }

    init(capture: XcodeCapture) {
        self.capture = capture
        workingDirectory = ProjectLocator.workingDirectory(for: capture.selection.fileURL)
        relativePath = ProjectLocator.relativePath(of: capture.selection.fileURL, in: workingDirectory)
    }

    /// A conversation with no selection, for sending batches of comments from the list.
    convenience init(reviewIn directory: URL) {
        let placeholder = EditorSelection(fileURL: directory, buffer: "", range: NSRange(location: 0, length: 0))
        self.init(capture: XcodeCapture(selection: placeholder, anchor: nil, xcode: XcodeAccessibility.runningXcode ?? .current, editor: nil))
    }

    func send(_ request: String, mode: RequestMode, target: AgentTarget) {
        let turn = Turn(request: request.trimmingCharacters(in: .whitespacesAndNewlines), mode: mode, target: target)
        let briefed = briefedTargets.contains(target.id)
        start(turn, directory: workingDirectory, briefs: true) { [selection, relativePath] unsaved, reference in
            let context = briefed ? nil : PromptContext(selection: selection, relativePath: relativePath, hasUnsavedChanges: unsaved)
            return PromptBuilder.prompt(request: request, mode: mode, context: context, reference: reference)
        }
    }

    /// Sends a batch of comments, possibly on several files, as one turn.
    func sendReview(_ comments: [ReviewComment], mode: RequestMode, target: AgentTarget) {
        guard !comments.isEmpty else { return }
        var turn = Turn(request: "", mode: mode, target: target)
        turn.comments = PromptBuilder.sortedForReview(comments)
        let directories = Set(comments.map(\.workingDirectory))
        let directory = directories.count == 1 ? URL(fileURLWithPath: directories.first!) : workingDirectory
        start(turn, directory: directory, briefs: false) { _, reference in
            PromptBuilder.reviewPrompt(comments: comments, mode: mode, reference: reference)
        }
    }

    /// Runs one turn. `briefs` says whether the prompt includes the selection, so later
    /// follow-ups to the same target can leave it out.
    private func start(_ turn: Turn, directory: URL, briefs: Bool, prompt makePrompt: @escaping (_ unsaved: Bool, _ reference: String?) -> String) {
        guard task == nil else { return }
        let settings = AppSettings.shared
        let target = turn.target
        let mode = turn.mode
        let agent = target.agent
        let id = turn.id
        let review = !turn.comments.isEmpty
        turns.append(turn)
        let events: (String) -> AsyncThrowingStream<AgentEvent, Error>
        var reference: String?
        switch target {
        case .running(let running):
            let tag = String(UUID().uuidString.prefix(6))
            reference = tag
            events = { RunningAgentRunner.events(for: running, prompt: $0, reference: tag) }
        case .new:
            guard let executable = AgentEnvironment.shared.executable(for: agent) else {
                update(id) { $0.state = .failed("Couldn't find the `\(agent.executableName)` command. Install \(agent.displayName) or set its path in Settings.") }
                return
            }
            let session: SessionReference = sessions[agent].map { .resume($0) } ?? (settings.continueLatestSession ? .continueLatest : .new)
            let arguments = InvocationBuilder.arguments(agent: agent, mode: mode, session: session, model: settings.model(for: agent))
            let environment = AgentEnvironment.shared.environment
            // A new session hasn't seen the selection, whatever an earlier failed run did.
            if sessions[agent] == nil { briefedTargets.remove(target.id) }
            events = { Self.headlessEvents(agent: agent, executable: executable, arguments: arguments, prompt: $0,
                                           directory: directory, environment: environment) }
        }
        if briefs { briefedTargets.insert(target.id) }

        task = Task {
            var unsaved = hasUnsavedChanges
            if mode == .change, settings.saveBeforeChange {
                if review {
                    update(id) { $0.activities.append("Saving all files in Xcode") }
                    if let xcode = XcodeAccessibility.runningXcode, XcodeAccessibility.saveAllDocuments(of: xcode) { try? await Task.sleep(for: .milliseconds(400)) }
                } else if unsaved {
                    update(id) { $0.activities.append("Saving \(self.selection.fileName) in Xcode") }
                    unsaved = await saveInXcode() == false
                }
            }
            let prompt = makePrompt(unsaved, reference)
            var finished = false
            let before = mode == .change ? await Self.snapshot(directory) : nil
            do {
                for try await event in events(prompt) {
                    apply(event, to: id, agent: agent, finished: &finished)
                }
                if Task.isCancelled {
                    update(id) { $0.state = .stopped }
                } else if !finished {
                    update(id) { $0.state = $0.reply.isEmpty ? .failed("The agent ended without replying.") : .done }
                }
            } catch {
                let stopped = Task.isCancelled
                update(id) { $0.state = stopped ? .stopped : .failed(error.localizedDescription) }
            }
            // Catches edits made through shell commands, which produce no tool events.
            if let before, let after = await Self.snapshot(directory) {
                for path in after.changedFiles(since: before) {
                    addChangedFile(path.hasPrefix("/") ? path : directory.appendingPathComponent(path).path, to: id)
                }
            }
            task = nil
        }
    }

    /// Runs a new non-interactive agent process and parses its output into events.
    nonisolated private static func headlessEvents(agent: AgentKind, executable: String, arguments: [String], prompt: String,
                                                   directory: URL, environment: [String: String]) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                var parser = AgentParsers.make(for: agent)
                do {
                    for try await line in AgentProcess.lines(executable: executable, arguments: arguments, input: prompt,
                                                             directory: directory, environment: environment) {
                        for event in parser.consume(line) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Adds a finished turn without running an agent; used to render previews.
    func appendPreviewTurn(_ turn: Turn) {
        turns.append(turn)
    }

    func stop() {
        task?.cancel()
    }

    /// Forget agent sessions so the next question starts fresh with the selection.
    func reset() {
        stop()
        turns.removeAll()
        sessions.removeAll()
        briefedTargets.removeAll()
    }

    func absolutePath(_ path: String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : workingDirectory.appendingPathComponent(path)
    }

    func displayPath(_ path: String) -> String {
        ProjectLocator.relativePath(of: absolutePath(path), in: workingDirectory)
    }

    private func apply(_ event: AgentEvent, to id: UUID, agent: AgentKind, finished: inout Bool) {
        // Events for a turn removed by "New conversation" are dropped, sessions included.
        guard turns.contains(where: { $0.id == id }) else { return }
        switch event {
        case .session(let session): sessions[agent] = session
        case .text(let text): update(id) { $0.reply += text }
        case .activity(let activity): update(id) { $0.activities.append(activity) }
        case .notice(let notice): update(id) { $0.notices.append(notice) }
        case .fileChanged(let path): addChangedFile(path, to: id)
        case .completed:
            finished = true
            update(id) { $0.state = .done }
        case .failed(let reason):
            finished = true
            update(id) { $0.state = .failed(reason) }
        }
    }

    private func update(_ id: UUID, _ change: (inout Turn) -> Void) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        change(&turns[index])
    }

    /// Stores paths relative to the working directory so event and git paths don't duplicate.
    private func addChangedFile(_ path: String, to id: UUID) {
        let relative = displayPath(path)
        update(id) { if !$0.changedFiles.contains(relative) { $0.changedFiles.append(relative) } }
    }

    @concurrent private static func snapshot(_ directory: URL) async -> WorkingTreeSnapshot? {
        WorkingTreeSnapshot.capture(in: directory)
    }

    private var hasUnsavedChanges: Bool {
        guard let disk = try? String(contentsOf: selection.fileURL, encoding: .utf8) else { return false }
        return disk != selection.buffer
    }

    /// Saves the document in Xcode and waits until the file on disk matches the editor.
    private func saveInXcode() async -> Bool {
        guard XcodeAccessibility.saveFrontDocument(of: capture.xcode) else { return false }
        for _ in 0..<20 {
            if !hasUnsavedChanges { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return !hasUnsavedChanges
    }
}
