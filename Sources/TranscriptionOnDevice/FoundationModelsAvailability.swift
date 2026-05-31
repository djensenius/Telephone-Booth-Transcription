import Foundation
import TranscriptionShared

#if canImport(FoundationModels)
import FoundationModels

/// Shared availability checks and error mapping for the on-device Foundation
/// Models services.
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
enum FoundationModelsAvailability {
    /// Throws `OnDeviceServiceError.unavailable` unless `model` reports it is
    /// ready to use (Apple Intelligence enabled, device eligible, model
    /// downloaded).
    static func ensureAvailable(_ model: SystemLanguageModel) throws {
        switch model.availability {
        case .available:
            return
        case .unavailable(let reason):
            throw OnDeviceServiceError.unavailable(
                "Apple Intelligence language model unavailable (\(describe(reason)))."
            )
        }
    }

    /// Maps a `LanguageModelSession.GenerationError` onto the transport-agnostic
    /// `OnDeviceServiceError` so HTTP adapters and in-process callers handle it
    /// consistently.
    static func map(_ error: LanguageModelSession.GenerationError) -> OnDeviceServiceError {
        switch error {
        case .exceededContextWindowSize:
            return .badRequest("Input is too long for the on-device model.")
        case .guardrailViolation, .refusal:
            return .badRequest("The on-device model declined to process this input.")
        case .unsupportedLanguageOrLocale:
            return .badRequest("The input language is not supported by the on-device model.")
        case .rateLimited, .concurrentRequests:
            // Transient backpressure — caller should retry, so surface a timeout
            // (504) rather than a permanent capability failure.
            return .timeout("The on-device model is busy. Try again.")
        case .assetsUnavailable:
            return .unavailable("On-device model assets are not available.")
        default:
            return .unavailable("On-device generation failed.")
        }
    }

    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "device not eligible"
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence not enabled"
        case .modelNotReady:
            return "model not ready"
        @unknown default:
            return "unknown reason"
        }
    }
}
#endif
