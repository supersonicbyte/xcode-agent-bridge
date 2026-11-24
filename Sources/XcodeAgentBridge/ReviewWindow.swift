import AppKit
import SwiftUI
import BridgeCore

/// The state of the Pending Comments window: where the comments go, and the replies.
@Observable final class ReviewModel {
    var target = AgentTarget.new(AppSettings.shared.agent)
    var pickedTarget = false
    var mode = RequestMode.change
    var project = ""
    var conversation = Conversation(reviewIn: URL(fileURLWithPath: NSHomeDirectory()))

    func pick(_ target: AgentTarget) {
        self.target = target
        pickedTarget = true
    }

    func updateTarget(running: [RunningAgent]) {
        if case .running(let current) = target, let fresh = running.first(where: { $0.id == current.id }) {
            target = .running(fresh)
            return
        }
        if pickedTarget, case .running = target, conversation.isRunning { return }
        if case .running = target { pickedTarget = false }
        guard !pickedTarget else { return }
        target = AgentTarget.preferred(running: running, project: project)
    }

    func sendAll() {
        let queue = CommentQueue.shared
        guard !conversation.isRunning, !queue.isEmpty else { return }
        queue.finishEditing(save: true)
        let comments = queue.takeAll()
        let directories = Set(comments.map(\.workingDirectory))
        if let directory = directories.first, directories.count == 1, directory != conversation.workingDirectory.path {
            conversation = Conversation(reviewIn: URL(fileURLWithPath: directory))
        }
        conversation.sendReview(comments, mode: mode, target: target)
    }
}

/// A normal window listing every pending comment, grouped by file, with Send all.
final class ReviewWindowController: NSObject, NSWindowDelegate {
    static let shared = ReviewWindowController()

    let model = ReviewModel()
    private var window: NSWindow?
    private var refreshTask: Task<Void, Never>?

    /// Opens the window. The panel's target and mode carry over unless a send is in progress.
    func show(project: String? = nil, target: AgentTarget? = nil, mode: RequestMode? = nil) {
        if !model.conversation.isRunning {
            if let project { model.project = project }
            else if let first = CommentQueue.shared.comments.first { model.project = first.workingDirectory }
            if let target {
                model.target = target
                model.pickedTarget = true
            }
            if let mode { model.mode = mode }
        }
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        startRefreshing()
    }

    func close() {
        window?.performClose(nil)
    }

    func windowWillClose(_ notification: Notification) {
        refreshTask?.cancel()
        refreshTask = nil
        CommentQueue.shared.finishEditing(save: false)
    }

    private func startRefreshing() {
        refreshTask?.cancel()
        refreshTask = Task { [model] in
            while !Task.isCancelled {
                await RunningAgents.shared.refresh()
                model.updateTarget(running: RunningAgents.shared.agents)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Pending Comments"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 320)
        window.contentViewController = NSHostingController(rootView: ReviewView(model: model, close: { [weak self] in self?.close() }))
        window.setContentSize(NSSize(width: 620, height: 560))
        window.center()
        window.setFrameAutosaveName("PendingComments")
        window.delegate = self
        return window
    }
}

struct ReviewView: View {
    @Bindable var model: ReviewModel
    let close: () -> Void
    @Bindable private var queue = CommentQueue.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if queue.isEmpty && model.conversation.turns.isEmpty { emptyState }
                        ForEach(groups, id: \.path) { group in fileSection(group.path, group.comments) }
                        if !model.conversation.turns.isEmpty { sent }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.conversation.turns.last?.reply) { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: model.conversation.turns.count) { proxy.scrollTo("end", anchor: .bottom) }
            }
            Divider()
            footer
        }
        .frame(minWidth: 480, minHeight: 320)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.snappy(duration: 0.2), value: queue.comments)
        .onExitCommand { if queue.editingComment != nil { queue.finishEditing(save: false) } }
        .background {
            ZStack {
                Button("Send all") { if queue.editingComment != nil { queue.finishEditing(save: true) } else { model.sendAll() } }
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Close", action: close).keyboardShortcut("w", modifiers: .command)
                Button("Ask") { model.mode = .ask }.keyboardShortcut("1", modifiers: .command)
                Button("Change") { model.mode = .change }.keyboardShortcut("2", modifiers: .command)
            }
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var groups: [(path: String, comments: [ReviewComment])] {
        var result: [(path: String, comments: [ReviewComment])] = []
        for comment in PromptBuilder.sortedForReview(queue.comments) {
            if result.last?.path == comment.relativePath { result[result.count - 1].comments.append(comment) }
            else { result.append((comment.relativePath, [comment])) }
        }
        return result
    }

    private var header: some View {
        HStack(spacing: 8) {
            let files = Set(queue.comments.map(\.filePath)).count
            Text(queue.isEmpty ? "No pending comments" : "\(queue.comments.count) pending comment\(queue.comments.count == 1 ? "" : "s")")
                .font(.system(size: 13, weight: .semibold))
            if files > 1 { Text("in \(files) files").font(.system(size: 12)).foregroundStyle(.secondary) }
            Spacer(minLength: 8)
            Text("Send to").font(.system(size: 11)).foregroundStyle(.secondary)
            TargetMenu(target: model.target, project: model.project, pick: model.pick)
        }
        .padding(.leading, 80) // clear the window buttons
        .padding(.trailing, 14)
        .frame(height: 38)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.bubble").font(.system(size: 28)).foregroundStyle(.tertiary)
            Text("No pending comments").font(.system(size: 13, weight: .semibold))
            Text("Select code in Xcode, press ⌃⌥Space, write a comment and press ⌘⏎.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func fileSection(_ path: String, _ comments: [ReviewComment]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if let first = comments.first { PanelManager.shared.reveal(first) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(accent)
                    Text(path).font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1).truncationMode(.head)
                    Text("\(comments.count)").font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
            }
            .buttonStyle(.plain)
            .help("Open in Xcode")
            ForEach(comments) { comment in
                VStack(alignment: .leading, spacing: 0) {
                    CommentSnippet(comment: comment)
                    CommentCard(comment: comment, showsLocation: false)
                        .padding(8)
                }
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
            }
        }
    }

    private var sent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SENT").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            ForEach(model.conversation.turns) { turn in
                TurnView(turn: turn, conversation: model.conversation)
                    .padding(12)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Picker("Mode", selection: $model.mode) {
                Text("Ask").tag(RequestMode.ask)
                Text("Change").tag(RequestMode.change)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Text(model.mode == .change ? "Edits files for each comment" : "Answers each comment")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if model.conversation.isRunning {
                Button("Stop watching") { model.conversation.stop() }
            }
            Button("Discard all") { queue.clear() }
                .disabled(queue.isEmpty)
            Button(action: model.sendAll) {
                Text(model.mode == .change ? "Make all changes" : "Send all").fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.mode == .change ? .orange : accent)
            .disabled(queue.isEmpty || model.conversation.isRunning)
            .help("Send every comment as one message (⌘⏎)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// The commented lines, with line numbers, above a comment in the list.
private struct CommentSnippet: View {
    let comment: ReviewComment

    var body: some View {
        let lines = comment.code.components(separatedBy: "\n")
        let start = comment.codeStartLine ?? comment.firstLine
        let limit = 6
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.prefix(limit).enumerated()), id: \.offset) { offset, line in
                let number = start + offset
                let commented = (comment.firstLine...comment.lastLine).contains(number)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(number)").foregroundStyle(.tertiary).frame(minWidth: 30, alignment: .trailing)
                    Text(line.isEmpty ? " " : line).lineLimit(1)
                        .foregroundStyle(commented ? .primary : .secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(commented && comment.codeStartLine != nil ? accent.opacity(0.12) : .clear)
            }
            if lines.count > limit {
                Text("+\(lines.count - limit) more line\(lines.count - limit == 1 ? "" : "s")")
                    .foregroundStyle(.tertiary).padding(.leading, 40)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .contentShape(Rectangle())
        .onTapGesture { PanelManager.shared.reveal(comment) }
        .help("Open in Xcode")
    }
}
