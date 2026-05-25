import Foundation

/// Deterministic errors surfaced when upstream response collection fails.
///
/// Route handlers can pattern-match on these to return structured 502/504
/// responses to callers.
public enum UpstreamError: Error, Sendable, Equatable {
    /// The upstream response body exceeded the endpoint-specific size cap.
    case responseTooLarge(maxBytes: Int)

    /// The upstream response was not fully received within the configured
    /// deadline (includes both the request execution and body collection phases).
    case deadlineExceeded
}
