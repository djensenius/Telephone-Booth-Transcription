# Telephone Booth Transcription

> _"Operator? I'd like to leave a message — and have it written down."_

A native macOS app that exposes an **OpenAI-compatible HTTP API** for:

- **Audio transcription** — `POST /v1/audio/transcriptions` (multipart, same wire format
  as `https://api.openai.com/v1/audio/transcriptions`).
- **Text moderation** — `POST /v1/moderations` (JSON, same wire format as
  `https://api.openai.com/v1/moderations`), with hate / harassment / violence /
  self-harm / illicit categories.

…backed by **local LLMs served by [LM Studio][lmstudio]** for moderation and any
OpenAI-compatible Whisper server (e.g. [`faster-whisper-server`][fws]) for transcription
— or **macOS's built-in [Speech][speech] framework** for fully on-device transcription
with no separate server. Every request is logged to a local SQLite database, every
endpoint is protected by a bearer token stored in the macOS Keychain, and the app can
optionally keep the Mac awake while the server is running.

Lives next to the rest of the [Telephone-Booth][tb] family:

| Repo | What it is |
| --- | --- |
| [`Telephone-Booth`][tb] | Rust phone client running on a Pi inside the booth. |
| [`Telephone-Booth-Operator`][tbo] | Hono + React operator console, Postgres-backed. |
| `Telephone-Booth-Transcription` (this repo) | Local OpenAI-compat ASR + moderation gateway. |

[lmstudio]: https://lmstudio.ai
[fws]: https://github.com/fedirz/faster-whisper-server
[speech]: https://developer.apple.com/documentation/speech
[tb]: https://github.com/djensenius/Telephone-Booth
[tbo]: https://github.com/djensenius/Telephone-Booth-Operator

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

## Quickstart

You'll need:

- macOS 26 or newer (the toolchain ships with the Xcode 26 SDK).
- For **OpenAI-compatible moderation**: [LM Studio][lmstudio] running locally,
  serving a chat/instruct model on `http://localhost:1234/v1` (default).
- For **proxy transcription** (default backend): a local Whisper-compatible
  server (e.g. [`faster-whisper-server`][fws]) on `http://localhost:8000/v1`,
  **or** an OpenAI API key (point the transcription upstream at
  `https://api.openai.com/v1`).
- Alternatively, switch the transcription backend in *Settings* to
  **Built-in macOS (Speech framework)** for fully on-device transcription with
  no separate server — just grant the permission prompt at first use.

The Settings panel auto-discovers available models by calling `GET /v1/models`
on each upstream, and shows them in a picker. Refresh the list with the
circular-arrow button next to it.

```sh
# Run from the source tree without bundling an .app
swift run

# Or build a real .app bundle into ./build/
./scripts/build-app.sh
open ./build/Telephone\ Booth\ Transcription.app
```

The first launch generates a random bearer token, stores it in the Keychain, and
shows it in the **Status** tab — copy it before you make your first request.

```sh
TOKEN="$(security find-generic-password \
  -s dev.djensenius.telephone-booth-transcription \
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
| `Resources/AppIcon.svg` + `Resources/AppIcon.icns` | Source-of-truth app icon. |
| `scripts/make-icon.sh` | Rasterizes the SVG into a complete `.icns` bundle. |
| `scripts/build-app.sh` | Builds a real `.app` bundle around the SwiftPM executable. |
| `docs/` | Architecture notes, API reference, LM Studio setup, moderation design. |
| `.github/workflows/ci.yml` | macOS CI: build, test, `.app` packaging, doc lint. |

## License

MIT — see [LICENSE](./LICENSE).
