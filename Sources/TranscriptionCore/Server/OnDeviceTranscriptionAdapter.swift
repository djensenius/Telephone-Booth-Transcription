import Foundation
import Hummingbird
import HTTPTypes
import NIOCore
import TranscriptionShared

/// Bridges a transport-agnostic `AudioTranscriber` into the HTTP server's
/// multipart-in / OpenAI-JSON-out shape. Both on-device backends share this:
/// they only differ in which transcriber they construct.
enum OnDeviceTranscriptionAdapter {
    /// Parses the multipart `file` part, writes it to a temp file, runs the
    /// supplied transcribe closure, and returns the `{"text": …}` response.
    /// Maps `OnDeviceServiceError` onto the server's `TranscriptionBackendError`.
    static func run(
        body: ByteBuffer,
        contentType: String,
        transcribe: (URL) async throws -> String
    ) async throws -> Response {
        let text: String
        do {
            text = try await OnDeviceAudioFile.withTemporaryFile(
                body: body,
                contentType: contentType,
                perform: transcribe
            )
        } catch let error as OnDeviceServiceError {
            throw error.asTranscriptionBackendError
        }

        let payload = ["text": text]
        let data = try JSONEncoder().encode(payload)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }
}

/// Extracts the multipart `file` part into a temporary file on disk, hands the
/// URL to `perform`, and cleans up afterwards. Shared by every on-device
/// backend that needs a file URL to feed the Speech framework.
///
/// Throws `OnDeviceServiceError.badRequest` for malformed bodies so callers can
/// map it onto their own route error type.
enum OnDeviceAudioFile {
    static func withTemporaryFile<T>(
        body: ByteBuffer,
        contentType: String,
        perform: (URL) async throws -> T
    ) async throws -> T {
        guard let part = MultipartFilePart.extractFile(from: body, contentType: contentType) else {
            throw OnDeviceServiceError.badRequest("multipart body did not include a `file` field")
        }

        let ext = AudioExtension.from(mimeType: part.mimeType) ?? "wav"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcription-\(UUID().uuidString).\(ext)")
        var buf = part.data
        guard let fileData = buf.readData(length: buf.readableBytes) else {
            throw OnDeviceServiceError.badRequest("failed to read audio data from multipart body")
        }
        try fileData.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        return try await perform(tmp)
    }
}

extension OnDeviceServiceError {
    /// Maps the transport-agnostic on-device error onto the HTTP route's error
    /// type. `.unavailable` maps to `.unauthorized` to preserve the prior
    /// 403 behavior for "engine not available on this device".
    var asTranscriptionBackendError: TranscriptionBackendError {
        switch self {
        case .badRequest(let message): return .badRequest(message)
        case .unauthorized(let message): return .unauthorized(message)
        case .timeout(let message): return .timeout(message)
        case .unavailable(let message): return .unauthorized(message)
        }
    }
}
