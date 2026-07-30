import Foundation
import Testing
@testable import TranscriptionOnDevice

/// The engines these probe are unavailable on CI and the simulator, so the
/// tests assert what must hold on *any* machine rather than a fixed answer.
/// Nothing here compares two separately sampled reads of live OS state: the
/// documentation is explicit that availability can change while the app runs,
/// so such a comparison would be nondeterministic on a capable device.
@Suite("OnDeviceCapability")
struct OnDeviceCapabilityTests {
    /// A locale the OS has never heard of has no `SpeechTranscriber`
    /// equivalent, so the probe must refuse it on every device, capable or
    /// not — that's the case the old device-wide-only gate got wrong.
    @Test(arguments: ["zz-ZZ", "qq", "xx-QQ"])
    func rejectsAnUnknownLocale(identifier: String) async {
        let supported = await OnDeviceCapability.isSpeechTranscriptionAvailable(
            for: Locale(identifier: identifier)
        )
        #expect(supported == false)
    }

    @Test func fullPipelineRequiresBothEngines() {
        #expect(OnDeviceCapability.isFullPipelineAvailable
                == (OnDeviceCapability.isSpeechTranscriptionAvailable
                    && OnDeviceCapability.isFoundationModelAvailable))
    }
}
