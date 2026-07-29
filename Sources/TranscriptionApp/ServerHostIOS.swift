#if !os(macOS)
import Combine
import Foundation
import TranscriptionReview

/// iOS app state. The embedded HTTP server is macOS-only ("Pro"); on iOS the
/// app is a review/translation client for Operator APIs, so this shim
/// exists purely to satisfy the shared `@EnvironmentObject` plumbing without
/// pulling in Hummingbird, GRDB, or the server stack.
@MainActor
final class ServerHost: ObservableObject {
    init() {}
    init(demo: Bool) {}

    /// No server runs on iOS, so there is nothing to tear down.
    func shutdown() async {}
}

/// There is no push worker on iOS, so transcription can't be run locally; the
/// Review surface reports the refusal instead of silently dropping the request.
extension ServerHost: TranscriptionRerunRequesting {
    func requestTranscription(messageID: String) async -> Bool { false }
}
#endif
