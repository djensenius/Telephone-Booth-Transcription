# Operator push worker

This document describes the Operator **push worker**. The existing local HTTP
API (`POST /v1/audio/transcriptions`, `POST /v1/translations`, and
`POST /v1/moderations`) continues to work unchanged.

## Two sources of work

The worker keeps one outbound WebSocket open, so the Mac can run behind NAT
while still receiving work immediately. That channel still solicits
**translation** and **moderation**, which are downstream of a transcript the
Operator has just received: the notification contains only a message ID and the
needed realms, and the app fetches the inputs separately.

**Transcription is different.** A completed upload now lands in the review queue
straight away and transcription is optional enrichment, so the Operator no
longer broadcasts `work` envelopes for it. The worker therefore runs a
**discovery pass** that polls `GET /v1/worker/messages` for reviewable messages
with no succeeded transcription and enqueues them itself. `work` envelopes
carrying `needs: ["transcription"]` are still honoured — the Operator UI's
manual "Re-run transcription" button emits one — they're simply no longer
required.

Both sources feed a single queue that de-duplicates by `(message, kind)` and
runs one job at a time. Envelope-driven work jumps ahead of discovered work, so
a translation or moderation request never waits behind a transcription backlog.
An envelope and a discovery hit for the same message run exactly once. A
translation or moderation envelope that lands while that same job is running
schedules one follow-up run, because the running job already fetched the older
input; transcription is never replayed that way, since it would post a second
transcript row.

## Operator wire format

All requests carry `Authorization: Bearer <Operator API token>` and
`User-Agent: Telephone-Booth-Transcription/<version>`.

| Method | Path | Notes |
| --- | --- | --- |
| `GET` | `/v1/ws/status` | WebSocket status stream. The worker reacts only to `work` envelopes. |
| `GET` | `/v1/worker/messages` | Discovery listing. Query: `needs=transcription\|any`, `limit`, `cursor`. |
| `GET` | `/v1/worker/messages/{id}/work` | Fetches audio/transcription input for the message. |
| `POST` | `/v1/worker/messages/{id}/transcription` | Body: `{ "text": "...", "language": "en" \| null, "model": null }`. Accepted unsolicited. |
| `POST` | `/v1/worker/messages/{id}/translation` | Body includes `transcriptionId`, `translatedText`, language fields, and `model`. |
| `POST` | `/v1/worker/messages/{id}/moderation` | Body includes `transcriptionId`, `flagged`, `recommendation`, `maxScore`, `categories`, and `model`. |

Discovery listing shape:

```json
{
  "items": [
    {
      "id": "<message-id>",
      "status": "pending",
      "receivedAt": "2026-07-29T04:12:49.000Z",
      "durationMs": 4200,
      "latestTranscriptionStatus": null
    }
  ],
  "nextCursor": null
}
```

`needs=transcription` returns the default working set (messages with no
succeeded transcription); `needs=any` returns every reviewable message so the AI
can be re-run deliberately. Every field except `id` is optional and `status` is
treated as an opaque string — a freshly landed message reports `pending`, while
`received` still appears on historical rows.

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

Transcription result posts deliberately **omit** `transcriptionId`: no pending
row is created for them any more, and a re-run is meant to add a new succeeded
row rather than overwrite the previous one. The Operator keeps the history and
the newest succeeded row wins downstream.

## Discovery pass

- Interval: the configured **Reconnect / discovery delay**, with its own capped
  exponential backoff (up to 300 s) on failure. Discovery failures don't disturb
  the WebSocket reconnect schedule or its backoff.
- Page size 50, following `nextCursor` for at most 10 pages per interval.
- Items already reporting `latestTranscriptionStatus: "succeeded"` are skipped.
- A message is enqueued by discovery at most 3 times per 30-minute window, so a
  message the Operator keeps listing can't spin in a hot loop, while a transient
  upstream outage still self-heals once the window rolls over. A successful
  transcription retires the message from discovery, so a stale listing doesn't
  cause it to be transcribed over and over; retirement is remembered for the
  5,000 most recent successes, after which the attempt cap above is what bounds
  it. A deliberate re-run from the app is forced and ignores both rules.
- At most 25 discovered jobs wait in the queue at once, so a large backlog
  can't crowd out translation and moderation.
- Runs only when the transcription realm is enabled.
- The listing endpoint doesn't lease or claim items, and de-duplication is
  per-worker, so run **one** worker per Operator: two Macs polling the same
  Operator would each transcribe every listed message.

## Re-running transcription from the app

The **Review** tab separates reviewable messages with no transcription at all
("Needs transcription") from ones that already have transcription history
("Transcribed"), and shows distinct "Silent" and "Transcription unfinished"
states. Messages whose newest transcription is pending or failed stay in the
second bucket: the review payload only carries the newest row, so an older
successful transcript could otherwise be masked, and re-running from Review is a
human decision. This is Review bucketing only — the worker's discovery pass has
its own rules and may still retry a message whose newest row failed. Both
buckets offer a button that hands the message to the local worker; that request
bypasses the discovery attempt cap.

Review runs on the operator's own OIDC session while the worker uses its
worker-scoped API token — the app bridges the two locally, so no extra Operator
permission is needed. The bridge is only wired up when the Review base URL and
the worker's Operator base URL agree; when they don't, the re-run is refused
with an error rather than transcribing against a different backend.

## Configuration

All settings live in the **Operator push worker** section of Settings:

- **Enable worker** — master toggle. Off by default.
- **Operator base URL** — e.g. `https://operator.example.com`.
- **Operator API token** — static Operator token stored in the macOS Keychain,
  never in `UserDefaults`.
- **Reconnect / discovery delay** — 1–300 seconds; reconnects back off
  exponentially and cap around 30 seconds, discovery up to 300 seconds.
- **Per-realm toggles** — transcription, translation, moderation.

The worker only starts when the local HTTP server is running, the master toggle
is on, `baseURL` is valid, a token is present, and at least one realm is enabled.

## Internal architecture

```text
┌────────────┐   WebSocket work    ┌────────────────┐
│ Operator   │ ──────────────────► │ OperatorWorker │
│ /v1/ws/... │ ◄────────────────── │                │
│            │   discovery poll    │   ┌──────────┐ │
│ /v1/worker │ ◄────────────────── │   │ job queue│ │
└────────────┘   result POSTs      └───┴────┬─────┴─┘
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

A `Last error` field shows the sanitized error code when present, and a
`Last discovery` field shows when the discovery pass last succeeded and how many
messages it queued — so "subscribed but discovering nothing" is
distinguishable from "not polling at all". Discovery failures report separately
under `Discovery error`, so an endpoint that keeps 404ing stays visible even
while socket work succeeds.

## Concurrency

The worker handles one need at a time, whether it arrived over the WebSocket or
from the discovery pass. Throughput can't be raised by adding worker devices:
the listing endpoint doesn't lease work, so a second Mac polling the same
Operator would transcribe every message a second time. Run one worker per
Operator until the Operator can hand out claims.
