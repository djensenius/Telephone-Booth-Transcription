//
//  OperatorAPIConfig.swift
//  TranscriptionReview
//

import Foundation

/// Base-URL configuration for the Operator API. Seeded from Info.plist
/// (`OperatorAPIBase`) with a safe default, and overridable at runtime via
/// `UserDefaults` so the macOS "Pro" build can point at a self-hosted booth.
public struct OperatorAPIConfig: Sendable {
    public static let defaultsKey = "operatorAPIBaseURL"

    public let baseURL: URL

    public static let shared = OperatorAPIConfig()

    public init(baseURL: URL? = nil) {
        if let baseURL {
            self.baseURL = baseURL
            return
        }
        let plistValue = Bundle.main.object(forInfoDictionaryKey: "OperatorAPIBase") as? String
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey)
        let raw = stored ?? plistValue ?? "https://api.telephonebooth.io"
        self.baseURL = URL(string: raw) ?? URL(string: "https://api.telephonebooth.io")!
    }

    /// Resolves a leading-slash API path against the base URL, preserving any
    /// base path prefix.
    public func url(forPath path: String) -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return baseURL.appendingPathComponent(trimmed)
    }
}
