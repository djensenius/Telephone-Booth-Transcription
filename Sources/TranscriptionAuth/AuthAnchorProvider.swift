//
//  AuthAnchorProvider.swift
//  TranscriptionAuth
//
//  Cross-platform presentation anchor for ASWebAuthenticationSession on
//  macOS and iOS / iPadOS.
//

import AuthenticationServices
import Foundation
import os

#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

private let logger = Logger(
    subsystem: "org.davidjensenius.TelephoneBoothTranscription.auth",
    category: "AuthAnchorProvider"
)

/// Provides a presentation anchor for ASWebAuthenticationSession.
final class AuthAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        return NSApp.keyWindow ?? NSWindow()
        #elseif canImport(UIKit)
        let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for windowScene in windowScenes {
            if let key = windowScene.windows.first(where: { $0.isKeyWindow }) {
                return key
            }
            if let first = windowScene.windows.first {
                return first
            }
        }
        if let windowScene = windowScenes.first {
            logger.warning("No key window found — creating a window for the active scene")
            return UIWindow(windowScene: windowScene)
        }
        // The system only requests a presentation anchor while the app is
        // foregrounded, so at least one window scene is always present here.
        preconditionFailure("No UIWindowScene available to anchor authentication")
        #else
        return ASPresentationAnchor()
        #endif
    }
}
