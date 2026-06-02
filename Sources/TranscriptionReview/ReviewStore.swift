//
//  ReviewStore.swift
//  TranscriptionReview
//

import Foundation
import Observation
import os

/// Drives the review queue: periodically polls the Operator for recent
/// messages and exposes the two work buckets the operator cares about —
/// messages awaiting a moderation decision and messages whose transcription
/// still needs translation.
@Observable
@MainActor
public final class ReviewStore {
    public enum LoadState: Sendable, Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @ObservationIgnored
    private let client: any OperatorReviewClient
    @ObservationIgnored
    private let pollInterval: Duration
    @ObservationIgnored
    private let logger = Logger(
        subsystem: "org.davidjensenius.TelephoneBoothTranscription.review",
        category: "ReviewStore"
    )
    @ObservationIgnored
    private var inFlight: Task<Void, Never>?
    /// Bumped on every local write so a poll that started before the write and
    /// resolves after it can be discarded instead of resurrecting the old row.
    @ObservationIgnored
    private var writeGeneration = 0

    public private(set) var messages: [Message] = []
    public private(set) var state: LoadState = .idle
    public private(set) var lastUpdated: Date?

    /// IDs of messages with an approve/reject/translation request in flight.
    public private(set) var pendingActions: Set<String> = []
    /// Human-readable message for the most recent failed write action, if any.
    public private(set) var actionError: String?

    public init(client: any OperatorReviewClient, pollInterval: Duration = .seconds(30)) {
        self.client = client
        self.pollInterval = pollInterval
    }

    /// Messages whose latest transcription has source text but no translation.
    public var awaitingTranslation: [Message] {
        messages.filter(\.needsTranslation)
    }

    /// Messages still awaiting a human moderation decision.
    public var awaitingModeration: [Message] {
        messages.filter(\.awaitingModerationDecision)
    }

    /// True when the given message has a write action in flight.
    public func isActing(on messageID: String) -> Bool {
        pendingActions.contains(messageID)
    }

    /// Clears any surfaced write-action error.
    public func clearActionError() {
        actionError = nil
    }

    /// Records a human moderation decision for a message and folds the updated
    /// message back into local state so it leaves the moderation bucket
    /// immediately, without waiting for the next poll.
    public func decide(_ message: Message, _ decision: ReviewDecision, notes: String? = nil) async {
        guard !pendingActions.contains(message.id) else { return }
        pendingActions.insert(message.id)
        actionError = nil
        defer { pendingActions.remove(message.id) }
        do {
            let updated = try await client.submitDecision(
                messageID: message.id,
                decision: decision,
                notes: notes
            )
            apply(updated)
        } catch {
            actionError = Self.describe(error, verb: "save that decision")
            logger.error("Decision failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Submits an operator-supplied translation for a message's latest
    /// transcription and folds the result back into local state.
    public func submitTranslation(
        _ message: Message,
        text: String,
        language: String? = nil
    ) async {
        guard !pendingActions.contains(message.id) else { return }
        pendingActions.insert(message.id)
        actionError = nil
        defer { pendingActions.remove(message.id) }
        do {
            let updated = try await client.submitTranslation(
                messageID: message.id,
                translatedText: text,
                translatedLanguage: language
            )
            // Merge into the *current* local message, not the captured one, so a
            // poll that landed mid-request can't be clobbered with stale fields.
            let base = messages.first(where: { $0.id == message.id }) ?? message
            apply(base.replacingLatestTranscription(updated))
        } catch {
            actionError = Self.describe(error, verb: "submit that translation")
            logger.error("Translation submit failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Replaces a message in the local queue by id, preserving ordering.
    private func apply(_ message: Message) {
        writeGeneration &+= 1
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        }
    }

    private static func describe(_ error: any Error, verb: String) -> String {
        switch error {
        case OperatorReviewError.unauthenticated, OperatorReviewError.unauthorized:
            return "Couldn’t \(verb): your session expired. Sign in again."
        case OperatorReviewError.api(_, let code):
            switch code {
            case "message_not_decidable":
                return "Couldn’t \(verb): this message is still uploading."
            case "no_succeeded_transcription":
                return "Couldn’t \(verb): there’s no transcription to translate yet."
            case "not_found":
                return "Couldn’t \(verb): the message no longer exists."
            default:
                return "Couldn’t \(verb): the Operator rejected the request (\(code))."
            }
        default:
            return "Couldn’t \(verb). Check your connection and try again."
        }
    }

    /// Polls until the surrounding task is cancelled. Drive this from a
    /// SwiftUI `.task` so polling stops automatically when the view goes away.
    public func poll() async {
        while !Task.isCancelled {
            await refresh()
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return // cancelled
            }
        }
    }

    /// Fetches the most recent messages and refreshes the buckets. Overlapping
    /// calls (poll loop + manual refresh + pull-to-refresh) are coalesced onto
    /// a single in-flight request so results can never be applied out of order.
    public func refresh() async {
        if let inFlight {
            await inFlight.value
            return
        }
        let task = Task { await self.performRefresh() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func performRefresh() async {
        if state != .loaded { state = .loading }
        let generation = writeGeneration
        do {
            // The Operator returns newest-first; we surface the most recent
            // page. Active review work is expected to live within this window.
            let list = try await client.fetchMessages(status: nil, since: nil, limit: 100)
            // If a local write landed while this fetch was in flight, the page
            // we just received predates it. Discard it; the next poll (or the
            // applied write) already reflects the newer state.
            guard generation == writeGeneration else { return }
            messages = list.items
            lastUpdated = Date()
            state = .loaded
        } catch OperatorReviewError.unauthenticated, OperatorReviewError.unauthorized {
            state = .failed("Couldn’t authenticate with the Operator. Try signing in again.")
        } catch {
            logger.error("Review refresh failed: \(String(describing: error), privacy: .public)")
            state = .failed("Couldn’t reach the Operator. Pull to retry.")
        }
    }
}
