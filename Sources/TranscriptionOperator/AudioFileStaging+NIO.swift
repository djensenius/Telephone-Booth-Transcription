import Foundation
import NIOCore
import TranscriptionPipeline

private struct ByteBufferDataSequence<Base: AsyncSequence & Sendable>: AsyncSequence, Sendable
where Base.Element == ByteBuffer {
    typealias Element = Data

    let base: Base

    struct AsyncIterator: AsyncIteratorProtocol {
        var base: Base.AsyncIterator

        mutating func next() async throws -> Data? {
            guard let buffer = try await base.next() else { return nil }
            return Data(buffer.readableBytesView)
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator())
    }
}

public extension AudioFileStaging {
    /// Compatibility overload for existing `TranscriptionOperator` consumers.
    static func stage<S: AsyncSequence & Sendable, T: Sendable>(
        chunks: S,
        expectedSHA256: String,
        maxBytes: Int,
        suggestedExtension: String?,
        _ body: @Sendable (URL) async throws -> T
    ) async throws -> T where S.Element == ByteBuffer {
        return try await AudioFileStaging.stage(
            chunks: ByteBufferDataSequence(base: chunks),
            expectedSHA256: expectedSHA256,
            maxBytes: maxBytes,
            suggestedExtension: suggestedExtension,
            body
        )
    }
}
