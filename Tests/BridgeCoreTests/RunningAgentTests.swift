import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#endif
@testable import BridgeCore

private func temporaryDirectory(_ name: String) throws -> URL {
    let url = URL(fileURLWithPath: "/tmp").appendingPathComponent("xab-\(name)-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func claudeRegistryListsLiveInteractiveSessions() throws {
    let registry = try temporaryDirectory("registry")
    defer { try? FileManager.default.removeItem(at: registry) }
    let socket = registry.appendingPathComponent("s.sock")
    FileManager.default.createFile(atPath: socket.path, contents: nil)
    func write(_ name: String, _ object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: registry.appendingPathComponent(name))
    }
    let me = getpid()
    try write("1.json", ["pid": me, "sessionId": "a", "cwd": "/repo/app", "name": "app-1", "status": "busy",
                         "kind": "interactive", "messagingSocketPath": socket.path, "updatedAt": 2_000])
    try write("2.json", ["pid": 999_999, "sessionId": "dead", "cwd": "/repo", "kind": "interactive",
                         "messagingSocketPath": socket.path])
    try write("3.json", ["pid": me, "sessionId": "headless", "cwd": "/repo", "kind": "print", "messagingSocketPath": socket.path])
    try write("4.json", ["pid": me, "sessionId": "nosocket", "cwd": "/repo", "kind": "interactive", "messagingSocketPath": "/nonexistent.sock"])
    try "not json".write(to: registry.appendingPathComponent("5.json"), atomically: true, encoding: .utf8)

    let agents = ClaudeSessions.runningAgents(in: registry)
    #expect(agents.count == 1)
    let agent = try #require(agents.first)
    #expect(agent.name == "app-1" && agent.isBusy && agent.directory == "/repo/app")
    #expect(agent.address == .claude(pid: me, socket: socket.path))
    #expect(ClaudeSessions.entries(in: registry).map(\.sessionID).sorted() == ["a", "headless"])
}

@Test func runningAgentsSortByProjectThenIdleThenRecent() {
    func agent(_ name: String, _ directory: String, busy: Bool, age: TimeInterval) -> RunningAgent {
        RunningAgent(id: name, agent: .claude, name: name, directory: directory, isBusy: busy,
                     updatedAt: Date(timeIntervalSince1970: 1_000 - age), address: .codex(threadID: name))
    }
    let agents = [
        agent("other", "/elsewhere", busy: false, age: 0),
        agent("parent", "/repo", busy: false, age: 5),
        agent("exact-busy", "/repo/app", busy: true, age: 0),
        agent("exact-idle", "/repo/app", busy: false, age: 50),
    ]
    #expect(RunningAgent.sorted(agents, for: "/repo/app").map(\.name) == ["exact-idle", "exact-busy", "parent", "other"])
    #expect(agents[1].relevance(to: "/repo/app") == 1 && agents[0].relevance(to: "/repo/app") == 0)
    #expect(agent("x", "/repo/application", busy: false, age: 0).relevance(to: "/repo/app") == 0)
}

@Test func claudeMessageReachesSocket() throws {
    let directory = try temporaryDirectory("sock")
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("s.sock").path
    let server = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        let bytes = Array(path.utf8)
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    #expect(bound == 0)
    listen(server, 1)
    defer { close(server) }

    try ClaudeSessions.send("Explain line 4", toSocket: path)
    let client = accept(server, nil, nil)
    defer { close(client) }
    var buffer = [UInt8](repeating: 0, count: 4096)
    let count = recv(client, &buffer, buffer.count, 0)
    let line = String(decoding: buffer.prefix(max(0, count)), as: UTF8.self)
    #expect(line.hasSuffix("\n"))
    let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    let message = try #require(object["message"] as? [String: Any])
    #expect(object["type"] as? String == "user" && message["role"] as? String == "user" && message["content"] as? String == "Explain line 4")
    #expect(throws: SocketError.self) { try ClaudeSessions.send("x", toSocket: directory.appendingPathComponent("missing.sock").path) }
}

@Test func transcriptFollowerStartsAtDeliveredMessage() throws {
    let marker = PromptBuilder.referenceLine("AB12")
    var follower = TranscriptFollower(marker: "ref AB12")
    let queued = #"{"type":"queue-operation","operation":"enqueue","content":"question \#(marker)"}"#
    let earlier = #"{"type":"assistant","message":{"content":[{"type":"text","text":"still busy with the old task"}]}}"#
    let delivered = #"{"type":"attachment","attachment":{"type":"queued_command","prompt":"question \#(marker)"}}"#
    let reply = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Here is the answer"}]}}"#
    // Lines can arrive split across reads.
    let all = Data([queued, earlier, delivered, reply].joined(separator: "\n").utf8) + Data("\n".utf8)
    let first = follower.consume(all.prefix(all.count - 20))
    #expect(first.isEmpty && follower.started)
    let rest = follower.consume(all.suffix(20))
    #expect(rest == [reply])
    var parser = ClaudeStreamParser()
    #expect(rest.flatMap { parser.consume($0) } == [.text("Here is the answer")])

    let projects = try temporaryDirectory("projects")
    defer { try? FileManager.default.removeItem(at: projects) }
    try FileManager.default.createDirectory(at: projects.appendingPathComponent("-repo-app"), withIntermediateDirectories: true)
    let file = projects.appendingPathComponent("-repo-app/sid.jsonl")
    FileManager.default.createFile(atPath: file.path, contents: nil)
    #expect(ClaudeSessions.transcript(sessionID: "sid", projects: projects)?.lastPathComponent == "sid.jsonl")
    #expect(ClaudeSessions.transcript(sessionID: "other", projects: projects) == nil)
}

@Test func webSocketFramesRoundTrip() throws {
    for size in [5, 300, 70_000] {
        let payload = Data(repeating: 0x41, count: size)
        let encoded = WebSocketFrame.encode(payload: payload, opcode: 0x1, mask: [1, 2, 3, 4])
        let decoded = try #require(WebSocketFrame.decode(encoded + Data([0x81])))
        #expect(decoded.frame.opcode == 0x1 && decoded.frame.payload == payload && decoded.used == encoded.count)
        #expect(WebSocketFrame.decode(encoded.prefix(encoded.count - 1)) == nil)
    }
    // Server frames are unmasked.
    let server = Data([0x81, 0x02]) + Data("{}".utf8)
    #expect(WebSocketFrame.decode(server)?.frame.payload == Data("{}".utf8))
}

@Test func codexTurnTrackerEmitsOnlyNewEvents() {
    var tracker = CodexTurnTracker()
    let user: [String: Any] = ["type": "userMessage", "id": "u"]
    var message: [String: Any] = ["type": "agentMessage", "id": "m1", "text": "Reading"]
    let command: [String: Any] = ["type": "commandExecution", "id": "c1", "command": "/bin/zsh -lc 'cat a.swift'"]
    #expect(tracker.events(items: [user, message, command], status: "inProgress", error: nil) ==
            [.text("Reading"), .activity("Running `cat a.swift`")])
    message["text"] = "Reading the file."
    let change: [String: Any] = ["type": "fileChange", "id": "f1", "status": "completed", "changes": [["path": "/repo/a.swift"]]]
    let final: [String: Any] = ["type": "agentMessage", "id": "m2", "text": "Done."]
    #expect(tracker.events(items: [user, message, command, change, final], status: "completed", error: nil) ==
            [.text(" the file."), .fileChanged("/repo/a.swift"), .text("\n\n"), .text("Done."), .completed])
    var failing = CodexTurnTracker()
    #expect(failing.events(items: [], status: "failed", error: "Usage limit reached") == [.failed("Usage limit reached")])
}

@Test func promptCarriesReference() {
    let prompt = PromptBuilder.prompt(request: "Why?", mode: .ask, context: nil, reference: "ZX9")
    #expect(prompt.hasSuffix("(Sent from Xcode by xcode-agent-bridge · ref ZX9)"))
}
