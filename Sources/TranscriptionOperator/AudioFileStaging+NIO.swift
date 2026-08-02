import Foundation
import NIOCore
import TranscriptionPipeline

public extension AudioFileStaging {
    /// Compatibility overload for existing `TranscriptionOperator` consumers.
    static func stage<S: AsyncSequence & Sendable, T: Sendable>(
        chunks: S,
        expectedSHA256: String,
        maxBytes: Int,
        suggestedExtension: String?,
        _ body: @Sendable (URL) async throws -> T
    ) async throws -> T where S.Element == ByteBuffer {
        let dataChunks = AsyncThrowingStream<Data, any Error> { continuation in
            Task {
                do {
                    for try await chunk in chunks {
                        continuation.yield(Data(chunk.readableBytesView))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
        return try await AudioFileStaging.stage(
            chunks: dataChunks,
            expectedSHA256: expectedSHA256,
            maxBytes: maxBytes,
            suggestedExtension: suggestedExtension,
            body
        )
    }
}
