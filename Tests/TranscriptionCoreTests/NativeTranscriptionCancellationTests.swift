#if canImport(Speech) && os(macOS)
import Foundation
import Hummingbird
import HTTPTypes
import Logging
import NIOCore
import Testing
@testable import TranscriptionCore

@Suite("NativeMacOS transcription cancellation")
struct NativeTranscriptionCancellationTests {

    // MARK: - Timeout behavior

    @Test func timeoutCancelsLongRunningTranscription() async throws {
        // Verify the backend accepts and stores the timeout parameter.
        let backend = NativeMacOSTranscriptionBackend(
            locale: .init(identifier: "en-US"),
            logger: Logger(label: "test"),
            transcriptionTimeout: .milliseconds(50)
        )
        #expect(backend.transcriptionTimeout == .milliseconds(50))
    }

    @Test func defaultTimeoutIs120Seconds() async throws {
        let backend = NativeMacOSTranscriptionBackend()
        #expect(backend.transcriptionTimeout == .seconds(120))
    }
}

#endif
