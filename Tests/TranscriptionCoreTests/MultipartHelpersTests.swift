import Foundation
import NIOCore
import Testing
@testable import TranscriptionCore

@Suite("MultipartHelpers")
struct MultipartHelpersTests {
    let boundary = "----TestBoundary"

    private func makeMultipartBody(parts: [(name: String, filename: String?, content: [UInt8])]) -> ByteBuffer {
        var bytes: [UInt8] = []
        for part in parts {
            bytes.append(contentsOf: Array("--\(boundary)\r\n".utf8))
            if let filename = part.filename {
                bytes.append(contentsOf: Array(
                    "Content-Disposition: form-data; name=\"\(part.name)\"; filename=\"\(filename)\"\r\n".utf8
                ))
                bytes.append(contentsOf: Array("Content-Type: application/octet-stream\r\n".utf8))
            } else {
                bytes.append(contentsOf: Array(
                    "Content-Disposition: form-data; name=\"\(part.name)\"\r\n".utf8
                ))
            }
            bytes.append(contentsOf: Array("\r\n".utf8))
            bytes.append(contentsOf: part.content)
            bytes.append(contentsOf: Array("\r\n".utf8))
        }
        bytes.append(contentsOf: Array("--\(boundary)--\r\n".utf8))
        return ByteBuffer(bytes: bytes)
    }

    @Test func injectsModelIntoTextOnlyBody() {
        let body = makeMultipartBody(parts: [
            (name: "file", filename: "test.wav", content: Array("fake audio".utf8))
        ])
        let result = MultipartHelpers.injectModelPart(body: body, boundary: boundary, model: "whisper-1")
        #expect(result != nil)

        let resultBytes = result!.getBytes(at: result!.readerIndex, length: result!.readableBytes)!
        let resultStr = String(data: Data(resultBytes), encoding: .utf8)!
        #expect(resultStr.contains("name=\"model\""))
        #expect(resultStr.contains("whisper-1"))
        // Closing boundary is still present
        #expect(resultStr.contains("--\(boundary)--"))
    }

    @Test func injectsModelWithBinaryAudioPayload() {
        // Construct bytes that are invalid UTF-8
        let binaryAudio: [UInt8] = [0xFF, 0xFE, 0x00, 0x01, 0x80, 0x81, 0xC0, 0xC1, 0xF5, 0xF6, 0xF7, 0xF8]
        let body = makeMultipartBody(parts: [
            (name: "file", filename: "audio.wav", content: binaryAudio)
        ])

        // Verify the body is NOT valid UTF-8 (precondition)
        let rawBytes = body.getBytes(at: body.readerIndex, length: body.readableBytes)!
        #expect(String(data: Data(rawBytes), encoding: .utf8) == nil)

        let result = MultipartHelpers.injectModelPart(body: body, boundary: boundary, model: "whisper-1")
        #expect(result != nil)

        // Verify the binary payload is preserved byte-for-byte
        let resultBytes = result!.getBytes(at: result!.readerIndex, length: result!.readableBytes)!
        #expect(resultBytes.contains(contentsOf: binaryAudio))

        // Verify model part was injected (check for ASCII marker)
        let modelPartMarker = Array("name=\"model\"\r\n\r\nwhisper-1".utf8)
        #expect(resultBytes.contains(contentsOf: modelPartMarker))

        // Verify closing boundary is present
        let closeMarker = Array("--\(boundary)--".utf8)
        #expect(resultBytes.contains(contentsOf: closeMarker))
    }

    @Test func returnsNilWhenClosingBoundaryMissing() {
        // Body without closing boundary
        var bytes: [UInt8] = []
        bytes.append(contentsOf: Array("--\(boundary)\r\n".utf8))
        bytes.append(contentsOf: Array("Content-Disposition: form-data; name=\"file\"\r\n\r\n".utf8))
        bytes.append(contentsOf: Array("data".utf8))
        let body = ByteBuffer(bytes: bytes)

        let result = MultipartHelpers.injectModelPart(body: body, boundary: boundary, model: "whisper-1")
        #expect(result == nil)
    }

    @Test func parseBoundaryFromContentType() {
        let ct = "multipart/form-data; boundary=----TestBoundary"
        let parsed = MultipartHelpers.parseBoundary(from: ct)
        #expect(parsed == "----TestBoundary")
    }

    @Test func parseBoundaryWithQuotes() {
        let ct = "multipart/form-data; boundary=\"----QuotedBoundary\""
        let parsed = MultipartHelpers.parseBoundary(from: ct)
        #expect(parsed == "----QuotedBoundary")
    }

    @Test func preservesExistingPartsWithBinaryContent() {
        // Multiple parts: a text part + a binary file part
        let binaryContent: [UInt8] = (0...255).map { $0 } // All possible byte values
        let body = makeMultipartBody(parts: [
            (name: "language", filename: nil, content: Array("en".utf8)),
            (name: "file", filename: "audio.raw", content: binaryContent)
        ])

        let result = MultipartHelpers.injectModelPart(body: body, boundary: boundary, model: "large-v3")
        #expect(result != nil)

        let resultBytes = result!.getBytes(at: result!.readerIndex, length: result!.readableBytes)!
        // Binary content preserved
        #expect(resultBytes.contains(contentsOf: binaryContent))
        // Model injected
        let modelMarker = Array("name=\"model\"\r\n\r\nlarge-v3".utf8)
        #expect(resultBytes.contains(contentsOf: modelMarker))
    }
}

private extension Array where Element: Equatable {
    func contains(contentsOf other: [Element]) -> Bool {
        guard other.count <= count else { return false }
        let end = count - other.count
        for i in 0...end {
            if self[i..<(i + other.count)].elementsEqual(other) {
                return true
            }
        }
        return false
    }
}
