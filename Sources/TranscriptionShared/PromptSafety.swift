import Foundation

/// Helpers for building prompts that embed untrusted text.
///
/// Every engine here — the on-device Foundation Models services and the HTTP
/// translator/classifier alike — frames caller-supplied text inside
/// `<<<TEXT>>>`/`<<<END>>>` sentinels and instructs the model to treat it as
/// data. That instruction is best-effort: a model can be talked out of it. These
/// helpers remove the easy escape, so the system prompt isn't the only defence.
public enum PromptSafety {
    /// Neutralizes the prompt sentinel tokens so user input cannot break out of
    /// the data-delimited region and inject follow-on instructions.
    ///
    /// Zero-width spaces are used rather than deletion so the text still reads
    /// correctly if a message legitimately mentions the sentinels.
    public static func sanitizeForDelimitedPrompt(_ input: String) -> String {
        input
            .replacingOccurrences(of: "<<<TEXT>>>", with: "<\u{200B}<\u{200B}<TEXT>\u{200B}>\u{200B}>")
            .replacingOccurrences(of: "<<<END>>>", with: "<\u{200B}<\u{200B}<END>\u{200B}>\u{200B}>")
    }

    /// Returns `tag` only if it looks like a BCP-47 language tag, else `nil`.
    ///
    /// Language hints arrive from the client and are interpolated *outside* the
    /// delimited data region, where `sanitizeForDelimitedPrompt` can't help, so
    /// anything that isn't a plausible tag is dropped rather than escaped:
    /// callers then fall back to letting the model detect the language.
    /// Deliberately stricter than BCP-47 — it accepts only alphanumeric
    /// subtags of 1–8 characters joined by hyphens, up to 5 subtags — which
    /// covers every tag these engines understand while excluding whitespace,
    /// newlines, and sentinel tokens.
    public static func normalizedLanguageTag(_ tag: String?) -> String? {
        guard let tag else { return nil }
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 45 else { return nil }
        let subtags = trimmed.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...5).contains(subtags.count) else { return nil }
        for subtag in subtags {
            guard (1...8).contains(subtag.count),
                  subtag.allSatisfy({ $0.isASCII && $0.isLetter || $0.isASCII && $0.isNumber })
            else { return nil }
        }
        return trimmed
    }
}
