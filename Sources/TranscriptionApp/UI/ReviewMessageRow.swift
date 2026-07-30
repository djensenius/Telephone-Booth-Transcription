import SwiftUI
import TranscriptionOperator
import TranscriptionReview

/// One message in the review queue.
///
/// Deliberately shallow: a glanceable summary — who's waiting on what, what the
/// AI thinks, and the gist of the message — with every control living in the
/// detail view. The previous design put text fields and buttons in the list,
/// which is what made the queue unreadable.
struct ReviewMessageRow: View {
    let message: Message
    /// The on-device result for this message, when one has been produced. Folds
    /// Apple Intelligence's opinion into the same badge as the Operator's.
    let onDeviceOutput: OnDeviceReviewPipeline.Output?

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.medium) {
            RecommendationMark(advice: advice)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                    if let step = message.nextStep {
                        StepChip(step: step)
                    } else {
                        StatusPill(text: message.status.displayName, tint: statusTint)
                    }
                    Spacer(minLength: Theme.Spacing.small)
                    Text(message.createdAt.formatted(.relative(presentation: .named)))
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .lineLimit(1)
                }

                Text(preview)
                    .font(Theme.Fonts.bodyLarge)
                    .foregroundStyle(previewIsPlaceholder
                                     ? Theme.Colors.textSecondary
                                     : Theme.Colors.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Theme.Spacing.small) {
                    if let advice {
                        Text("\(advice.source): \(advice.recommendation.displayName)")
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(advice.tint)
                    }
                    // Only worth a chip when the preview isn't already saying
                    // it: a failed transcription leaves no text, so the preview
                    // reads "Transcription failed." and the chip would just
                    // repeat it back.
                    if message.translationFailed {
                        Label("Translation failed", systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Colors.error)
                    } else if message.transcriptionFailed, !previewIsPlaceholder {
                        Label("Transcription failed", systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Colors.error)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.small)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var advice: AIRecommendation? {
        AIRecommendation(message: message, onDeviceOutput: onDeviceOutput)
    }

    /// English first — that's what the operator moderates on. Falls back to the
    /// source transcript, then to an explanation of why there's no text.
    private var preview: String {
        if let text = message.previewText { return text }
        if message.transcriptionIsSilent { return "Silent recording — no speech detected." }
        if message.transcriptionFailed { return "Transcription failed." }
        if message.transcriptionIsUnfinished { return "Transcribing…" }
        return "Not transcribed yet."
    }

    private var previewIsPlaceholder: Bool { message.previewText == nil }

    private var statusTint: Color {
        switch message.status {
        case .approved: return Theme.Colors.success
        case .rejected: return Theme.Colors.error
        case .pending, .received: return Theme.Colors.warning
        default: return Theme.Colors.info
        }
    }

    private var accessibilityLabel: String {
        var parts = [message.nextStep?.displayName ?? message.status.displayName]
        if let advice { parts.append("\(advice.source) recommends \(advice.recommendation.displayName)") }
        parts.append(preview)
        return parts.joined(separator: ". ")
    }
}

// MARK: - AI recommendation

/// The AI's opinion on a message, from whichever engine produced one.
///
/// Issue #79 called out that this was invisible: the Operator's recommendation
/// was a low-contrast pill among four others, and the on-device verdict was
/// buried in caption text under the translate button. Both now feed one badge.
struct AIRecommendation {
    var recommendation: ModerationRecommendation
    var reason: String?
    /// Which engine produced it, shown so the operator can weight it.
    var source: String
    var flagged: Bool

    /// Prefers the Operator's verdict — it's the one of record — and falls back
    /// to a local Apple Intelligence run when the Operator has none.
    init?(message: Message, onDeviceOutput: OnDeviceReviewPipeline.Output?) {
        if let moderation = message.latestModeration,
           let recommendation = moderation.recommendation {
            self.recommendation = recommendation
            self.reason = moderation.reasonSummary
            self.source = "AI"
            self.flagged = moderation.flagged ?? false
        } else if let raw = onDeviceOutput?.recommendation {
            self.recommendation = ModerationRecommendation(rawValue: raw)
            self.reason = nil
            self.source = "On device"
            self.flagged = onDeviceOutput?.flagged ?? false
        } else {
            return nil
        }
    }

    var tint: Color {
        switch recommendation {
        case .approve: return Theme.Colors.success
        case .reject: return Theme.Colors.error
        case .review: return Theme.Colors.warning
        case .unknown: return Theme.Colors.info
        }
    }

    var systemImage: String {
        switch recommendation {
        case .approve: return "hand.thumbsup.fill"
        case .reject: return "hand.thumbsdown.fill"
        case .review: return "eye.trianglebadge.exclamationmark.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
}

/// The coloured leading mark carrying the AI's recommendation at a glance.
struct RecommendationMark: View {
    let advice: AIRecommendation?

    var body: some View {
        Image(systemName: advice?.systemImage ?? "circle.dashed")
            .font(.system(size: 15))
            .foregroundStyle(advice?.tint ?? Theme.Colors.textSecondary.opacity(0.6))
            .frame(width: 22, height: 22)
            .padding(.top, 2)
            .accessibilityHidden(true)
    }
}

// MARK: - Chips

/// The one thing this message is waiting on.
struct StepChip: View {
    let step: ReviewStep

    var body: some View {
        Label(step.displayName, systemImage: systemImage)
            .font(Theme.Fonts.caption.weight(.semibold))
            .foregroundStyle(Theme.Colors.textPrimary)
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, 3)
            .background(tint.opacity(0.22), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.5), lineWidth: 1))
    }

    private var systemImage: String {
        switch step {
        case .transcription: return "waveform"
        case .translation: return "character.book.closed"
        case .decision: return "checkmark.seal"
        }
    }

    private var tint: Color {
        switch step {
        case .transcription: return Theme.Colors.info
        case .translation: return Theme.Colors.warning
        case .decision: return Theme.Colors.accent
        }
    }
}

struct StatusPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(Theme.Fonts.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
    }
}
