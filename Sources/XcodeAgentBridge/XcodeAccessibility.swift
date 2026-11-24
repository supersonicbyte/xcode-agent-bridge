import AppKit
import ApplicationServices
import BridgeCore

/// The selection and where it is on screen, read from Xcode through Accessibility.
struct XcodeCapture {
    var selection: EditorSelection
    /// The selection's bounds in AppKit screen coordinates, when Xcode reports them.
    var anchor: CGRect?
    var xcode: NSRunningApplication
    /// The source editor the selection came from, used to keep the panel next to the code.
    var editor: AXUIElement?
}

nonisolated enum CaptureError: LocalizedError, Hashable {
    case notTrusted, xcodeNotRunning, noEditor, noFile

    var errorDescription: String? {
        switch self {
        case .notTrusted: "Xcode Agent Bridge needs Accessibility access to read your selection in Xcode."
        case .xcodeNotRunning: "Xcode isn't running."
        case .noEditor: "Click into a source editor in Xcode, select some code, then press the shortcut again."
        case .noFile: "Xcode didn't report a file for this editor. Save the file first."
        }
    }
}

enum XcodeAccessibility {
    static let bundleIdentifier = "com.apple.dt.Xcode"

    static func isTrusted(prompt: Bool) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    static var runningXcode: NSRunningApplication? {
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == bundleIdentifier { return front }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
    }

    static func capture() throws -> XcodeCapture {
        guard isTrusted(prompt: false) else { throw CaptureError.notTrusted }
        guard let xcode = runningXcode else { throw CaptureError.xcodeNotRunning }
        let app = AXUIElementCreateApplication(xcode.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1.5)
        guard let editor = sourceEditor(in: app) else { throw CaptureError.noEditor }

        let window = element(editor, kAXWindowAttribute) ?? element(app, kAXFocusedWindowAttribute)
        guard let documentString = window.flatMap({ string($0, kAXDocumentAttribute) }),
              let fileURL = URL(string: documentString), fileURL.isFileURL else { throw CaptureError.noFile }
        let buffer = string(editor, kAXValueAttribute) ?? ""
        var range = CFRange(location: 0, length: 0)
        if let value = value(editor, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(value as! AXValue, .cfRange, &range)
        }
        let selection = EditorSelection(fileURL: fileURL, buffer: buffer, range: NSRange(location: range.location, length: range.length))
        return XcodeCapture(selection: selection, anchor: anchorRect(editor, selection: selection), xcode: xcode, editor: editor)
    }

    /// Selects whole lines of `path` in Xcode's current editor and captures them, once Xcode
    /// is showing that file. Nil while it isn't (yet).
    static func selectLines(_ lines: ClosedRange<Int>, of path: String) -> XcodeCapture? {
        guard let xcode = runningXcode, let editor = currentSourceEditor(), documentPath(of: editor) == path,
              let fileURL = document(of: editor).flatMap(URL.init(string:)) else { return nil }
        let buffer = string(editor, kAXValueAttribute) ?? ""
        guard let range = EditorSelection.range(ofLines: lines, in: buffer as NSString) else { return nil }
        var cfRange = CFRange(location: range.location, length: range.length)
        if let value = AXValueCreate(.cfRange, &cfRange) {
            AXUIElementSetAttributeValue(editor, kAXSelectedTextRangeAttribute as CFString, value)
        }
        let selection = EditorSelection(fileURL: fileURL, buffer: buffer, range: range)
        guard let anchor = anchorRect(editor, selection: selection) else { return nil }
        return XcodeCapture(selection: selection, anchor: anchor, xcode: xcode, editor: editor)
    }

    /// The source editor Xcode is showing now, if any.
    static func currentSourceEditor() -> AXUIElement? {
        guard isTrusted(prompt: false), let xcode = runningXcode else { return nil }
        let app = AXUIElementCreateApplication(xcode.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)
        return sourceEditor(in: app)
    }

    /// Where the selection is on screen now, in AppKit coordinates.
    static func selectionBounds(in editor: AXUIElement, selection: EditorSelection) -> CGRect? {
        anchorRect(editor, selection: selection)
    }

    /// The part of the editor that's on screen: its scroll area, in AppKit coordinates.
    static func visibleFrame(of editor: AXUIElement) -> CGRect? {
        var node: AXUIElement? = editor
        for _ in 0..<3 {
            guard let current = node else { break }
            if string(current, kAXRoleAttribute) == kAXScrollAreaRole { return frame(of: current) }
            node = element(current, kAXParentAttribute)
        }
        return nil
    }

    /// The file shown in the editor's window, to notice when the user switches files.
    static func document(of editor: AXUIElement) -> String? {
        element(editor, kAXWindowAttribute).flatMap { string($0, kAXDocumentAttribute) }
    }

    /// The path of the file shown in the editor's window.
    static func documentPath(of editor: AXUIElement) -> String? {
        document(of: editor).flatMap(URL.init(string:)).map { $0.standardizedFileURL.path }
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var position = CGPoint.zero, size = CGSize.zero
        guard let p = value(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let z = value(element, kAXSizeAttribute), CFGetTypeID(z) == AXValueGetTypeID(),
              AXValueGetValue(p as! AXValue, .cgPoint, &position), AXValueGetValue(z as! AXValue, .cgSize, &size) else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: position.x, y: primaryHeight - position.y - size.height, width: size.width, height: size.height)
    }

    /// Presses Xcode's ⌘S menu item, found by its shortcut so it works in any language.
    static func saveFrontDocument(of xcode: NSRunningApplication) -> Bool {
        pressMenuItem(of: xcode, key: "S", modifiers: 0)
    }

    /// Presses Xcode's Save All (⌥⌘S), for changes that span several files.
    static func saveAllDocuments(of xcode: NSRunningApplication) -> Bool {
        pressMenuItem(of: xcode, key: "S", modifiers: 2) // kAXMenuItemModifierOption; ⌘ is implied
    }

    private static func pressMenuItem(of xcode: NSRunningApplication, key: String, modifiers: Int) -> Bool {
        let app = AXUIElementCreateApplication(xcode.processIdentifier)
        guard let menuBar = element(app, kAXMenuBarAttribute) else { return false }
        func search(_ node: AXUIElement, depth: Int) -> AXUIElement? {
            if depth > 3 { return nil }
            for child in children(node) {
                if string(child, kAXRoleAttribute) == kAXMenuItemRole,
                   string(child, kAXMenuItemCmdCharAttribute) == key,
                   (value(child, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue == modifiers,
                   (value(child, kAXEnabledAttribute) as? Bool) == true {
                    return child
                }
                if let found = search(child, depth: depth + 1) { return found }
            }
            return nil
        }
        guard let save = search(menuBar, depth: 0) else { return false }
        return AXUIElementPerformAction(save, kAXPressAction as CFString) == .success
    }

    // MARK: - Helpers

    private static func sourceEditor(in app: AXUIElement) -> AXUIElement? {
        if let focused = element(app, kAXFocusedUIElementAttribute), isSourceEditor(focused) { return focused }
        guard let window = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute) else { return nil }
        func search(_ node: AXUIElement, depth: Int) -> AXUIElement? {
            if depth > 40 { return nil }
            if isSourceEditor(node) { return node }
            for child in children(node) { if let found = search(child, depth: depth + 1) { return found } }
            return nil
        }
        return search(window, depth: 0)
    }

    private static func isSourceEditor(_ element: AXUIElement) -> Bool {
        string(element, kAXRoleAttribute) == kAXTextAreaRole && string(element, kAXDescriptionAttribute) == "Source Editor"
    }

    private static func anchorRect(_ editor: AXUIElement, selection: EditorSelection) -> CGRect? {
        let length = (selection.buffer as NSString).length
        func bounds(at location: Int) -> CGRect? {
            var range = CFRange(location: min(location, max(0, length - 1)), length: length == 0 ? 0 : 1)
            guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
            var result: AnyObject?
            guard AXUIElementCopyParameterizedAttributeValue(editor, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &result) == .success,
                  let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
            var rect = CGRect.zero
            AXValueGetValue(result as! AXValue, .cgRect, &rect)
            // Off-screen text comes back as an empty rect at the editor's edge.
            return rect.width == 0 && rect.height == 0 ? nil : rect
        }
        let end = selection.range.location + max(0, selection.range.length - 1)
        let locations = end == selection.range.location ? [end] : [selection.range.location, end]
        let visible = locations.compactMap(bounds(at:))
        guard let first = visible.first else { return nil }
        let union = visible.dropFirst().reduce(first) { $0.union($1) }
        // Accessibility uses top-left origin coordinates relative to the primary screen.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: union.minX, y: primaryHeight - union.maxY, width: union.width, height: union.height)
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var result: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let result = value(element, attribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
}
