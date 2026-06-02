//
//  OperatorJSON.swift
//  TranscriptionReview
//
//  JSON coder configured for the Operator API's ISO-8601 timestamps
//  (with or without fractional seconds).
//

import Foundation

public enum OperatorJSON {
    nonisolated(unsafe) static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) static let isoBasic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = isoFractional.date(from: raw) ?? isoBasic.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported date format: \(raw)"
            )
        }
        return decoder
    }()

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(isoFractional.string(from: date))
        }
        return encoder
    }()

    /// Formats a `Date` as an ISO-8601 string with fractional seconds,
    /// suitable for use in query parameters.
    public static func iso8601String(from date: Date) -> String {
        isoFractional.string(from: date)
    }
}
