import Foundation
import BridgeCore

/// Where a question goes: a session that's already running, or a new one the app starts.
enum AgentTarget: Hashable {
    case new(AgentKind)
    case running(RunningAgent)

    var agent: AgentKind {
        switch self {
        case .new(let agent): agent
        case .running(let running): running.agent
        }
    }

    var label: String {
        switch self {
        case .new(let agent): "New \(agent.shortName)"
        case .running(let running): "\(running.agent.shortName) · \(running.name)"
        }
    }

    /// A running session in the project when that's preferred and there is one, else a new session.
    static func preferred(running: [RunningAgent], project: String) -> AgentTarget {
        if AppSettings.shared.preferRunningSessions,
           let best = RunningAgent.sorted(running, for: project).first(where: { $0.relevance(to: project) > 0 }) {
            return .running(best)
        }
        return .new(AppSettings.shared.agent)
    }

    var isRunning: Bool {
        if case .running = self { true } else { false }
    }

    var id: String {
        switch self {
        case .new(let agent): "new:\(agent.rawValue)"
        case .running(let running): running.id
        }
    }
}

/// The agent sessions currently running on this Mac.
@Observable final class RunningAgents {
    static let shared = RunningAgents()

    private(set) var agents: [RunningAgent] = []
    private(set) var codexServerRunning = false
    private(set) var startingCodexServer = false
    private(set) var codexServerMessage: String?

    func refresh() async {
        let (agents, running) = await Self.scan()
        self.agents = agents
        codexServerRunning = running
    }

    /// Starts Codex's shared background server. Codex sessions started afterwards join it
    /// and can then receive questions; sessions that are already open can't.
    func startCodexServer() async {
        guard let codex = AgentEnvironment.shared.executable(for: .codex) else {
            codexServerMessage = "Couldn't find the `codex` command."
            return
        }
        startingCodexServer = true
        let environment = AgentEnvironment.shared.environment
        let succeeded = await Self.run(codex, ["app-server", "daemon", "start"], environment: environment)
        startingCodexServer = false
        codexServerMessage = succeeded
            ? "Codex's background server is running. Codex sessions you start from now on will show up here."
            : "Codex couldn't start its background server. Try `codex app-server daemon start` in a terminal."
        await refresh()
    }

    @concurrent private static func scan() async -> ([RunningAgent], Bool) {
        var agents = ClaudeSessions.runningAgents()
        var codexRunning = false
        if let path = CodexAppServer.socketPath, let server = try? CodexAppServer(path: path) {
            codexRunning = true
            agents += (try? server.runningAgents()) ?? []
        }
        return (agents, codexRunning)
    }

    @concurrent private static func run(_ executable: String, _ arguments: [String], environment: [String: String]) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

/// Sends a question to a running session and reports what the agent does with it.
nonisolated enum RunningAgentRunner {
    static func events(for agent: RunningAgent, prompt: String, reference: String) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    switch agent.address {
                    case .claude(let pid, let socket):
                        try await followClaude(agent, pid: pid, socket: socket, prompt: prompt, reference: reference, continuation)
                    case .codex(let threadID):
                        try await followCodex(agent, threadID: threadID, prompt: prompt, continuation)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Delivers the message to the session's socket, then reads the reply from its transcript
    /// until the session goes idle again.
    private static func followClaude(_ agent: RunningAgent, pid: Int32, socket: String, prompt: String, reference: String,
                                     _ continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation) async throws {
        guard let entry = ClaudeSessions.entry(pid: pid) else { throw SocketError("That Claude session has ended.") }
        var sessionID = entry.sessionID
        var transcript = ClaudeSessions.transcript(sessionID: sessionID)
        var offset = transcript.map(fileSize) ?? 0
        try ClaudeSessions.send(prompt, toSocket: socket)
        continuation.yield(.activity("Sent to \(agent.name)"))

        var follower = TranscriptFollower(marker: "ref \(reference)")
        var parser = ClaudeStreamParser()
        var sawOutput = false, idlePolls = 0, warned = false
        let sent = Date()
        while true {
            try await Task.sleep(for: .milliseconds(350))
            guard let current = ClaudeSessions.entry(pid: pid) else {
                if follower.started { continuation.yield(.completed); return }
                throw SocketError("That Claude session ended before it read the message.")
            }
            if current.sessionID != sessionID {
                sessionID = current.sessionID
                transcript = nil
                offset = 0
            }
            if transcript == nil { transcript = ClaudeSessions.transcript(sessionID: sessionID) }
            if let transcript {
                let size = fileSize(transcript)
                if size < offset { offset = 0 }
                if size > offset, let handle = try? FileHandle(forReadingFrom: transcript) {
                    try? handle.seek(toOffset: offset)
                    let data = handle.readDataToEndOfFile()
                    try? handle.close()
                    offset += UInt64(data.count)
                    for line in follower.consume(data) {
                        if line.contains("\"type\":\"assistant\"") { sawOutput = true }
                        for event in parser.consume(line) {
                            switch event {
                            case .session, .completed: continue
                            default: continuation.yield(event)
                            }
                        }
                    }
                }
            }
            if follower.started {
                idlePolls = current.status == "idle" ? idlePolls + 1 : 0
                if idlePolls >= (sawOutput ? 3 : 15) {
                    continuation.yield(.completed)
                    return
                }
            } else if !warned, current.status == "idle", Date().timeIntervalSince(sent) > 6 {
                warned = true
                continuation.yield(.notice("\(agent.name) hasn't picked this up yet. Its terminal may be asking you to approve a message from another session. To skip that, add \"crossSessionInbound\": \"accept\" to Claude's settings."))
            }
        }
    }

    private static func followCodex(_ agent: RunningAgent, threadID: String, prompt: String,
                                    _ continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation) async throws {
        guard let path = CodexAppServer.socketPath else { throw SocketError("Codex's background server isn't running.") }
        let server = try CodexAppServer(path: path)
        let turnID = try server.startTurn(threadID: threadID, text: prompt)
        continuation.yield(.activity("Sent to \(agent.name)"))
        var tracker = CodexTurnTracker()
        while true {
            try await Task.sleep(for: .milliseconds(600))
            guard let turn = try server.turn(threadID: threadID, turnID: turnID) else { continue }
            for event in tracker.events(items: turn.items, status: turn.status, error: turn.error) {
                continuation.yield(event)
                switch event {
                case .completed, .failed: return
                default: continue
                }
            }
        }
    }

    private static func fileSize(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
