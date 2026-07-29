import Foundation
import NIOCore

/// Maps an audio MIME type to a sensible file extension so AVFoundation (and
/// upstream servers that content-sniff by filename) can decode the bytes.
enum AudioExtension {
    static func from(mimeType: String?) -> String? {
        guard let m = mimeType?.lowercased() else { return nil }
        switch m {
        case "audio/wav", "audio/wave", "audio/x-wav":           return "wav"
        case "audio/mpeg", "audio/mp3":                          return "mp3"
        case "audio/mp4", "audio/m4a", "audio/x-m4a":            return "m4a"
        case "audio/aac":                                        return "aac"
        case "audio/ogg", "audio/opus":                          return "ogg"
        case "audio/flac", "audio/x-flac":                       return "flac"
        case "audio/webm":                                       return "webm"
        default:                                                 return nil
        }
    }
}

/// Result of extracting the `file` field from a multipart body.
struct MultipartFilePart {
    let filename: String?
    let mimeType: String?
    let data: ByteBuffer

    /// Delimiter-correct extraction of the `file` part from a `multipart/form-data`
    /// body. Works directly on `ByteBuffer` without copying the entire body into
    /// `Data` or `[UInt8]`.
    ///
    /// The parser only recognizes boundary delimiters that are preceded by CRLF
    /// (or appear at offset 0), preventing false matches against binary content
    /// that happens to contain boundary-like byte sequences.
    ///
    /// Returns nil if the body isn't multipart, the boundary can't be parsed,
    /// or no part with `name="file"` is present.
    static func extractFile(from buffer: ByteBuffer, contentType: String) -> MultipartFilePart? {
        extractPart(named: "file", from: buffer, contentType: contentType)
    }

    /// Reads a short text part (e.g. `language`) as a trimmed UTF-8 string.
    /// Returns nil when the part is absent or empty.
    static func extractTextValue(
        named name: String,
        from buffer: ByteBuffer,
        contentType: String
    ) -> String? {
        guard let part = extractPart(named: name, from: buffer, contentType: contentType),
              let data = part.data.getData(at: part.data.readerIndex, length: part.data.readableBytes),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Shared parser backing `extractFile` and `extractTextValue`.
    static func extractPart(
        named name: String,
        from buffer: ByteBuffer,
        contentType: String
    ) -> MultipartFilePart? {
        guard let boundary = MultipartHelpers.parseBoundary(from: contentType),
              !boundary.isEmpty else { return nil }

        let view = buffer.readableBytesView
        guard !view.isEmpty else { return nil }

        let delimiter: [UInt8] = Array("--\(boundary)".utf8)
        let crlf: [UInt8] = [0x0D, 0x0A]
        let headerSep: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]

        // Locate all boundary positions that are correctly framed:
        // either at the very start of the body or preceded by CRLF.
        let positions = Self.findDelimiters(in: view, delimiter: delimiter, crlf: crlf)
        guard positions.count >= 2 else { return nil }

        // Each part sits between consecutive delimiter positions.
        // The content starts after the delimiter line (delimiter + CRLF or delimiter + "--").
        for i in 0..<(positions.count - 1) {
            let delimStart = positions[i]
            let nextDelimStart = positions[i + 1]

            // Skip past delimiter bytes.
            var contentStart = delimStart + delimiter.count
            // Check for closing marker `--` — skip this "part".
            if contentStart + 1 < view.endIndex,
               view[contentStart] == 0x2D, view[contentStart + 1] == 0x2D {
                continue
            }
            // Skip the CRLF after the delimiter line.
            if contentStart + 1 < view.endIndex,
               view[contentStart] == 0x0D, view[contentStart + 1] == 0x0A {
                contentStart += 2
            }

            // The part content ends where the next delimiter's preceding CRLF begins.
            var contentEnd = nextDelimStart
            // Strip the CRLF that precedes the next boundary marker.
            if contentEnd >= 2,
               view[contentEnd - 2] == 0x0D, view[contentEnd - 1] == 0x0A {
                contentEnd -= 2
            }

            guard contentStart < contentEnd else { continue }

            // Find header/body separator (CRLFCRLF).
            guard let sepOffset = Self.findSequence(headerSep, in: view, from: contentStart, to: contentEnd) else {
                continue
            }
            let headersEnd = sepOffset
            let bodyStart = sepOffset + headerSep.count

            // Parse headers (they're always ASCII/UTF-8).
            let headersSlice = view[contentStart..<headersEnd]
            guard let headers = String(bytes: headersSlice, encoding: .utf8) else { continue }
            guard Self.hasExactNameParameter(headers, name: name) else { continue }

            let filename = Self.matchHeader(headers, key: "filename")
            let mimeType = Self.matchHeader(headers, key: "Content-Type", isCT: true)

            // Return a zero-copy slice of the buffer for the body.
            let bodyLength = contentEnd - bodyStart
            let sliceStart = bodyStart - view.startIndex + buffer.readerIndex
            guard let bodyBuffer = buffer.getSlice(at: sliceStart, length: bodyLength) else {
                continue
            }
            return MultipartFilePart(filename: filename, mimeType: mimeType, data: bodyBuffer)
        }
        return nil
    }

    /// Find all positions in `view` where `delimiter` appears, only accepting
    /// matches that are at position 0 or preceded by `crlf`, AND followed by
    /// CRLF or `--` (per RFC 2046 boundary line framing).
    private static func findDelimiters(
        in view: ByteBufferView,
        delimiter: [UInt8],
        crlf: [UInt8]
    ) -> [ByteBufferView.Index] {
        var positions: [ByteBufferView.Index] = []
        var searchFrom = view.startIndex

        while searchFrom <= view.endIndex - delimiter.count {
            guard let pos = Self.findSequence(delimiter, in: view, from: searchFrom, to: view.endIndex) else {
                break
            }

            let isFramed: Bool
            if pos == view.startIndex {
                isFramed = true
            } else if pos >= view.startIndex + crlf.count {
                isFramed = view[pos - 2] == crlf[0] && view[pos - 1] == crlf[1]
            } else {
                isFramed = false
            }

            // Also verify post-boundary terminator: must be CRLF or "--".
            let afterDelim = pos + delimiter.count
            let hasValidSuffix: Bool
            if afterDelim + 1 < view.endIndex {
                let b0 = view[afterDelim]
                let b1 = view[afterDelim + 1]
                hasValidSuffix = (b0 == 0x0D && b1 == 0x0A) || (b0 == 0x2D && b1 == 0x2D)
            } else if afterDelim == view.endIndex {
                // Boundary at very end of body (no trailing bytes) — valid closing.
                hasValidSuffix = true
            } else {
                hasValidSuffix = false
            }

            if isFramed && hasValidSuffix {
                positions.append(pos)
            }
            searchFrom = pos + 1
        }
        return positions
    }

    /// Locate the first occurrence of `needle` in `view[from..<to]`.
    private static func findSequence(
        _ needle: [UInt8],
        in view: ByteBufferView,
        from start: ByteBufferView.Index,
        to end: ByteBufferView.Index
    ) -> ByteBufferView.Index? {
        guard needle.count > 0, end - start >= needle.count else { return nil }
        let limit = end - needle.count
        var i = start
        while i <= limit {
            var matched = true
            for j in 0..<needle.count {
                if view[i + j] != needle[j] {
                    matched = false
                    break
                }
            }
            if matched { return i }
            i += 1
        }
        return nil
    }

    private static func matchHeader(_ headers: String, key: String, isCT: Bool = false) -> String? {
        if isCT {
            for line in headers.split(separator: "\r\n") {
                let l = String(line).trimmingCharacters(in: .whitespaces)
                if l.lowercased().hasPrefix("content-type:") {
                    return l.dropFirst("Content-Type:".count).trimmingCharacters(in: .whitespaces)
                }
            }
            return nil
        }
        let needle = "\(key)=\""
        guard let r = headers.range(of: needle) else { return nil }
        let rest = headers[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// Check if the Content-Disposition header contains an exact `name="<name>"` parameter.
    /// Prevents false positives like matching `name="file2"` when looking for `name="file"`.
    private static func hasExactNameParameter(_ headers: String, name: String) -> Bool {
        let needle = "name=\"\(name)\""
        var searchStart = headers.startIndex
        while let range = headers.range(of: needle, range: searchStart..<headers.endIndex) {
            // Verify the character after the closing quote isn't alphanumeric (no "file2" match).
            let afterEnd = range.upperBound
            if afterEnd == headers.endIndex || !headers[afterEnd].isLetter && !headers[afterEnd].isNumber {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }
}
