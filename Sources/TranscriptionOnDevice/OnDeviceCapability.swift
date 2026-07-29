import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(Speech)
import Speech
#endif

/// Pre-flight probes for the on-device engines.
///
/// The services themselves re-check availability at use time, because Apple
/// Intelligence can be switched off or a model evicted between the probe and
/// the call. These exist so a caller can decide whether to *offer* a feature at
/// all: an `@available` compile/OS check alone is not enough, since a device can
/// run iOS 26 and still have no eligible hardware, have Apple Intelligence
/// disabled, or not have finished downloading the model.
public enum OnDeviceCapability {
    /// True when `SpeechTranscriber` can run on this device right now.
    public static var isSpeechTranscriptionAvailable: Bool {
        #if canImport(Speech)
        if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
            return SpeechTranscriber.isAvailable
        }
        #endif
        return false
    }

    /// True when the Foundation Models language model is ready to use.
    ///
    /// Probed with the same configuration the translation and moderation
    /// services use, so this can't report available for a model they would then
    /// be refused.
    public static var isFoundationModelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
            let model = SystemLanguageModel(
                useCase: .general,
                guardrails: .permissiveContentTransformations
            )
            if case .available = model.availability { return true }
        }
        #endif
        return false
    }

    /// True when the whole on-device review pipeline (transcribe → translate →
    /// moderate) can run.
    public static var isFullPipelineAvailable: Bool {
        isSpeechTranscriptionAvailable && isFoundationModelAvailable
    }
}
