# Operator push worker

This document describes the Operator **push worker**. The existing local HTTP
API (`POST /v1/audio/transcriptions`, `POST /v1/translations`, and
`POST /v1/moderations`) continues to work unchanged.

## Why push work over WebSocket?

The Operator backend publishes work notifications on its status WebSocket. This
app keeps one outbound WebSocket open, so the Mac can run behind NAT while still
receiving work immediately. The notification contains only a message ID and the
needed realms; the app fetches the inputs separately, runs the requested local
step, and posts the result back.

## Operator wire format

All requests carry `Authorization: <Operator API token>` and
`User-Agent: Telephone-Booth-Transcription/<version>`.

| Method | Path | Notes |
| --- | --- | --- |
| `GET` | `/v1/ws/status` | WebSocket status stream. The worker reacts only to `work` envelopes. |
| `GET` | `/v1/worker/messages/{id}/work` | Fetches audio/transcription input for the message. |
| `POST` | `/v1/worker/messages/{id}/transcription` | Body: `{ "text": "...", "language": "en" \| null, "model": null }`. |
| `POST` | `/v1/worker/messages/{id}/translation` | Body includes `transcriptionId`, `translatedText`, language fields, and `model`. |
| `POST` | `/v1/worker/messages/{id}/moderation` | Body includes `transcriptionId`, `flagged`, `recommendation`, `maxScore`, `categories`, and `model`. |

Status WebSocket work envelope:

```json
{ "kind": "work", "messageId": "<uuid>", "needs": ["transcription", "translation", "moderation"] }
```

Other envelope kinds (`message`, `status`, `metrics`, etc.) are ignored.

Work input shape:

```json
{
  "id": "<message-id>",
  "status": "pending",
  "audio": {
    "url": "https://...",
    "sha256": "...",
    "durationMs": 1234,
    "contentType": "audio/flac",
    "filename": "<sha>.flac"
  },
  "transcription": {
    "id": "<transcription-id>",
    "text": "...",
    "language": "fr",
    "model": null,
    "translationStatus": "pending",
    "translatedText": null,
    "moderationText": "..."
  }
}
```

The dispatcher still receives an `OperatorJob`: the worker builds a synthetic
job from this input. Transcription uses
`audio.url`/`sha256`; translation uses `transcription.text`; moderation uses
`transcription.moderationText`. Translation and moderation result posts include
the fetched `transcription.id`.

## Configuration

All settings live in the **Operator push worker** section of Settings:

- **Enable worker** — master toggle. Off by default.
- **Operator base URL** — e.g. `https://operator.example.com`.
- **Operator API token** — static Operator token stored in the macOS Keychain,
  never in `UserDefaults`.
- **Reconnect base delay** — 1–300 seconds; reconnects back off exponentially
  and cap around 30 seconds.
- **Per-realm toggles** — transcription, translation, moderation.

The worker only starts when the local HTTP server is running, the master toggle
is on, `baseURL` is valid, a token is present, and at least one realm is enabled.

## Internal architecture

```text
┌────────────┐   WebSocket work    ┌────────────────┐
│ Operator   │ ──────────────────► │ OperatorWorker │
│ /v1/ws/... │ ◄────────────────── │                │
└────────────┘   result POSTs      └───────┬────────┘
                                           │ loopback dispatch
                                           ▼
                                  ┌──────────────────┐
                                  │ TranscriptionApp │
                                  │  HTTP server     │
                                  └──────────────────┘
```

`LoopbackOperatorJobDispatcher` reuses the local HTTP server so routing, request
logging, concurrency limiting, and backend selection behave identically whether
work arrived over the Operator WebSocket or via a direct local HTTP request.

`InProcessOperatorJobDispatcher` remains available for devices that run services
directly. It maps failures to fixed, content-free error codes and never logs or
returns audio bytes, transcript text, translated text, moderation input, audio
URLs, filenames, or hashes.

## Privacy & logging

- The worker never logs audio bytes, transcript text, translated text, or
  moderation input. Only sanitized error codes and message IDs reach logs or the
  published status snapshot.
- The request log records loopback requests as metadata only.
- Failed local work is recorded as a sanitized worker error; content bodies are
  not logged.

## Status

The Settings UI surfaces a live status row driven by the worker actor:

- `stopped` — worker not running.
- `connecting` — opening the status WebSocket.
- `subscribed` — connected and waiting for work envelopes.
- `running` — executing one message need.
- `error` — the last connect, fetch, dispatch, or result post failed; the worker
  reconnects with capped exponential backoff.

A `Last error` field shows the sanitized error code when present.

## Concurrency

The worker handles one need at a time. If higher throughput is needed, add more
worker devices pointing at the same Operator.
