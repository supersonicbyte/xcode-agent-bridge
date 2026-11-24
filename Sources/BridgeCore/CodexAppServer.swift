import Foundation

/// A client for Codex's shared app-server daemon. Codex sessions started while the daemon runs
/// connect to it, so a turn started here appears in that session's terminal.
public final class CodexAppServer: @unchecked Sendable {
    public static var controlSocket: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/app-server-control/app-server-control.sock")
    }

    /// The daemon's socket, when the daemon is running.
    public static var socketPath: String? {
        let link = controlSocket.path
        guard FileManager.default.fileExists(atPath: link) else { return nil }
        return (link as NSString).resolvingSymlinksInPath
    }

    private let socket: UnixSocket
    private var buffer = Data()
    private var nextID = 0

    public init(path: String, clientName: String = "xcode-agent-bridge") throws {
        socket = try UnixSocket(path: path, timeout: 10)
        try handshake()
        _ = try call("initialize", ["clientInfo": ["name": clientName, "title": "Xcode Agent Bridge", "version": "0.1"]])
        try socket.write(WebSocketFrame.encode(text: Self.json(["method": "initialized"])))
    }

    @discardableResult
    public func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        nextID += 1
        let id = nextID
        try socket.write(WebSocketFrame.encode(text: Self.json(["id": id, "method": method, "params": params])))
        while true {
            let message = try receive()
            guard (message["id"] as? NSNumber)?.intValue == id else { continue } // notifications
            if let error = message["error"] as? [String: Any] {
                throw SocketError((error["message"] as? String) ?? "Codex returned an error for \(method).")
            }
            return message["result"] as? [String: Any] ?? [:]
        }
    }

    // MARK: - Sessions

    public func runningAgents() throws -> [RunningAgent] {
        let ids = (try call("thread/loaded/list", [:])["data"] as? [String]) ?? []
        return ids.compactMap { id in
            guard let thread = try? call("thread/read", ["threadId": id, "includeTurns": false])["thread"] as? [String: Any] else { return nil }
            let directory = thread["cwd"] as? String ?? ""
            let status = (thread["status"] as? [String: Any])?["type"] as? String ?? "idle"
            let name = [thread["name"] as? String, thread["preview"] as? String]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
                ?? "\((directory as NSString).lastPathComponent)-\(id.suffix(4))"
            let updated = (thread["updatedAt"] as? NSNumber)?.doubleValue ?? 0
            return RunningAgent(id: "codex:\(id)", agent: .codex, name: String(name.prefix(60)), directory: directory,
                                isBusy: status == "active", updatedAt: Date(timeIntervalSince1970: updated), address: .codex(threadID: id))
        }
    }

    /// Starts a turn on a session and returns the turn's ID.
    public func startTurn(threadID: String, text: String) throws -> String {
        _ = try? call("thread/resume", ["threadId": threadID, "excludeTurns": true])
        let result = try call("turn/start", ["threadId": threadID, "input": [["type": "text", "text": text]]])
        guard let turn = (result["turn"] as? [String: Any])?["id"] as? String else {
            throw SocketError("Codex didn't start a turn.")
        }
        return turn
    }

    /// The turn's status and items, or nil when the turn isn't listed yet.
    public func turn(threadID: String, turnID: String) throws -> (status: String, items: [[String: Any]], error: String?)? {
        let turns = (try call("thread/turns/list", ["threadId": threadID])["data"] as? [[String: Any]]) ?? []
        guard let turn = turns.last(where: { $0["id"] as? String == turnID }) else { return nil }
        let error = (turn["error"] as? [String: Any])?["message"] as? String
        return (turn["status"] as? String ?? "inProgress", turn["items"] as? [[String: Any]] ?? [], error)
    }

    // MARK: - WebSocket transport

    private func handshake() throws {
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let request = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        try socket.write(Data(request.utf8))
        let end = Data("\r\n\r\n".utf8)
        while buffer.range(of: end) == nil {
            let chunk = try socket.read()
            guard !chunk.isEmpty else { throw SocketError("Codex closed the connection during the handshake.") }
            buffer.append(chunk)
        }
        let range = buffer.range(of: end)!
        let head = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
        buffer.removeSubrange(buffer.startIndex..<range.upperBound)
        guard head.hasPrefix("HTTP/1.1 101") else { throw SocketError("Codex refused the connection: \(head.prefix(80))") }
    }

    private func receive() throws -> [String: Any] {
        while true {
            if let (frame, used) = WebSocketFrame.decode(buffer) {
                buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + used))
                switch frame.opcode {
                case 0x1, 0x2:
                    if let object = (try? JSONSerialization.jsonObject(with: frame.payload)) as? [String: Any] { return object }
                case 0x8:
                    throw SocketError("Codex closed the connection.")
                case 0x9:
                    try socket.write(WebSocketFrame.encode(payload: frame.payload, opcode: 0xA))
                default:
                    break
                }
                continue
            }
            let chunk = try socket.read()
            guard !chunk.isEmpty else { throw SocketError("Codex closed the connection.") }
            buffer.append(chunk)
        }
    }

    private static func json(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
    }
}

/// Minimal RFC 6455 framing: client frames are masked, server frames are not.
public enum WebSocketFrame {
    public static func encode(text: String) -> Data {
        encode(payload: Data(text.utf8), opcode: 0x1)
    }

    public static func encode(payload: Data, opcode: UInt8, mask: [UInt8] = (0..<4).map { _ in UInt8.random(in: 0...255) }) -> Data {
        var frame = Data([0x80 | opcode])
        let count = payload.count
        if count < 126 {
            frame.append(0x80 | UInt8(count))
        } else if count <= 0xFFFF {
            frame.append(0x80 | 126)
            frame.append(contentsOf: [UInt8(count >> 8), UInt8(count & 0xFF)])
        } else {
            frame.append(0x80 | 127)
            frame.append(contentsOf: (0..<8).reversed().map { UInt8((UInt64(count) >> (UInt64($0) * 8)) & 0xFF) })
        }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return frame
    }

    /// Decodes one frame from the start of `data`, returning it and the number of bytes used.
    public static func decode(_ data: Data) -> (frame: (opcode: UInt8, payload: Data), used: Int)? {
        let bytes = [UInt8](data.prefix(14))
        guard bytes.count >= 2 else { return nil }
        let opcode = bytes[0] & 0x0F
        let masked = bytes[1] & 0x80 != 0
        var length = Int(bytes[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[2]) << 8 | Int(bytes[3])
            offset = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            length = (2..<10).reduce(0) { $0 << 8 | Int(bytes[$1]) }
            offset = 10
        }
        var mask: [UInt8] = []
        if masked {
            guard bytes.count >= offset + 4 else { return nil }
            mask = Array(bytes[offset..<(offset + 4)])
            offset += 4
        }
        guard data.count >= offset + length else { return nil }
        let start = data.startIndex + offset
        var payload = Data(data[start..<(start + length)])
        if masked { payload = Data(payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }) }
        return ((opcode, payload), offset + length)
    }
}

/// Turns successive snapshots of a Codex turn into events, emitting only what is new.
public struct CodexTurnTracker {
    private var announced: Set<String> = []
    private var messageLengths: [String: Int] = [:]
    private var wroteText = false

    public init() {}

    public mutating func events(items: [[String: Any]], status: String, error: String?) -> [AgentEvent] {
        var events: [AgentEvent] = []
        for item in items {
            let id = item["id"] as? String ?? UUID().uuidString
            switch item["type"] as? String {
            case "agentMessage":
                let text = item["text"] as? String ?? ""
                let seen = messageLengths[id] ?? 0
                guard text.count > seen else { continue }
                if seen == 0, wroteText { events.append(.text("\n\n")) }
                events.append(.text(String(text.dropFirst(seen))))
                messageLengths[id] = text.count
                wroteText = true
            case "commandExecution":
                if announced.insert(id).inserted {
                    events.append(.activity("Running `\(CodexStreamParser.unwrapShell(item["command"] as? String ?? ""))`"))
                }
            case "fileChange":
                guard item["status"] as? String == "completed", announced.insert(id).inserted else { continue }
                for change in item["changes"] as? [[String: Any]] ?? [] {
                    if let path = change["path"] as? String { events.append(.fileChanged(path)) }
                }
            case "mcpToolCall":
                if announced.insert(id).inserted {
                    let name = [item["server"], item["tool"]].compactMap { $0 as? String }.joined(separator: ".")
                    events.append(.activity("Using \(name.isEmpty ? "a tool" : name)"))
                }
            case "webSearch":
                if announced.insert(id).inserted { events.append(.activity("Searching the web")) }
            default:
                continue
            }
        }
        switch status {
        case "completed": events.append(.completed)
        case "failed": events.append(.failed(error ?? "Codex reported an error."))
        case "interrupted": events.append(.failed("The turn was interrupted in Codex."))
        default: break
        }
        return events
    }
}
