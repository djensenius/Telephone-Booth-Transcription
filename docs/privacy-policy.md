# Privacy Policy — Telephone Booth Transcription

Last updated: 2026

Telephone Booth Transcription ("the app") is a private, self-hosted server app
that exposes an OpenAI-compatible HTTP API for audio transcription, translation,
and text moderation. It runs entirely on your own Mac or iPhone. This policy
explains what the app does and does not do with your information.

## Summary

- The app does **not** collect, sell, or share personal data with the
  developer or any third party.
- The app has **no analytics, advertising, or tracking SDKs**.
- When you use the on-device backends, your audio and text never leave your
  device.

## What the app stores on your device

- **Access token.** On first launch the app generates a random bearer token and
  stores it in the macOS/iOS **Keychain**. Clients must present this token to
  use the API. The token is never transmitted to the developer.
- **Request log.** The app keeps a local SQLite log of API requests for your own
  observability. This log is **metadata only** — timestamps, route, status,
  model, and sizes. It never records the audio you submit or the text bodies of
  requests or responses.
- **Settings.** Your chosen backends and upstream URLs are stored locally in
  user defaults on your device.

## What the app sends, and to whom

- **On-device backends.** When transcription, moderation, or text translation is
  handled by Apple Intelligence (Speech Analyzer and Apple Foundation Models),
  all processing happens on the device and nothing is sent anywhere.
- **Optional self-hosted backends.** If you configure a local Whisper server
  (such as faster-whisper-server) or a local LLM via LM Studio, the app sends
  requests only to the address you configure. These run on your own
  infrastructure.
- **Optional OpenAI upstream.** If you point the transcription upstream at the
  OpenAI API and supply your own API key, audio you submit is sent to OpenAI
  under OpenAI's privacy terms. This is opt-in and off by default.
- The app does **not** contact any developer-operated servers.

## Data the app does not collect

- No advertising identifiers.
- No location data.
- No contacts or photos.
- Microphone access is used only if a client supplies a live audio source to an
  on-device speech backend; audio is processed for transcription and is not used
  for analytics.
- No usage analytics or crash-reporting telemetry sent to the developer.

## Children's privacy

The app is a developer tool for a private art installation and is not directed
to children.

## Changes to this policy

If this policy changes, the updated version will be published at this URL.

## Contact

Questions or requests can be filed as an issue at
<https://github.com/djensenius/Telephone-Booth-Transcription/issues>.
