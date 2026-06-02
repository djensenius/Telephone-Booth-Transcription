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

    public private(set) var messages: [Message] = []
    public private(set) var state: LoadState = .idle
    public private(set) var lastUpdated: Date?

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
        do {
            // The Operator returns newest-first; we surface the most recent
            // page. Active review work is expected to live within this window.
            let list = try await client.fetchMessages(status: nil, since: nil, limit: 100)
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
