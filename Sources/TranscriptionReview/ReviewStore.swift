//
//  ReviewStore.swift
//  TranscriptionReview
//

import Foundation
import Observation
import os

/// Requests a local transcription run for one message. Implemented by the app
/// over its Operator push worker, keeping this module free of any dependency on
/// the worker stack.
public protocol TranscriptionRerunRequesting: Sendable {
    /// Enqueues a transcription for `messageID`, regardless of whether the
    /// Operator already holds a transcript. Returns `false` when the worker
    /// isn't running or the job is already queued.
    func requestTranscription(messageID: String) async -> Bool
}

/// Drives the review queue: periodically polls the Operator for recent
/// messages and exposes the work buckets the operator cares about — messages
/// with no transcription yet, messages whose transcription still needs
/// translation, and messages awaiting a moderation decision.
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
    /// How long a queued transcription may sit unfulfilled before the UI lets
    /// the operator try again. Local runs can fail (audio fetch, upstream, the
    /// result POST) without the app ever seeing a new transcript.
    @ObservationIgnored
    private let queuedTranscriptionTimeout: TimeInterval
    @ObservationIgnored
    private let now: @Sendable () -> Date
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
    /// State for each queued re-run: the transcription id it started from (so
    /// the marker clears only once a genuinely newer transcript lands) and when
    /// it was queued (so a failed run can't disable the button forever).
    @ObservationIgnored
    private var queuedTranscriptionState: [String: QueuedTranscription] = [:]

    private struct QueuedTranscription {
        var baseline: String?
        var queuedAt: Date
    }

    public private(set) var messages: [Message] = []
    public private(set) var state: LoadState = .idle
    public private(set) var lastUpdated: Date?

    /// IDs of messages with an approve/reject/translation request in flight.
    public private(set) var pendingActions: Set<String> = []
    /// Human-readable message for the most recent failed write action, if any.
    public private(set) var actionError: String?
    /// IDs of messages whose transcription has been handed to the local worker
    /// and hasn't come back yet. Cleared once a newer transcript lands.
    public private(set) var queuedTranscriptions: Set<String> = []

    /// Supplies local transcription re-runs. Set by the app once the worker
    /// host is available; `nil` disables the re-run affordance.
    @ObservationIgnored
    public var transcriptionRerunner: (any TranscriptionRerunRequesting)?

    public init(
        client: any OperatorReviewClient,
        pollInterval: Duration = .seconds(30),
        queuedTranscriptionTimeout: TimeInterval = 300,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.pollInterval = pollInterval
        self.queuedTranscriptionTimeout = queuedTranscriptionTimeout
        self.now = now
    }

    /// Reviewable messages with no succeeded transcription — the primary
    /// enrichment queue now that the Operator no longer solicits transcription.
    public var awaitingTranscription: [Message] {
        messages.filter(\.needsTranscription)
    }

    /// Reviewable messages that already have transcription history — succeeded,
    /// still running, or failed — offered separately so an operator can
    /// deliberately re-run the AI over them. Decided (approved/rejected)
    /// messages are out of scope.
    public var alreadyTranscribed: [Message] {
        messages.filter { $0.isReviewable && $0.latestTranscription != nil }
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

    /// True when a local transcription run has been queued for this message and
    /// no newer transcript has landed yet.
    public func isTranscriptionQueued(_ messageID: String) -> Bool {
        queuedTranscriptions.contains(messageID)
    }

    /// Hands a message to the local worker for transcription. Works both for
    /// messages that have never been transcribed and as a deliberate re-run of
    /// one that already has a transcript — the Operator keeps the history and
    /// the newest succeeded row wins downstream.
    public func requestTranscription(_ message: Message) async {
        guard !pendingActions.contains(message.id) else { return }
        guard let rerunner = transcriptionRerunner else {
            actionError = "Couldn’t start transcription: the Operator worker isn’t running."
            return
        }
        pendingActions.insert(message.id)
        actionError = nil
        defer { pendingActions.remove(message.id) }
        let baseline = message.latestTranscription?.id
        if await rerunner.requestTranscription(messageID: message.id) {
            queuedTranscriptions.insert(message.id)
            queuedTranscriptionState[message.id] = .init(baseline: baseline, queuedAt: now())
        } else {
            actionError = "Couldn’t start transcription: the worker isn’t running, "
                + "or this message is already queued."
        }
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

    /// Clears the "queued" marker for any message whose transcript is now newer
    /// than the one the re-run started from, that has left the window, or whose
    /// run has been outstanding long enough to assume it failed — otherwise a
    /// failed run would disable the retry button forever.
    private func reconcileQueuedTranscriptions() {
        guard !queuedTranscriptions.isEmpty else { return }
        let byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let cutoff = now().addingTimeInterval(-queuedTranscriptionTimeout)
        for id in queuedTranscriptions {
            guard let message = byID[id], let state = queuedTranscriptionState[id] else {
                clearQueuedTranscription(id)
                continue
            }
            if state.queuedAt <= cutoff {
                clearQueuedTranscription(id)
                continue
            }
            if let latest = message.latestTranscription,
               latest.status == .succeeded,
               latest.id != state.baseline {
                clearQueuedTranscription(id)
            }
        }
    }

    private func clearQueuedTranscription(_ messageID: String) {
        queuedTranscriptions.remove(messageID)
        queuedTranscriptionState.removeValue(forKey: messageID)
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
            reconcileQueuedTranscriptions()
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
