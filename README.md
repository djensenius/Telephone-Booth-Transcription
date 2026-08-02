# Telephone Booth Transcription

> _"Operator? I'd like to leave a message — and have it written down."_

Transcriber is a native macOS and iOS review client for the
[Telephone Booth Operator][operator]. It loads messages awaiting attention and
can draft transcription, translation, and moderation results on-device with
Apple Intelligence before an operator submits them.

The shipped apps do **not** run an HTTP server or listen for inbound network
connections.

[operator]: https://github.com/djensenius/Telephone-Booth-Operator

## Features

- **Review queue** — polls the Operator for messages needing transcription,
  translation, moderation, or a human decision.
- **On-device transcription** — downloads message audio from its pre-signed URL,
  verifies its SHA-256, and transcribes it with `SpeechAnalyzer`.
- **On-device translation and moderation** — uses Apple Foundation Models to
  draft results without sending message content to another AI service.
- **Human in the loop** — locally generated work remains a draft until the
  operator explicitly submits it.
- **OIDC sign-in** — authenticates directly with the Operator's identity
  provider and stores tokens in the Keychain.

On-device features require macOS 26 or iOS 26 and compatible Apple Intelligence
hardware. Unsupported capabilities are hidden rather than offered and failing.

## Development

```sh
swift build -c release
swift test

# Build the macOS app bundle into ./build/
./scripts/build-app.sh
```

The repository still contains `TranscriptionCore`, the reusable and fully
tested Hummingbird server library developed for earlier releases. It is not a
dependency of either app target and no server entitlement is shipped.

## Repository layout

| Path | Contents |
| --- | --- |
| `Sources/TranscriptionApp/` | Shared SwiftUI app for macOS and iOS. |
| `Sources/TranscriptionReview/` | Operator review API client and review state. |
| `Sources/TranscriptionOnDevice/` | Apple Speech and Foundation Models adapters. |
| `Sources/TranscriptionPipeline/` | App-linked in-process job and audio pipeline. |
| `Sources/TranscriptionOperator/` | Unlinked legacy background and loopback worker. |
| `Sources/TranscriptionCore/` | Unlinked legacy OpenAI-compatible server library. |
| `Tests/` | Swift Testing suites for the libraries. |
| `project.yml` | XcodeGen source for the macOS and iOS projects. |

## License

MIT — see [LICENSE](./LICENSE).
