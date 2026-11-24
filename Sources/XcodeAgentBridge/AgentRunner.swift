import Foundation
import BridgeCore

/// Finds agent executables and the environment to run them in.
@Observable final class AgentEnvironment {
    static let shared = AgentEnvironment()

    private(set) var searchPath: [String] = ShellEnvironment.searchPath(shellPath: nil, home: NSHomeDirectory())
    private(set) var isLoaded = false

    func load() async {
        let shellPath = await Self.loginShellPath()
        searchPath = ShellEnvironment.searchPath(shellPath: shellPath, home: NSHomeDirectory())
        isLoaded = true
    }

    func executable(for agent: AgentKind) -> String? {
        let override = AppSettings.shared.pathOverride(for: agent).trimmingCharacters(in: .whitespaces)
        return ShellEnvironment.resolve(override.isEmpty ? agent.executableName : override, in: searchPath)
    }

    var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath.joined(separator: ":")
        environment["TERM"] = "dumb"
        environment["NO_COLOR"] = "1"
        return environment
    }

    /// Asks the user's login shell for PATH, so version managers and installers that edit
    /// shell startup files are respected.
    @concurrent private static func loginShellPath() async -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", ShellEnvironment.probeCommand]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        return ShellEnvironment.parsePath(fromShellOutput: String(decoding: data, as: UTF8.self))
    }
}

nonisolated struct AgentProcessError: LocalizedError {
    var status: Int32
    var output: String
    var errorDescription: String? {
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "The agent exited with status \(status)." : detail
    }
}

/// Runs an agent and yields its standard output line by line. Cancelling the consuming
/// task terminates the process.
nonisolated enum AgentProcess {
    static func lines(executable: String, arguments: [String], input: String, directory: URL,
                      environment: [String: String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let running = RunningProcess()
            let process = running.process
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.environment = environment
            let output = Pipe(), stdin = Pipe()
            process.standardOutput = output
            process.standardInput = stdin
            // stderr goes to a file so a chatty agent can't block on a full pipe.
            let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent("xab-\(UUID().uuidString).log")
            FileManager.default.createFile(atPath: errorURL.path, contents: nil)
            guard let errorHandle = try? FileHandle(forWritingTo: errorURL) else {
                continuation.finish(throwing: CocoaError(.fileWriteUnknown))
                return
            }
            process.standardError = errorHandle
            do {
                try process.run()
            } catch {
                continuation.finish(throwing: error)
                return
            }
            let writer = stdin.fileHandleForWriting
            Task.detached {
                try? writer.write(contentsOf: Data(input.utf8))
                try? writer.close()
            }
            let reader = Task.detached {
                defer {
                    try? errorHandle.close()
                    try? FileManager.default.removeItem(at: errorURL)
                }
                do {
                    for try await line in output.fileHandleForReading.bytes.lines {
                        continuation.yield(line)
                    }
                    process.waitUntilExit()
                    if process.terminationStatus != 0, !running.cancelled {
                        let log = String(decoding: (try? Data(contentsOf: errorURL)) ?? Data(), as: UTF8.self)
                        continuation.finish(throwing: AgentProcessError(status: process.terminationStatus, output: String(log.suffix(2000))))
                    } else {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    running.cancelled = true
                    if process.isRunning { process.terminate() }
                    reader.cancel()
                }
            }
        }
    }
}

private nonisolated final class RunningProcess: @unchecked Sendable {
    let process = Process()
    var cancelled = false
}
