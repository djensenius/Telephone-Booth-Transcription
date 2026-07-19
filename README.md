# Telephone Booth Transcription

> _"Operator? I'd like to leave a message — and have it written down."_

A native macOS **and iOS** app that exposes an **OpenAI-compatible HTTP API**
for:

- **Audio transcription** — `POST /v1/audio/transcriptions` (multipart, same wire format
  as `https://api.openai.com/v1/audio/transcriptions`).
- **Audio translation** — `POST /v1/audio/translations` (multipart, same wire format
  as `https://api.openai.com/v1/audio/translations`) for audio → English. Plus a
  custom `POST /v1/translations` (JSON) for text → English when you already have a
  transcript.
- **Text moderation** — `POST /v1/moderations` (JSON, same wire format as
  `https://api.openai.com/v1/moderations`), with hate / harassment / violence /
  self-harm / illicit categories.

…backed by **local LLMs served by [LM Studio][lmstudio]** for moderation and any
OpenAI-compatible Whisper server (e.g. [`faster-whisper-server`][fws]) for transcription
and translation — or **macOS's built-in [Speech][speech] framework** for fully
on-device transcription with no separate server. Every request is logged to a local
SQLite database, every endpoint is protected by a bearer token stored in the macOS
Keychain, and the app can optionally keep the Mac awake while the server is running.

Lives next to the rest of the [Telephone-Booth][tb] family:

| Repo | What it is |
| --- | --- |
| [`Telephone-Booth`][tb] | Rust phone client running on a Pi inside the booth. |
| [`Telephone-Booth-Operator`][tbo] | Hono + React operator console, Postgres-backed. |
| [`Telephone-Booth-Operator-Mobile`][tbom] | Native Swift/SwiftUI operator app for iOS, macOS, watchOS, visionOS, and tvOS. |
| `Telephone-Booth-Transcription` (this repo) | Local OpenAI-compat ASR + moderation gateway. |

[lmstudio]: https://lmstudio.ai
[fws]: https://github.com/fedirz/faster-whisper-server
[speech]: https://developer.apple.com/documentation/speech
[tb]: https://github.com/djensenius/Telephone-Booth
[tbo]: https://github.com/djensenius/Telephone-Booth-Operator
[tbom]: https://github.com/djensenius/Telephone-Booth-Operator-Mobile

## How it fits together

```text
┌──────────────────── macOS app ────────────────────┐
│  SwiftUI window (status / token / settings / log) │
│        │                                          │
│        ▼                                          │
│  Hummingbird HTTP server   127.0.0.1:8089         │
│    AuthMiddleware (Bearer)                        │
│    RequestLogMiddleware (SQLite)                  │
│    /v1/audio/transcriptions  ──► transcription    │
│    /v1/audio/translations    ──► translation      │
│    /v1/translations          ──► translation      │
│    /v1/moderations           ──► moderation       │
│    /v1/requests              ──► local            │
│    /healthz                  ──► local            │
└──────────┬────────────────────────┬───────────────┘
           │                        │
           ▼                        ▼
  Whisper-compatible        LM Studio (or any
  upstream  (default:       OpenAI-compatible
  faster-whisper-server     chat backend)
  on :8000)                 on :1234
```

Optionally, the app can also run an **Operator push worker** that subscribes to
a remote Operator backend, runs requested work locally through the same routes,
and posts results back — handy when the Operator can't reach the Mac directly.
See [`docs/operator-push.md`](docs/operator-push.md).

## Quickstart

You'll need:

- macOS 26 or newer (the toolchain ships with the Xcode 26 SDK).
- For **OpenAI-compatible moderation**: [LM Studio][lmstudio] running locally,
  serving a chat/instruct model on `http://localhost:1234/v1` (default).
- For **proxy transcription** (default backend): a local Whisper-compatible
  server (e.g. [`faster-whisper-server`][fws]) on `http://localhost:8000/v1`,
  **or** an OpenAI API key (point the transcription upstream at
  `https://api.openai.com/v1`).
- Alternatively, switch the transcription backend in _Settings_ to either:
  - **macOS 26 Speech Analyzer (Apple Intelligence)** — the new on-device
    engine powering Notes / Voice Memos transcription. Highest accuracy.
  - **macOS legacy Speech Recognizer** — older `SFSpeechRecognizer`, broader
    locales but lower accuracy.

  Both run fully on-device, no separate server. Grant the permission prompt at
  first use.

- **Moderation** and **text translation** (`/v1/translations`) can likewise be
  switched in _Settings_ between **on-device Apple Intelligence** (Foundation
  Models, `model: apple-foundation-models`) and a **proxy** upstream. On macOS
  the default stays proxy (so existing setups are unchanged); pick on-device to
  run with no LM Studio. Audio translation (`/v1/audio/translations`) is always
  proxy — there is no on-device audio-translation engine.

### iOS app

The same codebase ships an iOS app (also named **Transcriber**, bundle id
`org.davidjensenius.TelephoneBoothTranscription`). On iOS the server runs in the
foreground only and the defaults are **on-device via Apple Intelligence**:

- **Transcription** defaults to the on-device Speech Analyzer.
- **Moderation** and **text translation** default to on-device FoundationModels
  (`model: apple-foundation-models`). These never fall back to a network
  upstream — if Apple Intelligence is unavailable the relevant endpoint returns
  `503 on_device_unavailable`. See [`docs/api.md`](./docs/api.md) and
  [`docs/moderation.md`](./docs/moderation.md) for the on-device response shapes
  (notably, on-device moderation returns a single `flagged` flag with all-zero
  category scores).
- **Audio translation** (`/v1/audio/translations`) remains proxy-only and is not
  served on-device, so it requires a configured upstream to use on iOS.

iOS requires iOS 26 and a device with Apple Intelligence support; on-device
features are unavailable on the simulator. The app ships Light, Dark, and Tinted
home-screen icons.

The Settings panel auto-discovers available models by calling `GET /v1/models`
on each upstream, and shows them in a picker. Refresh the list with the
circular-arrow button next to it.

```sh
# Open the native macOS app project in Xcode
open TelephoneBoothTranscription.xcodeproj

# Or build a local .app bundle into ./build/
./scripts/build-app.sh
open ./build/Transcriber.app
```

The first launch generates a random bearer token, stores it in the Keychain, and
shows it in the **Status** tab — copy it before you make your first request.

```sh
TOKEN="$(security find-generic-password \
  -s org.davidjensenius.TelephoneBoothTranscription \
  -a server-token -w)"

# Transcribe an audio file
curl -s http://127.0.0.1:8089/v1/audio/transcriptions \
  -H "Authorization: Bearer $TOKEN" \
  -F file=@./hello.wav \
  -F model=whisper-1

# Moderate some text
curl -s http://127.0.0.1:8089/v1/moderations \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"input":"I hope you have a nice day."}'
```

See [`docs/api.md`](./docs/api.md) for the full surface, and
[`docs/moderation.md`](./docs/moderation.md) for how the local moderation
fallback works (and how it differs from OpenAI's first-party moderation model).

## Repository layout

| Path | Contents |
| --- | --- |
| `Sources/TranscriptionApp/` | `@main` SwiftUI app, server lifecycle, power assertion, UI. |
| `Sources/TranscriptionCore/` | Platform-agnostic library: auth, request log, upstream proxy, route handlers, server composition. Fully unit-tested. |
| `Tests/TranscriptionCoreTests/` | Swift Testing suite for `TranscriptionCore`. |
| `TelephoneBoothTranscription.xcodeproj` + `project.yml` | Native macOS app project and its XcodeGen source. |
| `Resources/AppIconSource.png` + `Resources/AppIcon.icon` | Source-of-truth app icon art and generated Icon Composer document. |
| `scripts/make-icon.sh` | Extracts the PNG foreground and renders iOS fallback assets plus the layered Icon Composer icon. |
| `scripts/build-app.sh` | Builds the native macOS `.app` bundle from the Xcode project. |
| `docs/` | Architecture notes, API reference, LM Studio setup, moderation design. |
| `.github/workflows/ci.yml` | macOS CI: build, test, `.app` packaging, doc lint. |

## License

MIT — see [LICENSE](./LICENSE).
