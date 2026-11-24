import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// An agent session that is already running somewhere, usually in a terminal.
public struct RunningAgent: Identifiable, Sendable, Hashable {
    public enum Address: Sendable, Hashable {
        case claude(pid: Int32, socket: String)
        case codex(threadID: String)
    }

    public var id: String
    public var agent: AgentKind
    public var name: String
    public var directory: String
    public var isBusy: Bool
    public var updatedAt: Date
    public var address: Address

    public init(id: String, agent: AgentKind, name: String, directory: String, isBusy: Bool, updatedAt: Date, address: Address) {
        self.id = id
        self.agent = agent
        self.name = name
        self.directory = directory
        self.isBusy = isBusy
        self.updatedAt = updatedAt
        self.address = address
    }

    /// How closely this session matches a project: 2 same folder, 1 nested either way, 0 unrelated.
    public func relevance(to project: String) -> Int {
        let mine = (directory as NSString).standardizingPath, theirs = (project as NSString).standardizingPath
        if mine == theirs { return 2 }
        if theirs.hasPrefix(mine + "/") || mine.hasPrefix(theirs + "/") { return 1 }
        return 0
    }

    /// Running sessions ordered for a project: matching folders first, then idle ones, then recent.
    public static func sorted(_ agents: [RunningAgent], for project: String?) -> [RunningAgent] {
        agents.sorted { a, b in
            let ra = project.map(a.relevance) ?? 0, rb = project.map(b.relevance) ?? 0
            if ra != rb { return ra > rb }
            if a.isBusy != b.isBusy { return !a.isBusy }
            return a.updatedAt > b.updatedAt
        }
    }
}

/// Interactive Claude Code sessions, found through Claude's session registry and reached
/// through each session's cross-session messaging socket.
public enum ClaudeSessions {
    public static var home: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude") }

    public struct Entry: Sendable, Equatable {
        public var pid: Int32
        public var sessionID: String
        public var directory: String
        public var name: String
        /// Whether the user chose the name. Claude leaves `nameSource` out for a chosen name and
        /// sets "derived" or "collision" when it made one up from the folder.
        public var nameIsChosen: Bool
        public var status: String
        public var socket: String
        public var kind: String
        public var updatedAt: Date
    }

    public static func entries(in registry: URL = home.appendingPathComponent("sessions"),
                               isAlive: (Int32) -> Bool = processIsAlive) -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: registry, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf: file),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let pid = (object["pid"] as? NSNumber)?.int32Value,
                  let socket = object["messagingSocketPath"] as? String,
                  let sessionID = object["sessionId"] as? String,
                  isAlive(pid), FileManager.default.fileExists(atPath: socket) else { return nil }
            let directory = object["cwd"] as? String ?? ""
            let updated = (object["updatedAt"] as? NSNumber)?.doubleValue ?? 0
            return Entry(pid: pid, sessionID: sessionID, directory: directory,
                         name: object["name"] as? String ?? (directory as NSString).lastPathComponent,
                         nameIsChosen: object["name"] is String && object["nameSource"] == nil,
                         status: object["status"] as? String ?? "idle", socket: socket,
                         kind: object["kind"] as? String ?? "interactive",
                         updatedAt: Date(timeIntervalSince1970: updated / 1000))
        }
    }

    public static func entry(pid: Int32, in registry: URL = home.appendingPathComponent("sessions")) -> Entry? {
        entries(in: registry).first { $0.pid == pid }
    }

    /// Sessions the user is working in. Headless `claude -p` runs also have sockets, but
    /// they finish on their own and nobody is watching them.
    public static func runningAgents(in registry: URL = home.appendingPathComponent("sessions")) -> [RunningAgent] {
        entries(in: registry).filter { $0.kind == "interactive" }.map { entry in
            RunningAgent(id: "claude:\(entry.pid)", agent: .claude, name: displayName(of: entry), directory: entry.directory,
                         isBusy: entry.status != "idle", updatedAt: entry.updatedAt,
                         address: .claude(pid: entry.pid, socket: entry.socket))
        }
    }

    /// The name Claude shows for a session: one the user gave it, else the title Claude wrote
    /// into the transcript, else the registry's folder-based name like "myapp-91".
    public static func displayName(of entry: Entry, projects: URL = home.appendingPathComponent("projects")) -> String {
        if entry.nameIsChosen { return entry.name }
        guard let transcript = transcript(sessionID: entry.sessionID, projects: projects),
              let title = title(inTranscript: transcript) else { return entry.name }
        return title
    }

    /// The latest custom title (from /rename), else the latest AI title, in a transcript.
    /// Only the end of the file is read; Claude writes the title again on every turn.
    public static func title(inTranscript url: URL, tailBytes: Int = 512 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        return title(inTranscriptText: String(decoding: data, as: UTF8.self))
    }

    static func title(inTranscriptText text: String) -> String? {
        var custom: String?, ai: String?
        for line in text.split(separator: "\n").reversed() {
            let isCustom = line.contains("\"type\":\"custom-title\""), isAI = line.contains("\"type\":\"ai-title\"")
            guard (isCustom && custom == nil) || (isAI && ai == nil),
                  let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            let value = (isCustom ? object["customTitle"] ?? object["title"] : object["aiTitle"]) as? String
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { continue }
            if isCustom { custom = value; break } else { ai = value }
        }
        return custom ?? ai
    }

    public static func processIsAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// One message line in the cross-session protocol. On macOS a session accepts it from any
    /// process of the same user; the receiving Claude sees it as a message from another session.
    public static func messageFrame(_ text: String) -> Data {
        let object: [String: Any] = ["type": "user", "message": ["role": "user", "content": text]]
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        data.append(0x0A)
        return data
    }

    public static func send(_ text: String, toSocket path: String) throws {
        let socket = try UnixSocket(path: path, timeout: 5)
        try socket.write(messageFrame(text))
        shutdown(socket.descriptor, SHUT_WR)
    }

    /// Claude keeps each conversation in ~/.claude/projects/<folder>/<session id>.jsonl.
    public static func transcript(sessionID: String, projects: URL = home.appendingPathComponent("projects")) -> URL? {
        let folders = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return folders.lazy.map { $0.appendingPathComponent(sessionID + ".jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// Finds where a message we sent shows up in a Claude transcript and passes on what follows.
/// The queue record written when the message arrives is skipped: if Claude was busy, the
/// lines after it still belong to the previous turn.
public struct TranscriptFollower {
    public let marker: String
    public private(set) var started = false
    private var partial = Data()

    public init(marker: String) {
        self.marker = marker
    }

    /// Feeds newly appended bytes and returns complete lines that come after the message.
    public mutating func consume(_ data: Data) -> [String] {
        partial.append(data)
        var lines: [String] = []
        while let newline = partial.firstIndex(of: 0x0A) {
            let line = String(decoding: partial[partial.startIndex..<newline], as: UTF8.self)
            partial.removeSubrange(partial.startIndex...newline)
            if started {
                lines.append(line)
            } else if line.contains(marker), !line.contains("\"queue-operation\"") {
                started = true
            }
        }
        return lines
    }
}
