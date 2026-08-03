import Crypto
import Foundation
import TranscriptionShared

/// Errors raised while fetching and verifying job audio. Messages are fixed
/// and content-free; the dispatcher maps these onto sanitized
/// `OperatorJobError`s. None of these values ever carry the audio URL, bytes,
/// filename, or hash.
public enum AudioFetchError: Error, Sendable, Equatable {
    /// `expectedSHA256` was not a 64-character hex string.
    case invalidExpectedHash
    /// The download exceeded `maxBytes` before completing.
    case tooLarge
    /// The fully-downloaded bytes did not hash to `expectedSHA256`.
    case hashMismatch
    /// The audio URL was not an `https` URL (and insecure URLs are disallowed).
    case insecureURL
    /// The transport failed (DNS/connect/TLS/HTTP status). Detail is the
    /// sanitized error *type*, never the URL or response body.
    case fetchFailed
}

/// Downloads job audio to a private, short-lived temp file and hands the file
/// URL to a closure. The file (and its containing directory) are always removed
/// before the call returns, on every path including cancellation and throws.
public protocol AudioFetching: Sendable {
    /// Streams the audio at `url` to a temp file, enforcing `maxBytes` and
    /// verifying it hashes to `expectedSHA256`, then invokes `body` with the
    /// on-disk URL and returns its result.
    func withFetchedAudioFile<T: Sendable>(
        url: String,
        expectedSHA256: String,
        maxBytes: Int,
        suggestedExtension: String?,
        _ body: @Sendable (URL) async throws -> T
    ) async throws -> T
}

/// Reusable staging core shared by the URLSession fetcher and tests. Given any
/// `AsyncSequence` of `Data` chunks, it writes to a private temp file while
/// hashing and enforcing a byte cap, verifies the digest, runs `body`, and
/// always cleans up.
public enum AudioFileStaging {
    /// Normalizes a sha256 hex string to lowercase, or returns nil if it is not
    /// exactly 64 hexadecimal characters.
    public static func normalizedSHA256(_ value: String) -> String? {
        guard value.count == 64 else { return nil }
        var lowered = ""
        lowered.reserveCapacity(64)
        for character in value {
            switch character {
            case "0"..."9", "a"..."f":
                lowered.append(character)
            case "A"..."F":
                lowered.append(Character(character.lowercased()))
            default:
                return nil
            }
        }
        return lowered
    }

    public static func stage<S: AsyncSequence & Sendable, T: Sendable>(
        chunks: S,
        expectedSHA256: String,
        maxBytes: Int,
        suggestedExtension: String?,
        _ body: @Sendable (URL) async throws -> T
    ) async throws -> T where S.Element == Data {
        guard let expected = normalizedSHA256(expectedSHA256) else {
            throw AudioFetchError.invalidExpectedHash
        }

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("tbt-audio-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: directory) }

        let ext = Self.sanitizedExtension(suggestedExtension)
        let fileURL = directory.appendingPathComponent("audio\(ext)")
        guard fileManager.createFile(atPath: fileURL.path, contents: nil) else {
            throw AudioFetchError.fetchFailed
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        var handleClosed = false
        func closeHandle() {
            guard !handleClosed else { return }
            handleClosed = true
            try? handle.close()
        }
        defer { closeHandle() }

        var hasher = SHA256()
        var total = 0
        do {
            for try await chunk in chunks {
                let readable = chunk.count
                guard readable > 0 else { continue }
                total += readable
                if total > maxBytes {
                    throw AudioFetchError.tooLarge
                }
                hasher.update(data: chunk)
                try handle.write(contentsOf: chunk)
            }
        } catch let error as AudioFetchError {
            throw error
        } catch {
            throw AudioFetchError.fetchFailed
        }
        closeHandle()

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expected else {
            throw AudioFetchError.hashMismatch
        }

        return try await body(fileURL)
    }

    private static func sanitizedExtension(_ suggested: String?) -> String {
        guard let suggested, !suggested.isEmpty else { return ".flac" }
        // Accept only an alphanumeric extension; ignore full filenames or
        // anything with path separators to avoid traversal or odd names.
        let raw = suggested.hasPrefix(".") ? String(suggested.dropFirst()) : suggested
        guard !raw.isEmpty, raw.count <= 8, raw.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return ".flac"
        }
        return "." + raw.lowercased()
    }
}
