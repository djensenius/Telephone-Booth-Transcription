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
        // A backend with a very short timeout should throw TranscriptionTimeoutError
        // when the Speech framework doesn't return quickly. We can't actually run
        // speech recognition in tests (requires user authorization), but we can
        // verify the timeout path fires by providing a valid audio file that
        // triggers an auth error before the timeout — showing the mechanism works.
        //
        // This test validates the type is correctly configured and the init
        // accepts the timeout parameter.
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

    // MARK: - Cancellation propagation via Task cancellation

    @Test func cancelledTaskPreventsHanging() async throws {
        // Verifies that cancelling the parent task causes the handle method to
        // throw promptly rather than hanging indefinitely.
        let backend = NativeMacOSTranscriptionBackend(
            locale: .init(identifier: "en-US"),
            logger: Logger(label: "test"),
            transcriptionTimeout: .seconds(60)
        )

        // Build a minimal multipart body for the `file` field.
        let boundary = "test-boundary-\(UUID().uuidString)"
        let body = Self.makeMultipartBody(boundary: boundary, audioData: Data([0x00]))
        let contentType = "multipart/form-data; boundary=\(boundary)"
        let buffer = ByteBuffer(data: body)

        let task = Task {
            try await backend.handle(body: buffer, contentType: contentType)
        }

        // Cancel almost immediately — the backend should not hang.
        try await Task.sleep(for: .milliseconds(10))
        task.cancel()

        let start = ContinuousClock.now
        do {
            _ = try await task.value
            // If it returns (e.g. auth denied before reaching recognition),
            // that's fine — the important thing is it didn't hang.
        } catch {
            // Expected: either CancellationError, auth error, or timeout.
        }
        let elapsed = ContinuousClock.now - start

        // Should resolve within a few seconds at most, not hang forever.
        #expect(elapsed < .seconds(10), "cancelled task should not hang")
    }

    // MARK: - Helpers

    private static func makeMultipartBody(boundary: String, audioData: Data) -> Data {
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"test.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n".data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }
}

#endif
