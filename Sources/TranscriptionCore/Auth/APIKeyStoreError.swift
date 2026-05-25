import Foundation

public enum APIKeyStoreError: Error, Sendable, Equatable {
    case keychainStatus(OSStatus)
    case encodingFailed
}
