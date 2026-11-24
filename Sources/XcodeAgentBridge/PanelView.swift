import AppKit
import SwiftUI
import BridgeCore

let accent = Color(nsColor: .systemTeal)

struct PanelView: View {
    @Bindable var model: PanelModel
    let close: () -> Void

    var body: some View {
        Group {
            switch model.content {
            case .message(let text, let needsAccessibility):
                MessageView(text: text, needsAccessibility: needsAccessibility, close: close)
            case .conversation(let conversation):
                // A fresh view per conversation: keyboard-shortcut buttons otherwise keep
                // actions bound to the first conversation shown.
                ConversationView(conversation: conversation, model: model, close: close)
                    .id(ObjectIdentifier(conversation))
            case nil:
                EmptyView()
            }
        }
        .frame(width: model.isKey || model.conversation == nil ? 580 : 460)
        .animation(.snappy(duration: 0.18), value: model.isKey)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onExitCommand(perform: close)
        .onChange(of: CommentQueue.shared.editingComment) { if $1 == nil { model.focusRequest += 1 } }
    }
}

private struct MessageView: View {
    let text: String
    let needsAccessibility: Bool
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: needsAccessibility ? "hand.raised.fill" : "info.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(needsAccessibility ? .orange : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(text).font(.system(size: 13))
                    if needsAccessibility {
                        Text("Turn on Xcode Agent Bridge in System Settings ▸ Privacy & Security ▸ Accessibility, then press the shortcut again.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Spacer()
                if needsAccessibility {
                    Button("Open Accessibility Settings") {
                        _ = XcodeAccessibility.isTrusted(prompt: true)
                        XcodeAccessibility.openAccessibilitySettings()
                    }
                }
                Button("Close", action: close).keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
    }
}

private struct ConversationView: View {
    let conversation: Conversation
    @Bindable var model: PanelModel
    @Bindable var settings = AppSettings.shared
    let close: () -> Void
    private let queue = CommentQueue.shared
    @FocusState private var inputFocused: Bool
    @State private var transcriptHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.isKey {
                CodePreview(selection: conversation.selection, compact: !conversation.turns.isEmpty)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
            commentsHere
            if !conversation.turns.isEmpty {
                Divider()
                transcript
            }
            // Panels not in use show only their comments and replies; click one to expand it.
            if model.isKey {
                Divider()
                if !queue.isEmpty {
                    pendingBar
                    Divider()
                }
                inputBar
            }
        }
        .background { shortcuts }
        .onAppear { inputFocused = true }
        .onChange(of: model.focusRequest) { inputFocused = true }
        .animation(.snappy(duration: 0.2), value: queue.comments)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
            Text(conversation.selection.fileName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Text(conversation.selection.lineLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize()
            Text((conversation.relativePath as NSString).deletingLastPathComponent)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 8)
            TargetMenu(target: model.target, project: conversation.workingDirectory.path, pick: model.pick)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(conversation.turns) { turn in
                        TurnView(turn: turn, conversation: conversation)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(12)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { transcriptHeight = $0 }
            }
            .frame(height: min(max(transcriptHeight, 44), model.isKey ? 460 : 200))
            .onChange(of: conversation.turns.last?.reply) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: conversation.turns.count) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    /// Comments on the selected code, shown under it like review comments on a pull request.
    @ViewBuilder private var commentsHere: some View {
        let here = queue.comments.filter { $0.matches(conversation.selection) }
        if !here.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(here) { comment in
                    CommentCard(comment: comment, showsLocation: false)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    /// How many comments are waiting, with a way to open the list of all of them.
    private var pendingBar: some View {
        let count = queue.comments.count
        let others = queue.comments.filter { !$0.matches(conversation.selection) }.count
        return HStack(spacing: 6) {
            Image(systemName: "text.bubble.fill").font(.system(size: 11)).foregroundStyle(accent)
            Text("\(count) pending comment\(count == 1 ? "" : "s")").font(.system(size: 11, weight: .semibold))
            if others > 0 {
                Text("· \(others) on other code").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(action: openReview) {
                Text("Review & send…").font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Open the list of all pending comments (⌘⇧⏎)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(accent.opacity(0.05))
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Picker("Mode", selection: $model.mode) {
                    Text("Ask").tag(RequestMode.ask)
                    Text("Change").tag(RequestMode.change)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                TextField(placeholder, text: $model.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .onSubmit(send)
                if !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(action: addComment) {
                        Image(systemName: "plus.bubble.fill").font(.system(size: 17))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Add as a comment and send it later with the others (⌘⏎)")
                }
                if conversation.isRunning {
                    Button(action: conversation.stop) {
                        Image(systemName: "stop.circle.fill").font(.system(size: 20))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Stop (⌘.)")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(canSend ? accent : Color.secondary.opacity(0.5))
                    .disabled(!canSend)
                    .help("Send (⏎)")
                }
            }
            Text(hint)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Invisible buttons that carry the panel's keyboard shortcuts.
    private var shortcuts: some View {
        ZStack {
            Button("Ask") { model.mode = .ask }.keyboardShortcut("1", modifiers: .command)
            Button("Change") { model.mode = .change }.keyboardShortcut("2", modifiers: .command)
            Button("Explain") { explain() }.keyboardShortcut("e", modifiers: .command)
            Button("Stop") { conversation.stop() }.keyboardShortcut(".", modifiers: .command)
            Button("New") { conversation.reset(); model.draft = "" }.keyboardShortcut("n", modifiers: .command)
            Button("Switch agent") { cycleTarget() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Close", action: close).keyboardShortcut("w", modifiers: .command)
            Button("Add comment") { addComment() }.keyboardShortcut(.return, modifiers: .command)
            Button("Review comments") { openReview() }.keyboardShortcut(.return, modifiers: [.command, .shift])
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var placeholder: String {
        switch model.mode {
        case .ask: conversation.turns.isEmpty ? "Ask, or comment and press ⌘⏎ to collect it — ⏎ alone explains" : "Ask a follow-up…"
        case .change: "Describe the change, or comment and press ⌘⏎ to collect it…"
        }
    }

    private var hint: String {
        if !queue.isEmpty {
            if queue.isEditing(on: conversation.selection) { return "⌘⏎ update comment · esc cancel" }
            return "⌘⏎ add comment · ⌘⇧⏎ review & send all \(queue.comments.count) · esc back to Xcode"
        }
        return switch model.mode {
        case .ask where model.target.isRunning: "⏎ send to \(model.target.label) · its terminal shows it too · ⌘⇧A switch · ⌘2 change · esc close"
        case .ask: "⏎ send · ⌘⏎ add comment · ⌘E explain · ⌘2 change · ⌘⇧A switch agent · esc close"
        case .change:
            switch model.target {
            case .running(let running): "\(running.name) makes the change with its own permissions · ⌘1 ask · ⌘. stop watching · esc close"
            case .new(let agent): "\(agent.shortName) will edit files in \(conversation.workingDirectory.lastPathComponent) · ⌘1 ask · ⌘. stop · esc close"
            }
        }
    }

    private var canSend: Bool {
        !conversation.isRunning && (model.mode == .ask || !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func send() {
        // ⌘⏎ adds a comment; the text field must not also treat it as a plain ⏎.
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true { return }
        guard canSend else { return }
        conversation.send(model.draft, mode: model.mode, target: model.target)
        model.draft = ""
    }

    /// Collects the draft as a pending comment on this selection. While a comment is being
    /// edited, ⌘⏎ saves the edit instead.
    private func addComment() {
        // Only an edit shown in this panel is saved by ⌘⏎; one left open elsewhere is dropped.
        if queue.isEditing(on: conversation.selection) {
            queue.finishEditing(save: true)
            return
        }
        queue.finishEditing(save: false)
        let text = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let comment = ReviewComment(selection: conversation.selection, workingDirectory: conversation.workingDirectory, text: text)
        queue.add(comment)
        model.draft = ""
        queue.flagAdded(comment.id)
    }

    /// Opens the window listing every pending comment. Text still being typed is added first.
    private func openReview() {
        if !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queue.add(ReviewComment(selection: conversation.selection, workingDirectory: conversation.workingDirectory, text: model.draft))
            model.draft = ""
        }
        ReviewWindowController.shared.show(project: conversation.workingDirectory.path, target: model.target, mode: model.mode)
    }

    private func explain() {
        guard !conversation.isRunning else { return }
        conversation.send("", mode: .ask, target: model.target)
    }

    private func cycleTarget() {
        let targets = model.targets(RunningAgents.shared.agents)
        let index = targets.firstIndex { $0.id == model.target.id } ?? -1
        model.pick(targets[(index + 1) % targets.count])
    }
}

/// Picks where the question goes: a running session (answers in its terminal and here) or a
/// new session the app starts (answers only here).
struct TargetMenu: View {
    let target: AgentTarget
    let project: String
    let pick: (AgentTarget) -> Void
    private let running = RunningAgents.shared

    var body: some View {
        Menu {
            let sessions = RunningAgent.sorted(running.agents, for: project)
            let here = sessions.filter { $0.relevance(to: project) > 0 }
            let elsewhere = sessions.filter { $0.relevance(to: project) == 0 }
            if !here.isEmpty {
                Section("Running in this project") { ForEach(here) { item($0) } }
            }
            if !elsewhere.isEmpty {
                Section("Running elsewhere") { ForEach(elsewhere) { item($0) } }
            }
            if sessions.isEmpty {
                Text("No running Claude or Codex sessions found")
            }
            Section("New session · answers only here") {
                ForEach(AgentKind.allCases) { agent in
                    Button {
                        pick(.new(agent))
                    } label: {
                        Label("New \(agent.displayName) session", systemImage: target == .new(agent) ? "checkmark" : "plus.bubble")
                    }
                }
            }
            if !running.codexServerRunning {
                Divider()
                Button(running.startingCodexServer ? "Starting Codex background server…" : "Reach running Codex sessions…") {
                    Task { await running.startCodexServer() }
                }
                .disabled(running.startingCodexServer)
            }
            if let message = running.codexServerMessage {
                Text(message)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(statusColor)
                Text(target.label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Where the question goes (⌘⇧A to switch). Running sessions answer in their terminal and here.")
    }

    private var statusColor: Color {
        switch target {
        case .running(let agent): agent.isBusy ? .orange : .green
        case .new: Color.secondary.opacity(0.6)
        }
    }

    private func item(_ agent: RunningAgent) -> some View {
        Button {
            pick(.running(agent))
        } label: {
            let folder = (agent.directory as NSString).abbreviatingWithTildeInPath
            let state = agent.isBusy ? "busy" : "idle"
            Label("\(agent.agent.shortName) · \(agent.name) — \(folder) · \(state)",
                  systemImage: target.id == agent.id ? "checkmark" : (agent.agent == .claude ? "terminal" : "chevron.left.forwardslash.chevron.right"))
        }
    }
}

private struct CodePreview: View {
    let selection: EditorSelection
    let compact: Bool

    var body: some View {
        let all = selection.code.components(separatedBy: "\n")
        let limit = compact ? 2 : 6
        let shown = Array(all.prefix(limit))
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(shown.enumerated()), id: \.offset) { offset, line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(selection.lines.lowerBound + offset)")
                        .foregroundStyle(.tertiary)
                        .frame(minWidth: 28, alignment: .trailing)
                    Text(line.isEmpty ? " " : line).lineLimit(1)
                }
            }
            if all.count > limit {
                Text("+\(all.count - limit) more line\(all.count - limit == 1 ? "" : "s")")
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 38)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if selection.isEmpty {
                Text("cursor line").font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary).padding(5)
            }
        }
    }
}

struct TurnView: View {
    let turn: Conversation.Turn
    let conversation: Conversation
    @State private var showSteps = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(turn.mode == .ask ? "ASK" : "CHANGE")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .foregroundStyle(turn.mode == .ask ? accent : .orange)
                    .background((turn.mode == .ask ? accent : Color.orange).opacity(0.15), in: Capsule())
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                Text(turn.target.label).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
            if !turn.comments.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(turn.comments.enumerated()), id: \.element.id) { index, comment in
                        CommentRow(comment: comment, number: index + 1)
                    }
                }
            }
            if turn.state == .running {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(turn.activities.last ?? (turn.reply.isEmpty ? "Thinking…" : "Writing…"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else if !turn.activities.isEmpty {
                DisclosureGroup(isExpanded: $showSteps) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(turn.activities.enumerated()), id: \.offset) { _, activity in
                            Text(activity).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("\(turn.activities.count) step\(turn.activities.count == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            if !turn.reply.isEmpty { ReplyView(text: turn.reply) }
            ForEach(Array(turn.notices.enumerated()), id: \.offset) { _, notice in
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            if !turn.changedFiles.isEmpty { changedFiles }
            switch turn.state {
            case .failed(let reason):
                Label(reason, systemImage: "xmark.octagon.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                if !turn.comments.isEmpty { restoreButton }
            case .stopped:
                Text(turn.target.isRunning ? "Stopped watching. The agent keeps going in its terminal." : "Stopped.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if !turn.comments.isEmpty, !turn.target.isRunning { restoreButton }
            case .done where !turn.reply.isEmpty:
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(turn.reply, forType: .string)
                } label: {
                    Label("Copy reply", systemImage: "doc.on.doc").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
    }

    private var title: String {
        if !turn.comments.isEmpty {
            let files = Set(turn.comments.map(\.filePath)).count
            return "\(turn.comments.count) comment\(turn.comments.count == 1 ? "" : "s")" + (files > 1 ? " in \(files) files" : "")
        }
        return turn.request.isEmpty ? "Explain this code" : turn.request
    }

    private var restoreButton: some View {
        Button {
            CommentQueue.shared.restore(turn.comments)
        } label: {
            Label("Put the comments back to send again", systemImage: "arrow.uturn.backward").font(.system(size: 11))
        }
        .buttonStyle(.borderless)
    }

    private var changedFiles: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Changed").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            FlowRow(spacing: 6) {
                ForEach(turn.changedFiles, id: \.self) { path in
                    Button {
                        openInXcode(conversation.absolutePath(path).path)
                    } label: {
                        Label(conversation.displayPath(path), systemImage: "doc.text")
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Open in Xcode")
                }
            }
        }
    }
}

func openInXcode(_ path: String, line: Int? = nil) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xed")
    process.arguments = (line.map { ["-l", String($0)] } ?? []) + [path]
    try? process.run()
}

/// One comment: where it is, what it says. Clicking it opens the code in Xcode.
private struct CommentRow: View {
    let comment: ReviewComment
    var number: Int?
    var isHere = false
    var remove: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let number {
                Text("\(number).").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(minWidth: 16, alignment: .trailing)
            }
            Button {
                PanelManager.shared.reveal(comment)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(comment.fileName) \(comment.lineLabel)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(isHere ? accent : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 190, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                    Text(comment.text)
                        .font(.system(size: 12))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isHere ? "On the selected code · click to open in Xcode" : "Open in Xcode")
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0.4)
                .help("Delete this comment")
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(hovering && remove != nil ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .onHover { hovering = $0 }
    }
}

/// Renders Markdown prose with inline styling and fenced code as monospaced blocks.
struct ReplyView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(ReplySegment.parse(text).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let prose):
                    Text(Self.attributed(prose))
                        .font(.system(size: 12.5))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(_, let body):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(body)
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
    }

    static func attributed(_ prose: String) -> AttributedString {
        // Inline Markdown keeps line breaks; headings become bold lines.
        let lines = prose.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let trimmed = line.drop { $0 == " " }
            guard trimmed.hasPrefix("#") else { return String(line) }
            let title = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? String(line) : "**\(title)**"
        }
        let source = lines.joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
    }
}

/// Lays out children left to right, wrapping onto new lines.
struct FlowRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(widest, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// A pending comment, styled like a review comment on a pull request: who, where, the text,
/// and Edit / Delete. Editing happens in place.
struct CommentCard: View {
    let comment: ReviewComment
    let showsLocation: Bool
    @Bindable private var queue = CommentQueue.shared
    @FocusState private var editorFocused: Bool
    @State private var hovering = false

    private var isEditing: Bool { queue.editingComment == comment.id }
    private var isNew: Bool { queue.justAdded == comment.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.6)
            if isEditing { editor } else { body(comment.text) }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isEditing || isNew ? accent.opacity(0.9) : Color(nsColor: .separatorColor), lineWidth: isEditing || isNew ? 1.5 : 1)
        )
        .onHover { hovering = $0 }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.crop.circle.fill").font(.system(size: 13)).foregroundStyle(.secondary)
            Text("You").font(.system(size: 11, weight: .semibold))
            if showsLocation {
                Button {
                    PanelManager.shared.reveal(comment)
                } label: {
                    Text("\(comment.fileName) \(comment.lineLabel)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .underline(hovering)
                }
                .buttonStyle(.plain)
                .help("Open in Xcode")
            } else {
                Text(comment.lineLabel).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
            }
            Text(isNew ? "Added" : "Pending")
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .foregroundStyle(isNew ? accent : Color.orange)
                .overlay(Capsule().strokeBorder(isNew ? accent : Color.orange, lineWidth: 1))
            Spacer(minLength: 4)
            if !isEditing {
                Menu {
                    Button("Edit") { queue.beginEditing(comment) }
                    Button("Delete", role: .destructive) { CommentQueue.shared.remove(comment.id) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 18, height: 14)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Edit or delete")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.04))
    }

    private func body(_ text: String) -> some View {
        Text(ReplyView.attributed(text))
            .font(.system(size: 12.5))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { queue.beginEditing(comment) }
    }

    private var editor: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField("Leave a comment", text: $queue.editText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .lineLimit(2...8)
                .focused($editorFocused)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            HStack(spacing: 8) {
                Button("Cancel") { queue.finishEditing(save: false) }
                    .controlSize(.small)
                Button("Update comment") { queue.finishEditing(save: true) }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .controlSize(.small)
                    .disabled(queue.editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(8)
        .onAppear { editorFocused = true }
    }
}
