import Foundation
import BridgeCore

/// Comments collected across selections and files, sent to the agent together.
/// Kept in UserDefaults so they survive quitting the app.
@Observable final class CommentQueue {
    static let shared = CommentQueue()
    private static let key = "pendingComments"

    private(set) var comments: [ReviewComment] {
        didSet {
            if let data = try? JSONEncoder().encode(comments) { UserDefaults.standard.set(data, forKey: Self.key) }
        }
    }

    private init() {
        let data = UserDefaults.standard.data(forKey: Self.key)
        comments = data.flatMap { try? JSONDecoder().decode([ReviewComment].self, from: $0) } ?? []
    }

    var isEmpty: Bool { comments.isEmpty }

    /// The comment being edited, in the panel or the list, and its text while editing.
    var editingComment: ReviewComment.ID?
    var editText = ""
    /// The comment just added, highlighted briefly.
    private(set) var justAdded: ReviewComment.ID?

    /// Whether the comment being edited is on `selection`, so a panel there shows the edit.
    func isEditing(on selection: EditorSelection) -> Bool {
        guard let id = editingComment else { return false }
        return comments.contains { $0.id == id && $0.matches(selection) }
    }

    func beginEditing(_ comment: ReviewComment) {
        editingComment = comment.id
        editText = comment.text
    }

    func finishEditing(save: Bool) {
        guard let id = editingComment else { return }
        if save { update(id, text: editText) }
        editingComment = nil
        editText = ""
    }

    func flagAdded(_ id: ReviewComment.ID) {
        justAdded = id
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if justAdded == id { justAdded = nil }
        }
    }

    func add(_ comment: ReviewComment) {
        guard !comment.text.isEmpty else { return }
        comments.append(comment)
    }

    func update(_ id: ReviewComment.ID, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let index = comments.firstIndex(where: { $0.id == id }) else { return }
        comments[index].text = text
    }

    func remove(_ id: ReviewComment.ID) {
        if editingComment == id { editingComment = nil }
        comments.removeAll { $0.id == id }
    }

    /// Hands back every comment and empties the queue.
    func takeAll() -> [ReviewComment] {
        defer { comments.removeAll() }
        return comments
    }

    func restore(_ restored: [ReviewComment]) {
        comments = restored + comments.filter { comment in !restored.contains { $0.id == comment.id } }
    }

    func clear() {
        editingComment = nil
        comments.removeAll()
    }
}
