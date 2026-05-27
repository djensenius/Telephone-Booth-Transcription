# Operator pull worker

This document describes the **pull mode** added in this release. It is
additive: the existing push-mode endpoints (`POST /v1/audio/transcriptions`,
`POST /v1/audio/translations`, `POST /v1/moderations`) continue to work
unchanged.

## Why pull mode?

The Operator backend (`Telephone-Booth-Operator`) historically calls **into**
this Mac app over HTTP. That requires inbound reachability from the
Operator's host to the Mac running this app. When the Operator runs on the
public Internet and the Mac is behind a residential NAT, that's a deal
breaker.

The pull worker inverts the direction. This app polls the Operator every
N seconds, leases at most one pending job at a time, runs it against the
exact same backend implementations the HTTP routes use, and submits the
result back. No inbound reachability to the Mac is required — only outbound
HTTPS to the Operator.

## Operator wire format

The worker speaks four endpoints on the Operator:

| Method | Path | Notes |
| --- | --- | --- |
| `GET` | `/v1/jobs/next?leaseSeconds=N&kinds=transcription,translation,moderation` | Returns `204 No Content` when nothing is queued. |
| `POST` | `/v1/jobs/{id}/succeed` | Body: `{ "leaseToken": "...", ...kind-specific result fields }`. |
| `POST` | `/v1/jobs/{id}/fail` | Body: `{ "leaseToken": "...", "errorCode": "...", "errorMessage": "..." }`. |
| `POST` | `/v1/jobs/{id}/heartbeat` | Body: `{ "leaseToken": "..." }`. Reserved; not issued by the default worker. |

All requests carry `Authorization: Bearer <operator-api-token>` and a
`User-Agent: Telephone-Booth-Transcription/<version>` header.

Job JSON shape (`GET /v1/jobs/next` 200 response):

```json
{
  "id": "<opaque>",
  "leaseToken": "<opaque>",
  "kind": "transcription" | "translation" | "moderation",
  "transcription": { "audioUrl": "...", "sha256": "...", "durationMs": 1234, "model": "...", "language": "..." },
  "translation":   { "input": "...", "sourceLanguage": "es" },
  "moderation":    { "input": "..." }
}
```

Per-kind result bodies posted to `/v1/jobs/{id}/succeed`:

```jsonc
// transcription
{ "leaseToken": "...", "text": "...", "language": "en", "model": "whisper-1" }

// translation
{ "leaseToken": "...", "translatedText": "...", "sourceLanguage": "es", "targetLanguage": "en", "model": "..." }

// moderation
{ "leaseToken": "...", "flagged": false, "recommendation": "allow", "maxScore": 0.02, "model": "..." }
```

## Configuration

All settings live in the **Operator pull worker** section of Settings:

- **Enable polling** — master toggle. Off by default.
- **Operator base URL** — e.g. `https://operator.example.com`.
- **Operator API token** — bearer token issued by the Operator. Stored in
  the macOS Keychain (account `operator-pull-api-token`), never in
  `UserDefaults`.
- **Poll interval** — 1–300 seconds; default 5.
- **Lease window** — 10–3600 seconds; default 60. The worker is expected
  to finish each job well within this window.
- **Per-realm toggles** — transcription, translation, moderation.

The worker only starts when:
- the master toggle is on,
- `baseURL` is a valid http(s) URL,
- a non-empty API token is present in the Keychain,
- at least one realm is enabled, and
- the local HTTP server is running (the worker dispatches jobs through
  loopback to reuse routing, middleware, and backend selection).

## Internal architecture

```
┌────────────┐    poll (5s)      ┌──────────────┐
│ Operator   │ ◄────────────────│ OperatorWorker│
│ /v1/jobs/* │                   └──────┬───────┘
└────────────┘                          │  POST /v1/audio/transcriptions
                                        │  POST /v1/translations
                                        │  POST /v1/moderations
                                        ▼  (loopback, same bearer token)
                                ┌──────────────────┐
                                │ TranscriptionApp │
                                │  HTTP server     │
                                └──────────────────┘
```

The dispatcher (`LoopbackOperatorJobDispatcher`) re-uses the local HTTP
server so all routing, request logging, concurrency limiting, and backend
selection behave identically whether the request came from a push client
or from the worker.

## Privacy & logging

- The worker never logs audio bytes, transcript text, translation text, or
  moderation input. Only sanitized error **codes** and job IDs reach the
  logger or the published status snapshot.
- The request log records the loopback POST (metadata only) — same as any
  other request to the local HTTP server.
- Errors submitted back to the Operator on `/v1/jobs/{id}/fail` use the
  same sanitized code/message scheme; messages never contain request body
  content.

## Status

The Settings UI surfaces a live status row driven by the worker actor:

- `stopped` — worker not running.
- `idle` — waiting between polls.
- `polling` — about to GET `/v1/jobs/next`.
- `running` — executing a leased job.
- `error` — last poll or submit failed; the worker is backing off
  exponentially (capped at 30 s) before retrying.

A `Last error` field shows the sanitized error code when the worker is in
the error phase.

## Concurrency

The worker runs one job at a time. If you need higher throughput, raise
`maxConcurrentRequests` for the HTTP server (which only affects push-in
clients) and add more Mac workers pointing at the same Operator; the
lease semantics guarantee each job is handed to exactly one worker at a
time.
