import AppKit
import QuartzCore
import SwiftUI
import BridgeCore

@Observable final class PanelModel {
    enum Content {
        case message(String, needsAccessibility: Bool)
        case conversation(Conversation)
    }

    var content: Content?
    var draft = ""
    var mode = RequestMode.ask
    var target = AgentTarget.new(AppSettings.shared.agent)
    /// Set once the user picks a target, so refreshes stop changing it.
    var pickedTarget = false
    /// Bumped whenever the panel opens so the input field takes focus.
    var focusRequest = 0
    /// Whether this is the panel in use. Others show only their comments and replies.
    var isKey = false
    /// Esc first cancels an edit, then closes the panel.
    func cancel(orClose close: () -> Void) {
        let queue = CommentQueue.shared
        if let selection = conversation?.selection, queue.isEditing(on: selection) {
            queue.finishEditing(save: false)
        } else {
            close()
        }
    }

    var conversation: Conversation? {
        if case .conversation(let conversation) = content { conversation } else { nil }
    }

    /// Targets in menu order: running sessions (this project first), then new sessions.
    func targets(_ running: [RunningAgent]) -> [AgentTarget] {
        let project = conversation?.workingDirectory.path
        return RunningAgent.sorted(running, for: project).map(AgentTarget.running) + AgentKind.allCases.map(AgentTarget.new)
    }

    func pick(_ target: AgentTarget) {
        self.target = target
        pickedTarget = true
        if case .new(let agent) = target { AppSettings.shared.agent = agent }
    }

    /// Keeps the target current as sessions start, stop and change state.
    func updateTarget(running: [RunningAgent]) {
        if case .running(let current) = target {
            if let fresh = running.first(where: { $0.id == current.id }) {
                target = .running(fresh)
                return
            }
            if pickedTarget, conversation?.isRunning == true { return }
            pickedTarget = false
        }
        guard !pickedTarget else { return }
        target = AgentTarget.preferred(running: running, project: conversation?.workingDirectory.path ?? "")
    }
}

/// A floating panel that takes keyboard input without activating the app, so Xcode stays
/// the frontmost app while you type.
final class BridgePanel: NSPanel {
    var anchorTop: CGFloat?
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 580, height: 200),
                   styleMask: [.nonactivatingPanel, .borderless, .resizable],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .utilityWindow
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    /// SwiftUI resizes the panel as the reply grows; keep the top edge where it was.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var rect = frameRect
        if let anchorTop { rect.origin.y = anchorTop - rect.height }
        if let visible = (screen ?? NSScreen.main)?.visibleFrame, rect.minY < visible.minY {
            rect.origin.y = visible.minY
        }
        let resized = rect.size != frame.size
        super.setFrame(rect, display: flag)
        // Recomputing the shadow is slow; moving doesn't change it.
        if resized { invalidateShadow() }
    }
}

/// All open panels. Each panel stays pinned to its own code until it's closed; the one in
/// use is expanded, the others show just their comments and replies.
final class PanelManager {
    static let shared = PanelManager()

    private(set) var controllers: [PanelController] = []
    /// The editor Xcode is showing, shared by all panels so they don't each search for it.
    private var currentEditor: (element: AXUIElement?, document: String?, time: Date)?

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            MainActor.assumeIsolated {
                for controller in PanelManager.shared.controllers { controller.appActivated(bundleID) }
            }
        }
    }

    /// The hot key: opens a panel on the selection, or brings back the one already there.
    /// Pressed while typing in a panel, it closes that panel.
    func hotKeyPressed() {
        if let key = controllers.first(where: \.isKey) {
            key.close()
            return
        }
        do {
            open(try XcodeAccessibility.capture())
        } catch {
            let controller = PanelController(manager: self)
            controllers.append(controller)
            controller.showMessage(error.localizedDescription, needsAccessibility: error as? CaptureError == .notTrusted)
        }
    }

    /// Opens a comment's file in Xcode, selects its lines and shows a panel there.
    func reveal(_ comment: ReviewComment) {
        openInXcode(comment.filePath, line: comment.firstLine)
        Task {
            // Wait for Xcode to open the file and scroll to the line.
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(100))
                if let capture = XcodeAccessibility.selectLines(comment.firstLine...comment.lastLine, of: comment.filePath) {
                    open(capture)
                    return
                }
            }
        }
    }

    private func open(_ capture: XcodeCapture) {
        CommentQueue.shared.finishEditing(save: false)
        if let existing = controllers.first(where: { $0.covers(capture.selection) }) {
            existing.bringBack(capture)
        } else {
            let controller = PanelController(manager: self)
            controllers.append(controller)
            controller.present(capture)
        }
    }

    func closed(_ controller: PanelController) {
        // A panel whose agent is still working is kept, so the hot key can bring it back.
        if controller.model.conversation?.isRunning != true {
            controllers.removeAll { $0 === controller }
        }
    }

    /// The source editor Xcode is showing and its file, looked up at most ten times a second.
    func editorShowing() -> (element: AXUIElement, document: String)? {
        if let cached = currentEditor, Date().timeIntervalSince(cached.time) < 0.1 {
            return cached.element.flatMap { element in cached.document.map { (element, $0) } }
        }
        let element = XcodeAccessibility.currentSourceEditor()
        let document = element.flatMap(XcodeAccessibility.documentPath(of:))
        currentEditor = (element, document, Date())
        return element.flatMap { element in document.map { (element, $0) } }
    }
}

/// One panel, pinned to one piece of code.
final class PanelController {
    let model = PanelModel()
    private unowned let manager: PanelManager
    private var panel: BridgePanel?
    private var refreshTask: Task<Void, Never>?

    /// Keeps the panel next to the code it's about while the editor scrolls.
    private struct Follow {
        var editor: AXUIElement
        let selection: EditorSelection
        /// The file the code is in, compared with the file Xcode is showing.
        let document: String
        var anchor: CGRect
        /// The panel's top-left corner relative to the selection.
        var offset: CGPoint
    }
    private var follow: Follow?
    private var displayLink: CADisplayLink?
    private let frameTicker = FrameTicker()
    private var hiddenWhileFollowing = false
    /// The panel is open but hidden because another app is in front.
    private var hiddenForOtherApp = false
    private(set) var isOpen = false
    /// Frames since the code last moved; while it's still, it's checked less often.
    private var stillFrames = 0
    private var frameCount = 0
    private var visibleFrame: CGRect?

    init(manager: PanelManager) {
        self.manager = manager
    }

    var isKey: Bool { isOpen && panel?.isKeyWindow == true && panel?.isVisible == true }

    /// Whether this panel is about code that `selection` touches.
    func covers(_ selection: EditorSelection) -> Bool {
        guard let mine = model.conversation?.selection else { return false }
        return mine.fileURL.standardizedFileURL.path == selection.fileURL.standardizedFileURL.path && mine.lines.overlaps(selection.lines)
    }

    /// Keeps the panel with Xcode: hidden while another app is in front, back when Xcode
    /// (or this app) is.
    func appActivated(_ bundleID: String?) {
        guard isOpen, let panel else { return }
        if bundleID == XcodeAccessibility.bundleIdentifier || bundleID == Bundle.main.bundleIdentifier {
            guard hiddenForOtherApp else { return }
            hiddenForOtherApp = false
            if !hiddenWhileFollowing { panel.orderFront(nil) }
        } else {
            hiddenForOtherApp = true
            panel.orderOut(nil)
        }
    }

    /// Opens a new conversation about `capture` next to its code.
    func present(_ capture: XcodeCapture) {
        model.content = .conversation(Conversation(capture: capture))
        model.draft = ""
        model.mode = .ask
        model.pickedTarget = false
        model.updateTarget(running: RunningAgents.shared.agents)
        show(anchor: capture.anchor, reposition: true)
        startFollowing(capture)
    }

    /// Shows this panel's conversation again, next to its code.
    func bringBack(_ capture: XcodeCapture) {
        guard let conversation = model.conversation else { return present(capture) }
        let anchor = capture.selection.fileURL == conversation.selection.fileURL && capture.editor != nil
            ? XcodeAccessibility.selectionBounds(in: capture.editor!, selection: conversation.selection) : nil
        show(anchor: anchor ?? capture.anchor, reposition: !(panel?.isVisible ?? false))
        startFollowing(XcodeCapture(selection: conversation.selection, anchor: anchor ?? capture.anchor,
                                    xcode: capture.xcode, editor: capture.editor))
    }

    func showMessage(_ text: String, needsAccessibility: Bool) {
        model.content = .message(text, needsAccessibility: needsAccessibility)
        show(anchor: nil, reposition: true)
    }

    /// Esc and the close button: stop editing a comment first, otherwise close.
    func cancel() {
        model.cancel { close() }
    }

    func close() {
        isOpen = false
        hiddenForOtherApp = false
        if let selection = model.conversation?.selection, CommentQueue.shared.isEditing(on: selection) {
            CommentQueue.shared.finishEditing(save: false)
        }
        stopFollowing()
        refreshTask?.cancel()
        refreshTask = nil
        panel?.orderOut(nil)
        manager.closed(self)
        if let xcode = XcodeAccessibility.runningXcode { xcode.activate() }
    }

    private func show(anchor: CGRect?, reposition: Bool) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if reposition || !panel.isVisible { position(panel, anchor: anchor) }
        isOpen = true
        hiddenForOtherApp = false
        hiddenWhileFollowing = false
        panel.makeKeyAndOrderFront(nil)
        model.focusRequest += 1
        startRefreshing()
    }

    /// Re-reads running sessions while the panel is open, so status and new sessions show up.
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

    private func startFollowing(_ capture: XcodeCapture) {
        stopFollowing()
        FollowLog.write("follow \(capture.selection.fileName) \(capture.selection.lineLabel), anchor \(capture.anchor == nil ? "none" : "ok")")
        guard let editor = capture.editor, let panel else { return }
        AXUIElementSetMessagingTimeout(editor, 0.25)
        // Without a position yet (another file is showing), use where the panel would open.
        let anchor = capture.anchor ?? .zero
        let offset = capture.anchor.map { CGPoint(x: panel.frame.minX - $0.minX, y: panel.frame.maxY - $0.minY) } ?? CGPoint(x: -24, y: -6)
        follow = Follow(editor: editor, selection: capture.selection, document: capture.selection.fileURL.standardizedFileURL.path,
                        anchor: anchor, offset: offset)
        visibleFrame = XcodeAccessibility.visibleFrame(of: editor)
        stillFrames = 0
        frameCount = 0
        // A screen's display link keeps ticking while the panel is hidden, so it can come back.
        frameTicker.tick = { [weak self] in self?.frameTick() }
        let screen = panel.screen ?? NSScreen.main
        displayLink = screen?.displayLink(target: frameTicker, selector: #selector(FrameTicker.step(_:)))
        displayLink?.add(to: .main, forMode: .common)
    }

    private func stopFollowing() {
        displayLink?.invalidate()
        displayLink = nil
        follow = nil
        hiddenWhileFollowing = false
    }

    /// Runs every screen refresh. Checks every frame while the code is moving and every
    /// eighth frame while it's still. File checks run a few times a second.
    private func frameTick() {
        frameCount += 1
        if stillFrames > 30, frameCount % 8 != 0 { return }
        guard var current = follow else { return }
        if frameCount % 15 == 0 {
            // Switching files can replace Xcode's editor; follow the one showing our file.
            guard let (editor, document) = manager.editorShowing(), document == current.document else {
                hide()
                return
            }
            if !CFEqual(editor, current.editor) {
                AXUIElementSetMessagingTimeout(editor, 0.25)
                current.editor = editor
                follow = current
                FollowLog.write("\(current.selection.fileName) \(current.selection.lineLabel): following Xcode's new editor")
            }
            visibleFrame = XcodeAccessibility.visibleFrame(of: current.editor)
        } else if hiddenWhileFollowing {
            // While hidden, only the file checks above can bring it back.
            return
        }
        followStep()
    }

    private func hide() {
        guard !hiddenWhileFollowing else { return }
        hiddenWhileFollowing = true
        stillFrames = 0
        panel?.orderOut(nil)
    }

    /// Moves the panel with the code; hides it while the code is scrolled out of view.
    private func followStep() {
        guard var current = follow, let panel else { return }
        let rect = XcodeAccessibility.selectionBounds(in: current.editor, selection: current.selection)
        guard let rect, visibleFrame.map({ $0.intersects(rect) }) ?? true else {
            hide()
            return
        }
        stillFrames = rect.origin == current.anchor.origin ? stillFrames + 1 : 0
        if rect.origin != current.anchor.origin {
            current.anchor = rect
            follow = current
            let top = rect.minY + current.offset.y
            panel.anchorTop = top
            panel.setFrame(NSRect(x: rect.minX + current.offset.x, y: top - panel.frame.height,
                                  width: panel.frame.width, height: panel.frame.height), display: false)
        }
        if hiddenWhileFollowing {
            hiddenWhileFollowing = false
            if !hiddenForOtherApp { panel.orderFront(nil) }
        }
    }

    /// The user dragged the panel: keep following from the new spot.
    private func panelDragged(_ panel: BridgePanel) {
        guard NSEvent.pressedMouseButtons != 0, var current = follow else { return }
        current.offset = CGPoint(x: panel.frame.minX - current.anchor.minX, y: panel.frame.maxY - current.anchor.minY)
        follow = current
    }

    private func makePanel() -> BridgePanel {
        let panel = BridgePanel()
        let hosting = NSHostingController(rootView: PanelView(model: model, close: { [weak self] in self?.cancel() }))
        hosting.sizingOptions = [.preferredContentSize]
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = .clear
        panel.contentViewController = hosting
        panel.onCancel = { [weak self] in self?.cancel() }
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] notification in
            guard let panel = notification.object as? BridgePanel else { return }
            MainActor.assumeIsolated {
                panel.anchorTop = panel.frame.maxY
                self?.panelDragged(panel)
            }
        }
        // The panel in use is expanded; the others shrink to their comments and replies.
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.isKey = true }
        }
        center.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.isKey = false }
        }
        return panel
    }

    private func position(_ panel: BridgePanel, anchor: CGRect?) {
        let width = panel.frame.width
        let point = anchor.map { CGPoint(x: $0.minX, y: $0.minY) } ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        var top: CGFloat
        var x: CGFloat
        if let anchor {
            x = anchor.minX - 24
            top = anchor.minY - 6
            // Not enough room below the selection: open above it instead.
            if top - visible.minY < 320 { top = min(visible.maxY, anchor.maxY + 6 + 320) }
        } else {
            x = point.x - width / 2
            top = point.y + 40
        }
        x = min(max(x, visible.minX + 8), visible.maxX - width - 8)
        top = min(top, visible.maxY - 8)
        panel.anchorTop = top
        panel.setFrame(NSRect(x: x, y: top - panel.frame.height, width: width, height: panel.frame.height), display: true)
    }
}

extension CaptureError: Equatable {}

/// Receives display-link callbacks, which need an Objective-C target.
final class FrameTicker: NSObject {
    var tick: (() -> Void)?
    @objc func step(_ link: CADisplayLink) { tick?() }
}

/// A small log of how the panel follows code, in ~/Library/Logs/XcodeAgentBridge.log.
/// Repeated lines are written once.
enum FollowLog {
    private static var last = ""
    private static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/XcodeAgentBridge.log")

    static func name(_ path: String?) -> String {
        path.map { ($0 as NSString).lastPathComponent } ?? "nothing"
    }

    static func write(_ message: String) {
        guard message != last else { return }
        last = message
        let line = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
