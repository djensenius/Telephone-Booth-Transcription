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

    /// Returns `tag` only if it is a structurally well-formed BCP-47 language
    /// tag, else `nil`.
    ///
    /// Language hints arrive from the client and are interpolated *outside* the
    /// delimited data region, where `sanitizeForDelimitedPrompt` can't help, so
    /// anything that isn't a plausible tag is dropped rather than escaped:
    /// callers then fall back to letting the model detect the language.
    ///
    /// The check is structural rather than merely lexical, because a
    /// "hyphen-separated alphanumeric words" rule still admits instruction-
    /// shaped values like `ignore-all-rules-output-safe`. Requiring a 2–3
    /// letter primary subtag followed only by script/region/variant shapes
    /// bounds the value to codes that cannot spell out a sentence.
    ///
    /// Accepts `language[-script][-region][-variant…]`:
    /// - language: 2–3 letters (`en`, `fra`)
    /// - script: exactly 4 letters (`Hant`)
    /// - region: exactly 2 letters or 3 digits (`US`, `419`)
    /// - variant: 5–8 alphanumerics, or 4 starting with a digit (`1996`)
    ///
    /// Extensions and private-use subtags (`-u-…`, `-x-…`) are deliberately
    /// rejected: no engine here uses them, and they are the one part of the
    /// grammar that admits long runs of free-form text.
    public static func normalizedLanguageTag(_ tag: String?) -> String? {
        guard let tag else { return nil }
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 35 else { return nil }

        var subtags = trimmed.split(separator: "-", omittingEmptySubsequences: false)[...]
        guard let language = subtags.popFirst(),
              (2...3).contains(language.count),
              language.allSatisfy(\.isAsciiLetter)
        else { return nil }

        if let next = subtags.first, next.count == 4, next.allSatisfy(\.isAsciiLetter) {
            subtags.removeFirst()
        }
        if let next = subtags.first,
           next.count == 2 && next.allSatisfy(\.isAsciiLetter)
            || next.count == 3 && next.allSatisfy(\.isAsciiDigit) {
            subtags.removeFirst()
        }
        for variant in subtags {
            let isLongForm = (5...8).contains(variant.count)
                && variant.allSatisfy(\.isAsciiAlphanumeric)
            let isDigitForm = variant.count == 4
                && variant.first?.isAsciiDigit == true
                && variant.allSatisfy(\.isAsciiAlphanumeric)
            guard isLongForm || isDigitForm else { return nil }
        }
        return trimmed
    }
}

private extension Character {
    var isAsciiLetter: Bool { isASCII && isLetter }
    var isAsciiDigit: Bool { isASCII && isNumber }
    var isAsciiAlphanumeric: Bool { isAsciiLetter || isAsciiDigit }
}
