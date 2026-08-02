# Privacy Policy — Telephone Booth Transcription

Last updated: 2026

Telephone Booth Transcription ("the app") is a review client for a privately
operated Telephone Booth installation.

## Summary

- The app has no advertising, analytics, or third-party tracking SDKs.
- The app does not run an HTTP server or accept inbound network connections.
- Apple Intelligence processing occurs on-device.
- Nothing generated on-device is submitted until the operator confirms it.

## Data stored on your device

- **Sign-in tokens** are stored in the system Keychain.
- **Review state and drafts** are held locally while you use the app.
- The app does not maintain the HTTP request log used by older server releases.

## Network use

The app connects to the configured Telephone Booth Operator service to sign in,
load the review queue, fetch message metadata, and submit approved work. Message
audio is downloaded from pre-signed, short-lived URLs without attaching the
Operator authorization token.

Transcription uses Apple Speech, while translation and moderation use Apple
Foundation Models when those capabilities are available. That processing occurs
on-device.

## Data the app does not collect

- No advertising identifiers.
- No location data.
- No contacts or photos.
- No developer-operated analytics or crash-reporting telemetry.

## Contact

Questions can be filed at
<https://github.com/djensenius/Telephone-Booth-Transcription/issues>.
