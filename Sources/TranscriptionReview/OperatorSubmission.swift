import Foundation

/// Shaping rules the Operator imposes on what this app submits. They live here,
/// rather than in the HTTP client, so demo mode is shaped identically — a
/// divergence there would show QA a value the real Operator would have
/// rewritten or refused.
public enum OperatorSubmission {
    /// Folds a verdict onto the three values the Operator accepts. A local model
    /// can phrase the same call as `block` or `allow`, and posting that verbatim
    /// would fail the whole submission over vocabulary; anything unrecognized
    /// becomes `review`, the safe answer to "a human should look at this".
    public static func recommendation(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "approve", "allow", "allowed": return "approve"
        case "reject", "block", "blocked": return "reject"
        default: return "review"
        }
    }

    /// The Operator rejects a score outside `0...1`; clamp rather than let a
    /// stray value fail the whole submission.
    public static func score(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    /// Trims a metadata field and folds an empty result to `nil`, so a blank
    /// hint is sent as JSON `null` rather than an empty string.
    public static func metadata(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }
}
