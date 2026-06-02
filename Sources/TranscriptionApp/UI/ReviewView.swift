import SwiftUI
import TranscriptionAuth
import TranscriptionReview

/// The review queue: the operator's primary surface. Surfaces messages whose
/// transcription still needs translation and messages awaiting a moderation
/// decision, alongside the AI's recommendation. Read-only for now — the
/// translate / approve / reject actions land once the Operator exposes the
/// matching endpoints.
struct ReviewView: View {
    @State private var auth = AuthManager.shared
    @State private var store = ReviewStore(
        client: HTTPOperatorReviewClient(tokenProvider: AuthBearerAdapter())
    )

    var body: some View {
        Group {
            if auth.isSignedIn {
                queue
            } else {
                signedOut
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: auth.isSignedIn) {
            if auth.isSignedIn {
                await store.poll()
            }
        }
    }

    private var signedOut: some View {
        VStack(spacing: Theme.Spacing.medium) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 40))
                .foregroundStyle(Theme.Colors.textSecondary)
            Text("Sign in to review messages")
                .font(Theme.Fonts.headerLarge())
                .foregroundStyle(Theme.Colors.textPrimary)
            Text("Connect your Operator account in Settings to load the review queue.")
                .font(Theme.Fonts.bodyMedium)
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var queue: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                header

                if case .failed(let message) = store.state {
                    banner(message, systemImage: "exclamationmark.triangle.fill", tint: Theme.Colors.warning)
                }

                bucket(
                    title: "Needs translation",
                    systemImage: "character.book.closed",
                    messages: store.awaitingTranslation,
                    emptyText: "Every transcription is translated."
                )

                bucket(
                    title: "Awaiting moderation",
                    systemImage: "checklist",
                    messages: store.awaitingModeration,
                    emptyText: "No messages waiting on a decision."
                )
            }
            .padding(.bottom, Theme.Spacing.large)
        }
        .refreshable { await store.refresh() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Review")
                    .font(Theme.Fonts.headerXL())
                    .foregroundStyle(Theme.Colors.textPrimary)
                if let updated = store.lastUpdated {
                    Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            Spacer()
            Button {
                Task { await store.refresh() }
            } label: {
                if store.state == .loading {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(TBTGlassButtonStyle())
            .disabled(store.state == .loading)
        }
    }

    @ViewBuilder
    private func bucket(
        title: String,
        systemImage: String,
        messages: [Message],
        emptyText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Label("\(title) (\(messages.count))", systemImage: systemImage)
                .font(Theme.Fonts.headerLarge())
                .foregroundStyle(Theme.Colors.textPrimary)

            if messages.isEmpty {
                Text(emptyText)
                    .font(Theme.Fonts.bodyMedium)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Theme.Spacing.small)
            } else {
                ForEach(messages) { message in
                    ReviewRow(message: message)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func banner(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(Theme.Fonts.bodyMedium)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.medium)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }
}

private struct ReviewRow: View {
    let message: Message

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.small) {
                StatusPill(text: message.status.displayName, tint: statusTint)
                if let recommendation = message.latestModeration?.recommendation {
                    StatusPill(
                        text: "AI: \(recommendation.displayName)",
                        tint: recommendationTint(recommendation)
                    )
                }
                Spacer()
                Text(message.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }

            Text(transcriptText)
                .font(Theme.Fonts.bodyMedium)
                .foregroundStyle(Theme.Colors.textPrimary)
                .lineLimit(4)

            if let reason = message.latestModeration?.reasonSummary, !reason.isEmpty {
                Text(reason)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.tertiaryBackground.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }

    private var transcriptText: String {
        if let text = message.latestTranscription?.text,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return "No transcription yet."
    }

    private var statusTint: Color {
        switch message.status {
        case .approved: return Theme.Colors.success
        case .rejected: return Theme.Colors.error
        case .pending, .received: return Theme.Colors.warning
        default: return Theme.Colors.info
        }
    }

    private func recommendationTint(_ recommendation: ModerationRecommendation) -> Color {
        switch recommendation {
        case .approve: return Theme.Colors.success
        case .reject: return Theme.Colors.error
        case .review: return Theme.Colors.warning
        case .unknown: return Theme.Colors.info
        }
    }
}

private struct StatusPill: View {
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
