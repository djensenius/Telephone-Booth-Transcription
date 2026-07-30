import Foundation
import Observation

/// The operator's unsent work: translation and notes drafts, and the text each
/// local recommendation was computed from.
///
/// This lives outside the detail view because the detail view is transient. It
/// is `.id(message.id)`-scoped, so changing the macOS selection or popping the
/// iOS detail destroys its `@State` — and with it a translation the operator
/// typed by hand, or one a failed submit deliberately kept for them to retry.
/// The pipeline already outlives the view for the same reason; drafts have to
/// as well.
@MainActor
@Observable
final class ReviewDraftStore {
    struct Draft: Equatable {
        var translation = ""
        var notes = ""
        /// The text the local verdict on screen was computed from, so an edit
        /// that makes it stale can be detected.
        var moderatedText: String?

        var isEmpty: Bool { translation.isEmpty && notes.isEmpty && moderatedText == nil }
    }

    private var drafts: [String: Draft] = [:]

    subscript(messageID: String) -> Draft {
        get { drafts[messageID] ?? Draft() }
        set { drafts[messageID] = newValue.isEmpty ? nil : newValue }
    }

    /// Discards everything held for a message, for when its source text is
    /// superseded or it leaves the queue.
    func clear(_ messageID: String) {
        drafts[messageID] = nil
    }

    /// Drops drafts for messages that are no longer in the review queue.
    ///
    /// Drafts hold full translations, so without this a long session keeps the
    /// text of every message it ever touched resident.
    func prune(keeping activeIDs: Set<String>) {
        drafts = drafts.filter { activeIDs.contains($0.key) }
    }
}
