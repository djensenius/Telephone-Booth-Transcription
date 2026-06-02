//
//  AppAuthConfig.swift
//  TranscriptionAuth
//
//  OIDC configuration for the Transcription app. The app reuses the same
//  Authentik provider as the Operator mobile app (same issuer + client ID +
//  scopes) and only registers its own redirect URI, so signing in here yields
//  bearer tokens the Operator API accepts.
//
//  Defaults come from Info.plist (so CI builds and unit tests pick up safe
//  values) and fall back to the shared Operator provider when absent.
//

import Foundation

/// Static OIDC configuration. Changing identity providers at runtime would
/// invalidate stored tokens and is intentionally unsupported.
public struct AppAuthConfig: Sendable {
    /// The OIDC issuer base URL (the per-app Authentik application path).
    public let oidcIssuerBase: String

    /// The OIDC client ID registered with Authentik as a public, PKCE-only client.
    public let oidcClientID: String

    /// Custom URL scheme used for the OAuth redirect callback. Must match the
    /// app's `CFBundleURLTypes` entry and be registered on the Authentik provider.
    public let redirectScheme: String

    /// Full redirect URI registered with Authentik for this app.
    public let redirectURI: String

    /// OIDC scopes requested at sign-in time.
    public let oidcScopes: String

    /// The shared configuration, seeded from Info.plist with safe fallbacks.
    public static let shared = AppAuthConfig()

    public init(
        oidcIssuerBase: String? = nil,
        oidcClientID: String? = nil,
        redirectScheme: String? = nil,
        oidcScopes: String? = nil
    ) {
        let scheme = redirectScheme
            ?? Bundle.main.object(forInfoDictionaryKey: "OIDCRedirectScheme") as? String
            ?? "tbtranscription"
        self.redirectScheme = scheme
        self.redirectURI = "\(scheme)://oauth/callback"
        self.oidcIssuerBase = oidcIssuerBase
            ?? Bundle.main.object(forInfoDictionaryKey: "OIDCIssuerBase") as? String
            ?? "https://auth.fluxhaus.io/application/o/telephone-booth-operator-mobile"
        self.oidcClientID = oidcClientID
            ?? Bundle.main.object(forInfoDictionaryKey: "OIDCClientID") as? String
            ?? "x0M0MleMvCSCx8MqIE2jVoYe57nAhGymIG8azTEY"
        self.oidcScopes = oidcScopes
            ?? Bundle.main.object(forInfoDictionaryKey: "OIDCScopes") as? String
            ?? "openid email profile offline_access"
    }
}
