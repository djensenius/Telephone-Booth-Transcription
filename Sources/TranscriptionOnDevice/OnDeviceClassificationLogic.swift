import Foundation
import TranscriptionShared

/// Pure, engine-agnostic reduction helpers used by the on-device Foundation
/// Models services. Kept free of any `FoundationModels` import or availability
/// gating so the logic can be unit-tested on any platform/OS.

public enum OnDeviceModerationLogic {
    /// Reduces a model classification into the verdict shape the Operator's
    /// moderation `succeed` body expects.
    ///
    /// Recommendation policy mirrors `LoopbackOperatorJobDispatcher`: a flagged
    /// input is `reject`; otherwise a score above `0.5` is `review`; everything
    /// else is `approve`. `severityScore` is clamped into `0...1` and any
    /// non-finite value is treated as `0`.
    public static func makeVerdict(
        flagged: Bool,
        severityScore: Double,
        model: String
    ) -> ModerationVerdict {
        let clamped = min(max(severityScore.isNaN ? 0 : severityScore, 0), 1)
        let recommendation: String
        if flagged {
            recommendation = "reject"
        } else if clamped > 0.5 {
            recommendation = "review"
        } else {
            recommendation = "approve"
        }
        return ModerationVerdict(
            flagged: flagged,
            recommendation: recommendation,
            maxScore: clamped,
            model: model
        )
    }
}

public enum OnDeviceTranslationLogic {
    /// Normalizes a model translation into a `TranslationResult`. A detected
    /// source language of `"unknown"`, empty, or `nil` falls back to the
    /// caller-supplied hint. Target language is always English.
    public static func makeResult(
        translatedText: String,
        detectedSource: String?,
        fallbackSource: String?,
        model: String
    ) -> TranslationResult {
        let text = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let detected = detectedSource?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let fallback = fallbackSource?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let source: String?
        if let detected, !detected.isEmpty, detected != "unknown" {
            source = detected
        } else if let fallback, !fallback.isEmpty {
            source = fallback
        } else {
            source = nil
        }
        return TranslationResult(
            translatedText: text,
            sourceLanguage: source,
            targetLanguage: "en",
            model: model
        )
    }
}

public enum OnDevicePromptSafety {
    /// Neutralizes the prompt sentinel tokens so user input cannot break out of
    /// the data-delimited region and inject follow-on instructions. The existing
    /// HTTP classifier/translator rely on the system instructions alone; this
    /// adds defense-in-depth for the on-device path.
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
