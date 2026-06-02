import SwiftUI
import TranscriptionAuth

/// Account sign-in row backed by the shared OIDC `AuthManager`. Signing in
/// here yields bearer tokens the Operator API accepts, enabling polling.
struct AccountSettingsSection: View {
    @State private var auth = AuthManager.shared
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        Section("Account") {
            switch auth.authState {
            case .signedIn:
                Label("Signed in to the Operator", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Button("Sign Out", role: .destructive) {
                    auth.signOut()
                }
            case .signedOut, .unknown:
                Text("Sign in with your Operator account to review and translate "
                     + "messages without running a server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await signIn() }
                } label: {
                    if isWorking {
                        ProgressView()
                    } else {
                        Label("Sign In", systemImage: "person.crop.circle.badge.checkmark")
                    }
                }
                .disabled(isWorking)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func signIn() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await auth.signInWithOIDC()
        } catch AuthError.cancelled {
            // User dismissed the sheet; not an error worth surfacing.
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
