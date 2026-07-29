# Architecture

```text
┌───────────────────── TranscriptionApp (executable) ─────────────────────┐
│                                                                         │
│  @main App.swift                                                        │
│    └── ContentView                                                      │
│          ├── StatusView          (start/stop, token, sleep indicator)   │
│          ├── SettingsView        (bind addr, upstreams, limits)         │
│          └── RequestLogView      (table of recent requests)             │
│                                                                         │
│  ServerHost (MainActor ObservableObject)                                │
│    ├── owns HTTPClient (singleton EventLoopGroup)                       │
│    ├── owns PowerAssertion (IOKit)                                      │
│    ├── owns Task that runs the Hummingbird Application                  │
│    └── owns TokenStore + RequestLogStoring (passed into core)           │
│                                                                         │
└──────────────────────────────────┬──────────────────────────────────────┘
                                   │
                                   ▼
┌──────────────────────── TranscriptionCore (library) ────────────────────┐
│                                                                         │
│  TranscriptionServer  ── makeRouter() / makeApplication()               │
│    ├── RequestLogMiddleware  ──► RequestLogStoring                      │
│    ├── AuthMiddleware        ──► TokenStore                             │
│    ├── HealthRoute                                                      │
│    ├── TranscriptionRoute    ──► OpenAIUpstream                         │
│    ├── ModerationRoute       ──► OpenAIUpstream + ModerationClassifier  │
│    └── RequestsRoute         ──► RequestLogStoring                      │
│                                                                         │
│  Auth/                                                                  │
│    TokenStore (protocol)                                                │
│    KeychainTokenStore (macOS Security framework)                        │
│    InMemoryTokenStore (tests)                                           │
│                                                                         │
│  Logging/                                                               │
│    RequestLogStore (GRDB / SQLite)                                      │
│    InMemoryRequestLogStore (tests)                                      │
│                                                                         │
│  Upstream/                                                              │
│    OpenAIUpstream (AsyncHTTPClient proxy)                               │
│    ProxyTranslationBackend (audio→English passthrough)                  │
│    TextTranslator (text→English via chat-completions)                   │
│    ModerationClassifier (chat-completion fallback)                      │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

This app exposes three OpenAI-compatible upstream realms:

- **Transcription** — `POST /v1/audio/transcriptions`, proxied to a
  Whisper-compatible server (faster-whisper-server, OpenAI) or served by the
  on-device macOS Speech engines.
- **Translation** — `POST /v1/audio/translations` (audio → English) and the
  custom `POST /v1/translations` (text → English). Each has its own backend
  setting: proxy to an independently-configured upstream (a deployment may want
  a larger translation model than its transcription model), or on-device via
  Apple Foundation Models. On-device audio translation is a composition —
  transcribe with the Speech engine, then translate that text — because Apple
  ships no direct speech→English model.
- **Moderation** — `POST /v1/moderations`, proxied to LM Studio (or any
  chat-completions server) with a best-effort local classifier fallback, or
  served on-device by Foundation Models.

Setting every realm to its on-device backend ("all-local mode",
`ServerConfig.isFullyLocal`) means no request the server handles reaches the
network.

## Key decisions

### Two layers

`TranscriptionCore` is a platform-agnostic Swift library with no AppKit /
SwiftUI / IOKit dependencies. Everything that _can_ be tested without a window
server lives here, and the tests run in CI on macOS without any special
permissions.

`TranscriptionApp` is the SwiftUI executable. It owns lifecycles,
side-effecting integrations (Keychain, IOKit power assertions, on-disk SQLite
path), and the UI.

### Schema-blind proxying

The transcription route does **not** parse the multipart body. It collects the
bytes up to a configured size limit, forwards them verbatim with the original
`Content-Type` (preserving the multipart boundary), and passes the upstream
response back unchanged. Only `model` is extracted from the body for the
request log, and that extraction is best-effort.

The moderation route similarly forwards the JSON body verbatim to the
upstream's `/v1/moderations` first; only when that fails does it fall back to
parsing `input` and invoking the LLM-based classifier.

This keeps the proxy compatible with any future OpenAI parameter without code
changes.

### Auth on every non-health route

`AuthMiddleware` runs before route handlers and applies to everything except
`/healthz`. It uses a constant-time byte comparison and explicitly rejects
duplicate `Authorization` headers (RFC 7235 allows only one) and non-`Bearer`
schemes.

### Request log is metadata-only

Bodies are never written to the SQLite log. A request row carries: method,
path, status, duration, content sizes, model name, auth result, moderation
`flagged`, and an error class name on failure. The `logBodies` config flag
exists for future opt-in body capture but is not yet wired through the route
handlers — see [`moderation.md`](./moderation.md) for why opt-in body capture
is dangerous for moderation inputs in particular.

### Request log retention

`RequestLogStore` enforces a configurable `RetentionPolicy` with two optional
limits:

- **`maxRows`** (default 10 000) — after each insert, if the total row count
  exceeds this limit the oldest rows (by `receivedAt`) are deleted.
- **`maxAge`** (default 30 days) — rows older than `now − maxAge` are deleted
  on the next write.

Both limits are enforced inside the same write transaction as the insert, so
retention is effectively zero-overhead and requires no background timer. The
`receivedAt` column is indexed, making pruning cheap even on large tables.

The defaults are generous enough for a continuously running art installation
while guaranteeing the database cannot grow without bound.

### Power assertion

`PowerAssertion` wraps `IOPMAssertionCreateWithName` with
`kIOPMAssertionTypePreventUserIdleSystemSleep`. The Mac is kept awake only
when _both_ `preventSleep` is on in Settings AND the server is running. The
assertion is always released on server stop, on toggle-off, and on app quit.

### Testing

`HummingbirdTesting` lets us hit the live router in-process without binding a
real socket. The `TranscriptionServerTests` suite covers the auth happy/sad
paths against a real wired-up router with in-memory token + log stores.
`ModerationClassifierTests` covers the JSON parsing of model output, including
markdown-fence stripping and unknown-category resilience.

CI runs `swift test` on `macos-26` (and the same workflow can be promoted to
older macOS images by lowering `Package.swift`'s minimum platform if needed).

### Operator push worker (optional)

In addition to the push-in HTTP server, this app can also run a long-lived
**Operator push worker** that subscribes to a remote Operator for
transcription, translation, and moderation work and posts results back. The
worker dispatches each synthetic job back through this app's own loopback HTTP
server, so all routing, middleware, and backend selection apply identically.
This makes inbound reachability to the Mac optional: only outbound
HTTPS/WebSocket access to the Operator is required.

See [`operator-push.md`](operator-push.md) for setup, wire format, and
status semantics.

### iOS: in-process, no server

The iOS target is deliberately **not** a second copy of the server. It links
`TranscriptionShared`, `TranscriptionOnDevice`, and `TranscriptionOperator`,
but not `TranscriptionCore` — there is no Hummingbird listener, no GRDB request
log, and no `ConfigPersistence` (that file is `#if os(macOS)` in its entirety).
`ServerHostIOS` is an empty shim that exists only so the shared SwiftUI code
compiles.

Instead, the iOS review UI runs the same pipeline **in-process**.
`OnDeviceReviewPipeline` (in `TranscriptionOperator`, alongside the dispatcher
it drives, so its state machine is unit-testable without an app host) wraps
`InProcessOperatorJobDispatcher` — the identical type the macOS push worker
uses — with:

- `URLSessionAudioFetcher` for the audio fetch, so we get ATS, cellular policy,
  and proxy support from the platform rather than standing up a NIO event-loop
  group inside a phone app. It delegates hashing, byte-capping, temp-file
  staging, and cleanup to the shared `AudioFileStaging`, so its observable
  behavior matches `HTTPClientAudioFetcher` exactly. It sends **no**
  `Authorization` header: `message.audio.url` is a pre-signed, short-lived blob
  URL whose credential is already in the query string, and whose host is
  storage rather than the Operator — attaching the operator's bearer token
  would leak it to a third party for no benefit.
- `SpeechAnalyzerTranscriber` and the FoundationModels translation/moderation
  services, constructed directly rather than reached through HTTP.

The consequences are worth stating plainly:

- **No HTTP hop.** The transcript never leaves the process, so there is no
  loopback listener to secure and no bearer token to manage on iOS.
- **Same error vocabulary.** Because the dispatcher is shared, iOS surfaces the
  same sanitized `OperatorJobError` codes (`audio_fetch_failed`,
  `audio_sha256_mismatch`, `*_unavailable`, `*_timeout`) as the macOS worker.
  `OnDeviceReviewPipeline` maps those codes — never the underlying error — to
  operator-facing copy, preserving the metadata-only logging rule.
- **Manual and advisory.** The pipeline runs only when the operator taps the
  button, and its output _pre-fills_ the translation draft. It never submits.
  The human stays in the loop, which also means a bad on-device transcript is a
  correctable draft rather than a published result.
- **Graceful absence.** `makeAppleIntelligence` (the Apple Intelligence wiring,
  which stays in `TranscriptionApp`) returns `nil` when the engines are
  unavailable, and the UI hides the affordance entirely rather than offering a
  button that always fails. It consults `OnDeviceCapability`, which probes
  `SpeechTranscriber.isAvailable` and `SystemLanguageModel.availability` — an
  OS-version check alone is not enough, since a device can run iOS 26 and still
  be ineligible, have Apple Intelligence turned off, or not have finished
  downloading the model. The engines re-check at use time as well, because
  availability can change after the probe, and the review queue re-probes on
  appear so enabling Apple Intelligence mid-session surfaces the affordance
  without a relaunch. Speech and Foundation Models are gated separately:
  transcription needs only the former, so a device with Apple Intelligence off
  still gets the transcription queues, with `supportsTranslation == false`
  hiding just the translate affordance.

#### Transcripts are read-only on iOS

The transcription queues added by the discovery worker are actionable on macOS,
which hands the job to its worker and gets the transcript posted back to the
Operator. iOS can run the same transcription locally via `transcribeOnly`, but
it cannot submit the result: the only Operator endpoint that accepts transcript
text (`POST /v1/worker/messages/{id}/transcription`) is gated on a worker-scoped
API token, and the iOS app authenticates solely as a human operator over OIDC.
`POST /v1/messages/{id}/transcribe` is operator-authenticated but takes no body
— it triggers the Operator's own server-side pipeline, which is the opposite of
what an on-device run is for.

Rather than issue the phone a worker token (a broad privilege for a single
write, and one the iOS app has nowhere to persist), the local transcript is
shown to the operator and goes no further. Lifting this needs an
operator-authenticated submit endpoint, tracked in
[Operator #121](https://github.com/djensenius/Telephone-Booth-Operator/issues/121).

---

## Network Security & Non-Loopback Binds

The server speaks **plain HTTP** only. By default, it binds to `127.0.0.1`
(loopback), which ensures traffic never leaves the machine.

### Why non-loopback is restricted

If bound to `0.0.0.0` or a LAN IP, the bearer token and all audio/text
payloads traverse the network unencrypted. A LAN attacker can passively
sniff the token and impersonate an authorised client.

The `ServerConfig.validated()` method enforces this: any non-loopback
`bindHost` is silently reset to `127.0.0.1` **unless**
`nonLoopbackBindAcknowledged` is `true`. In the GUI, the user must toggle
"Allow non-loopback bind (insecure without TLS)" to persist a non-loopback
address.

### Serving a remote operator Mac

The supported direct-LAN setup for a Telephone-Booth Operator running on a
different Mac is to persist both a network-reachable `bindHost` and
`nonLoopbackBindAcknowledged=true`. After `ServerConfig.validated()`, the
default bind is `127.0.0.1`; without that acknowledgement, any non-loopback
`bindHost` silently reverts to loopback and the remote operator cannot connect.

This direct bind is plain HTTP, so use it only on a trusted network. If the
operator traffic crosses an untrusted network, keep the app bound to loopback
and put a TLS-terminating proxy in front.

### Deploying with remote clients (TLS reverse proxy)

If the server must accept connections from other machines through a protected
endpoint, place a TLS-terminating reverse proxy in front:

```text
[Remote client] ──TLS──► [nginx / Caddy / stunnel] ──HTTP──► localhost:8089
```

Example Caddy snippet:

```caddyfile
transcription.local {
    reverse_proxy 127.0.0.1:8089
    tls internal      # auto-provisions a self-signed cert for .local
}
```

With this setup the app remains bound to loopback and the proxy handles
encryption. Pass the same bearer token in the `Authorization` header from
the remote client through the proxy.

### mTLS (mutual TLS)

For stronger authentication, configure your reverse proxy with client
certificate verification (mTLS). This ensures only devices with a trusted
certificate can reach the API — even if the bearer token is compromised,
connections from untrusted machines are rejected at the TLS layer.
