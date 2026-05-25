# API reference

Every endpoint except `/healthz` requires `Authorization: Bearer <token>`. The
token is shown in the app's **Status** tab and rotates from the same screen; it
lives in the macOS login Keychain under
`dev.djensenius.telephone-booth-transcription / server-token`.

`401 Unauthorized` is returned for:

- missing `Authorization` header (`code: "missing_authorization"`)
- non-Bearer scheme (`code: "invalid_scheme"`)
- empty token (`code: "empty_token"`)
- duplicate `Authorization` headers (`code: "multiple_authorization_headers"`)
- token mismatch (`code: "bad_token"`)

The validated server config binds to `127.0.0.1` by default. To serve a
Telephone-Booth Operator running on another Mac, persist a non-loopback
`bindHost` and set `nonLoopbackBindAcknowledged=true`; otherwise validation
silently reverts the bind to loopback. See
[`architecture.md`](./architecture.md#serving-a-remote-operator-mac) for the
networking trade-offs.

`503 Service Unavailable` is returned when the server has reached its configured
maximum concurrent request limit (`maxConcurrentRequests` in Settings, default
8). The response uses the standard error envelope:

```json
{
  "error": {
    "type": "server_error",
    "code": "overloaded",
    "message": "server is at maximum capacity, please retry later"
  }
}
```

Clients should back off and retry. `/healthz` is never subject to the
concurrency limit -- it always responds even when the server is at capacity.

## `GET /healthz`

Unauthenticated liveness probe.

```json
{ "status": "ok", "service": "telephone-booth-transcription" }
```

## `POST /v1/audio/transcriptions`

OpenAI-compatible multipart upload. The behaviour depends on the configured
**transcription backend** (see _Settings → Transcription backend_ in the app):

- **Proxy backend** (default) — the server forwards all multipart fields
  verbatim to the configured upstream (faster-whisper-server, OpenAI, etc.).
  Only `model` is extracted for the request log. If you've picked a default
  model in Settings and the request doesn't carry one, the server injects it
  before forwarding.
- **macOS 26 Speech Analyzer (Apple Intelligence)** — the server parses the
  multipart body, extracts the `file` field, and feeds it to `SpeechAnalyzer`
  paired with `SpeechTranscriber`. Same engine that powers Apple-Intelligence
  transcription in Notes / Voice Memos. Highest accuracy, handles long-form
  audio. First use of a new locale may trigger a one-time on-device model
  download via `AssetInventory`.
- **macOS legacy Speech Recognizer** — uses the older `SFSpeechRecognizer`.
  Wider locale coverage and no model download, but lower accuracy. Useful
  fallback for locales the new engine doesn't yet support.

For both native backends the response is the OpenAI default JSON shape:
`{ "text": "…" }`. Other multipart fields (`prompt`, `temperature`,
`response_format`, etc.) are ignored on the native backends; only `language`
(via the locale chosen in Settings) is honoured. First use will prompt for
Speech Recognition permission.

Common fields:

| Field | Required | Notes |
| --- | --- | --- |
| `file` | yes | The audio file (wav / mp3 / m4a / webm / flac / ogg). |
| `model` | recommended | e.g. `whisper-1`, `whisper-large-v3`, model alias served by your upstream. |
| `language` | no | ISO-639-1 (`en`, `fr`, …) |
| `prompt` | no | Optional prompt to bias the decoder. |
| `temperature` | no | 0..1 |
| `response_format` | no | `json` (default), `text`, `srt`, `vtt`, `verbose_json` |

Response body and status code are passed through from the upstream unchanged
(minus hop-by-hop headers).

## `POST /v1/moderations`

OpenAI-compatible moderation. JSON body:

```json
{ "input": "string or array of strings", "model": "omni-moderation-latest" }
```

The server first tries the configured moderation upstream's `/v1/moderations`.
If the upstream returns 2xx, that response is forwarded verbatim. Otherwise, if
the **chat-completion fallback** is enabled in Settings (default on), the
server asks the moderation upstream's `/v1/chat/completions` endpoint to
classify the input against OpenAI's category set and returns a result in the
OpenAI moderation response shape:

```json
{
  "id": "modr-local-…",
  "model": "omni-moderation-latest",
  "results": [
    {
      "flagged": true,
      "categories": {
        "sexual": false, "sexual/minors": false,
        "harassment": false, "harassment/threatening": false,
        "hate": true, "hate/threatening": false,
        "illicit": false, "illicit/violent": false,
        "self-harm": false, "self-harm/intent": false, "self-harm/instructions": false,
        "violence": false, "violence/graphic": false
      },
      "category_scores": { "hate": 0.91, "...": 0.0 }
    }
  ]
}
```

See [`moderation.md`](./moderation.md) for the limitations of the local
fallback. **It is not a replacement for OpenAI's first-party safety model.**

## `GET /v1/requests`

Returns the most recent request log entries (defaults to 100, `?limit=N` up to
1000).

```json
{
  "data": [
    {
      "id": 42,
      "receivedAt": "2026-05-23T20:31:11Z",
      "method": "POST",
      "path": "/v1/audio/transcriptions",
      "status": 200,
      "durationMs": 8421,
      "model": "whisper-1",
      "requestBytes": 0,
      "responseBytes": 142,
      "authOK": true,
      "moderationFlagged": null,
      "error": null
    }
  ]
}
```

Bodies are **not** logged. Only metadata: method, path, status, duration,
content sizes, auth result, model, and the moderation `flagged` flag.

## `GET /v1/models`

Composite model list across the configured upstreams. The response shape
matches OpenAI's `/v1/models`:

```json
{
  "object": "list",
  "data": [
    { "id": "macos-speech", "object": "model", "owned_by": "transcription", "created": 0 },
    { "id": "Systran/faster-whisper-medium.en", "object": "model", "owned_by": "transcription" },
    { "id": "llama-3.1-8b-instruct", "object": "model", "owned_by": "moderation" }
  ]
}
```

`owned_by` indicates which of the local app's two upstreams reported the
model: `transcription` (the Whisper-compatible server) or `moderation` (the
LM Studio / chat-completions server). When the macOS native transcription
backend is selected, a synthetic `macos-speech` entry is prepended so clients
can pick it through the same picker.

The endpoint is best-effort: if an upstream is unreachable, its entries are
simply omitted rather than failing the request.
