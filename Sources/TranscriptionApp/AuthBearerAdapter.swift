import Foundation
import TranscriptionAuth
import TranscriptionReview

/// Bridges the OIDC `AuthManager` to the review module's `BearerTokenProviding`
/// protocol, keeping `TranscriptionReview` free of any auth-stack dependency.
struct AuthBearerAdapter: BearerTokenProviding {
    func authorizationHeader() async -> String? {
        await AuthManager.shared.authorizationHeader()
    }
}
