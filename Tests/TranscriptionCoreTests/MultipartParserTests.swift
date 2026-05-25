import Foundation
import NIOCore
import Testing
@testable import TranscriptionCore

@Suite("MultipartFilePart.extractFile")
struct MultipartParserTests {

    // MARK: - Helpers

    private func makeMultipartBody(
        boundary: String,
        parts: [(headers: String, body: [UInt8])]
    ) -> ByteBuffer {
        var bytes: [UInt8] = []
        for part in parts {
            bytes.append(contentsOf: "--\(boundary)\r\n".utf8)
            bytes.append(contentsOf: part.headers.utf8)
            bytes.append(contentsOf: [0x0D, 0x0A, 0x0D, 0x0A]) // CRLFCRLF
            bytes.append(contentsOf: part.body)
            bytes.append(contentsOf: [0x0D, 0x0A]) // trailing CRLF before next boundary
        }
        bytes.append(contentsOf: "--\(boundary)--\r\n".utf8)
        return ByteBuffer(bytes: bytes)
    }

    private func contentType(boundary: String) -> String {
        "multipart/form-data; boundary=\(boundary)"
    }

    // MARK: - Tests

    @Test func extractsFilePartFromNormalMultipartBody() {
        let boundary = "----WebKitFormBoundary7MA4YWxkTrZu0gW"
        let audioBytes: [UInt8] = Array(repeating: 0xAB, count: 256)
        let body = makeMultipartBody(boundary: boundary, parts: [
            (headers: "Content-Disposition: form-data; name=\"model\"\r\nContent-Type: text/plain",
             body: Array("whisper-1".utf8)),
            (headers: "Content-Disposition: form-data; name=\"file\"; filename=\"test.wav\"\r\nContent-Type: audio/wav",
             body: audioBytes)
        ])

        let result = MultipartFilePart.extractFile(from: body, contentType: contentType(boundary: boundary))
        #expect(result != nil)
        #expect(result?.filename == "test.wav")
        #expect(result?.mimeType == "audio/wav")
        #expect(result?.data.readableBytes == 256)
        if let data = result?.data {
            let extracted = data.getBytes(at: data.readerIndex, length: data.readableBytes)!
            #expect(extracted == audioBytes)
        }
    }

    @Test func doesNotFalseMatchBoundaryInsideBinaryContent() {
        let boundary = "ABCD1234"
        // Craft binary content that contains the boundary string inside the file body.
        var fakeContent: [UInt8] = Array(repeating: 0xFF, count: 100)
        fakeContent.append(contentsOf: "--ABCD1234".utf8) // embedded boundary-like bytes
        fakeContent.append(contentsOf: Array(repeating: 0xEE, count: 100))

        let body = makeMultipartBody(boundary: boundary, parts: [
            (headers: "Content-Disposition: form-data; name=\"file\"; filename=\"audio.mp3\"\r\nContent-Type: audio/mpeg",
             body: fakeContent)
        ])

        let result = MultipartFilePart.extractFile(from: body, contentType: contentType(boundary: boundary))
        #expect(result != nil)
        #expect(result?.data.readableBytes == fakeContent.count)
        if let data = result?.data {
            let extracted = data.getBytes(at: data.readerIndex, length: data.readableBytes)!
            #expect(extracted == fakeContent)
        }
    }

    @Test func handlesLargeBody() {
        let boundary = "LargeBoundary123"
        let largeAudio: [UInt8] = Array(repeating: 0x42, count: 2 * 1024 * 1024) // 2 MB

        let body = makeMultipartBody(boundary: boundary, parts: [
            (headers: "Content-Disposition: form-data; name=\"file\"; filename=\"big.wav\"\r\nContent-Type: audio/wav",
             body: largeAudio)
        ])

        let result = MultipartFilePart.extractFile(from: body, contentType: contentType(boundary: boundary))
        #expect(result != nil)
        #expect(result?.data.readableBytes == largeAudio.count)
    }

    @Test func returnsOnlyFilePartWhenMultiplePartsPresent() {
        let boundary = "MultiBound"
        let body = makeMultipartBody(boundary: boundary, parts: [
            (headers: "Content-Disposition: form-data; name=\"model\"",
             body: Array("whisper-1".utf8)),
            (headers: "Content-Disposition: form-data; name=\"language\"",
             body: Array("en".utf8)),
            (headers: "Content-Disposition: form-data; name=\"file\"; filename=\"speech.m4a\"\r\nContent-Type: audio/m4a",
             body: Array(repeating: 0xCC, count: 64))
        ])

        let result = MultipartFilePart.extractFile(from: body, contentType: contentType(boundary: boundary))
        #expect(result != nil)
        #expect(result?.filename == "speech.m4a")
        #expect(result?.mimeType == "audio/m4a")
        #expect(result?.data.readableBytes == 64)
    }

    @Test func returnsNilWhenNoFileFieldPresent() {
        let boundary = "NoFileBound"
        let body = makeMultipartBody(boundary: boundary, parts: [
            (headers: "Content-Disposition: form-data; name=\"model\"",
             body: Array("whisper-1".utf8))
        ])

        let result = MultipartFilePart.extractFile(from: body, contentType: contentType(boundary: boundary))
        #expect(result == nil)
    }

    @Test func parsesQuotedBoundary() {
        let boundary = "QuotedBound99"
        let ct = "multipart/form-data; boundary=\"\(boundary)\""
        let body = makeMultipartBody(boundary: boundary, parts: [
            (headers: "Content-Disposition: form-data; name=\"file\"; filename=\"q.wav\"\r\nContent-Type: audio/wav",
             body: [0x01, 0x02, 0x03])
        ])

        let result = MultipartFilePart.extractFile(from: body, contentType: ct)
        #expect(result != nil)
        #expect(result?.data.readableBytes == 3)
    }

    @Test func returnsNilForNonMultipartContentType() {
        let buffer = ByteBuffer(string: "just plain text")
        let result = MultipartFilePart.extractFile(from: buffer, contentType: "text/plain")
        #expect(result == nil)
    }
}
