import Foundation
import Testing
@testable import TranscriptionOnDevice

/// The engines these probe are unavailable on CI and the simulator, so the
/// tests assert the invariants that must hold on *any* machine rather than a
/// fixed answer.
@Suite("OnDeviceCapability")
struct OnDeviceCapabilityTests {
    /// The locale-aware probe narrows the device-wide one: it can say no where
    /// the device-wide check says yes, but never the reverse.
    @Test func localeProbeNeverExceedsDeviceProbe() async {
        let device = OnDeviceCapability.isSpeechTranscriptionAvailable
        for identifier in ["en-US", "fr-FR", "zz-ZZ"] {
            let locale = await OnDeviceCapability.isSpeechTranscriptionAvailable(
                for: Locale(identifier: identifier)
            )
            #expect(!locale || device, "\(identifier) reported supported on a device that can't transcribe")
        }
    }

    /// A locale the OS has never heard of has no `SpeechTranscriber`
    /// equivalent, so the probe must refuse it even on a capable device —
    /// that's the case the old device-wide-only gate got wrong.
    @Test func rejectsAnUnknownLocale() async {
        let supported = await OnDeviceCapability.isSpeechTranscriptionAvailable(
            for: Locale(identifier: "zz-ZZ")
        )
        #expect(supported == false)
    }

    @Test func fullPipelineRequiresBothEngines() {
        #expect(OnDeviceCapability.isFullPipelineAvailable
                == (OnDeviceCapability.isSpeechTranscriptionAvailable
                    && OnDeviceCapability.isFoundationModelAvailable))
    }
}
