import Crypto
import Foundation
import NIOCore
import Testing
import TranscriptionOperator
import TranscriptionShared

@Suite("AudioFileStaging")
struct AudioFileStagingTests {
    private func stream(_ chunks: [Data]) -> AsyncStream<ByteBuffer> {
        AsyncStream { continuation in
            for chunk in chunks {
                continuation.yield(ByteBuffer(bytes: chunk))
            }
            continuation.finish()
        }
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test func normalizesAndVerifiesMatchingDigest() async throws {
        let payload = Data("hello whisper world".utf8)
        let hex = sha256Hex(payload)
        let chunks = [Data(payload.prefix(5)), Data(payload.dropFirst(5))]

        let staged: Data = try await AudioFileStaging.stage(
            chunks: stream(chunks),
            expectedSHA256: hex.uppercased(),
            maxBytes: 1_000,
            suggestedExtension: "flac"
        ) { url in
            try Data(contentsOf: url)
        }
        #expect(staged == payload)
    }

    @Test func cleansUpTempFileAfterBody() async throws {
        let payload = Data("cleanup".utf8)
        let captured: URL = try await AudioFileStaging.stage(
            chunks: stream([payload]),
            expectedSHA256: sha256Hex(payload),
            maxBytes: 1_000,
            suggestedExtension: nil
        ) { $0 }
        #expect(FileManager.default.fileExists(atPath: captured.path) == false)
    }

    @Test func rejectsInvalidExpectedHash() async {
        let payload = Data("x".utf8)
        await #expect(throws: AudioFetchError.invalidExpectedHash) {
            _ = try await AudioFileStaging.stage(
                chunks: stream([payload]),
                expectedSHA256: "not-a-hash",
                maxBytes: 1_000,
                suggestedExtension: nil
            ) { _ in 0 }
        }
    }

    @Test func detectsDigestMismatch() async {
        let payload = Data("real audio".utf8)
        let wrong = String(repeating: "a", count: 64)
        await #expect(throws: AudioFetchError.hashMismatch) {
            _ = try await AudioFileStaging.stage(
                chunks: stream([payload]),
                expectedSHA256: wrong,
                maxBytes: 1_000,
                suggestedExtension: nil
            ) { _ in 0 }
        }
    }

    @Test func enforcesByteCap() async {
        let payload = Data(repeating: 0x41, count: 2_048)
        await #expect(throws: AudioFetchError.tooLarge) {
            _ = try await AudioFileStaging.stage(
                chunks: stream([payload]),
                expectedSHA256: sha256Hex(payload),
                maxBytes: 1_024,
                suggestedExtension: nil
            ) { _ in 0 }
        }
    }

    @Test func normalizedSHA256Validation() {
        #expect(AudioFileStaging.normalizedSHA256(String(repeating: "A", count: 64)) == String(repeating: "a", count: 64))
        #expect(AudioFileStaging.normalizedSHA256(String(repeating: "g", count: 64)) == nil)
        #expect(AudioFileStaging.normalizedSHA256("abc") == nil)
    }
}
