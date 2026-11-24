import Foundation
import Testing
@testable import BridgeCore

private func comment(_ path: String, _ source: String, select: String, _ text: String) -> ReviewComment {
    let selection = EditorSelection(fileURL: URL(fileURLWithPath: "/repo/\(path)"), buffer: source,
                                    range: (source as NSString).range(of: select))
    return ReviewComment(selection: selection, workingDirectory: URL(fileURLWithPath: "/repo"), text: text)
}

@Test func reviewPromptNumbersCommentsByFileAndLine() throws {
    let source = "a\nb\nc\nd\n"
    let late = comment("Sources/B.swift", source, select: "d", "Rename this")
    let early = comment("Sources/B.swift", source, select: "b\nc", "  Why two lines?  ")
    let other = comment("Sources/A.swift", source, select: "a", "Remove")
    #expect(early.lineLabel == "L2–3" && early.text == "Why two lines?" && early.relativePath == "Sources/B.swift")

    let prompt = PromptBuilder.reviewPrompt(comments: [late, early, other], mode: .change, reference: "R1")
    #expect(prompt.hasPrefix("I left 3 comments on code in Xcode."))
    let a = try #require(prompt.range(of: "## 1. `Sources/A.swift` line 1"))
    let b = try #require(prompt.range(of: "## 2. `Sources/B.swift` lines 2–3\n\n```swift\nb\nc\n```\n\nWhy two lines?"))
    let d = try #require(prompt.range(of: "## 3. `Sources/B.swift` line 4"))
    #expect(a.lowerBound < b.lowerBound && b.lowerBound < d.lowerBound)
    #expect(prompt.contains("one short line per comment number"))
    #expect(prompt.hasSuffix(PromptBuilder.referenceLine("R1")))

    let ask = PromptBuilder.reviewPrompt(comments: [other], mode: .ask)
    #expect(ask.hasPrefix("I left 1 comment on") && ask.contains("Don't modify any files."))
}

@Test func reviewCommentsRoundTripAndMatchSelections() throws {
    let source = "let x = 1\nlet y = 2\n"
    let original = comment("A.swift", source, select: "let y", "Inline this")
    let decoded = try JSONDecoder().decode([ReviewComment].self, from: JSONEncoder().encode([original]))
    #expect(decoded == [original])
    let sameLine = EditorSelection(fileURL: URL(fileURLWithPath: "/repo/A.swift"), buffer: source, range: NSRange(location: 12, length: 3))
    let otherLine = EditorSelection(fileURL: URL(fileURLWithPath: "/repo/A.swift"), buffer: source, range: NSRange(location: 0, length: 0))
    #expect(original.matches(sameLine) && !original.matches(otherLine))
    let both = EditorSelection(fileURL: URL(fileURLWithPath: "/repo/A.swift"), buffer: source, range: NSRange(location: 0, length: 15))
    #expect(original.matches(both))
}

@Test func lineRangesSelectWholeLines() {
    let text = "one\ntwo\n\nfour\n" as NSString
    #expect(EditorSelection.range(ofLines: 2...2, in: text) == NSRange(location: 4, length: 3))
    #expect(EditorSelection.range(ofLines: 1...2, in: text) == NSRange(location: 0, length: 7))
    #expect(EditorSelection.range(ofLines: 3...3, in: text) == NSRange(location: 8, length: 0))
    #expect(EditorSelection.range(ofLines: 4...4, in: text) == NSRange(location: 9, length: 4))
    #expect(EditorSelection.range(ofLines: 9...9, in: text) == nil)
}

@Test func reviewCommentsUseWholeLinesAndContextForBlankLines() {
    let source = "func a() {\n    /// Docs\n    let x = 1\n\n    let y = 2\n}\n"
    let midLine = comment("A.swift", source, select: "Docs\n    let x", "Explain")
    #expect(midLine.code == "    /// Docs\n    let x = 1" && midLine.codeStartLine == nil && midLine.lineLabel == "L2–3")

    let blank = EditorSelection(fileURL: URL(fileURLWithPath: "/repo/A.swift"), buffer: source,
                                range: NSRange(location: (source as NSString).range(of: "\n\n").location + 1, length: 0))
    let onBlank = ReviewComment(selection: blank, workingDirectory: URL(fileURLWithPath: "/repo"), text: "Add a line here")
    #expect(onBlank.lineLabel == "L4" && onBlank.codeStartLine == 1)
    #expect(onBlank.code == "func a() {\n    /// Docs\n    let x = 1\n\n    let y = 2\n}\n")
    let prompt = PromptBuilder.reviewPrompt(comments: [onBlank], mode: .ask)
    #expect(prompt.contains("`A.swift` line 4 (blank; lines 1–7 shown around it)"))
}

@Test func sessionTitlesPreferRenameOverAITitle() {
    let ai = #"{"type":"ai-title","aiTitle":"Old title","sessionId":"x"}"# + "\n" + #"{"type":"user","message":{}}"# + "\n"
        + #"{"type":"ai-title","aiTitle":"Agent code review app UI","sessionId":"x"}"# + "\n"
    #expect(ClaudeSessions.title(inTranscriptText: ai) == "Agent code review app UI")
    let renamed = #"{"type":"custom-title","customTitle":"Bridge work","sessionId":"x"}"# + "\n" + ai
    #expect(ClaudeSessions.title(inTranscriptText: renamed) == "Bridge work")
    #expect(ClaudeSessions.title(inTranscriptText: #"{"type":"user"}"#) == nil)
}
