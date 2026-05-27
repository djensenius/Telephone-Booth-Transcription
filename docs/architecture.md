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
  Whisper-compatible server (faster-whisper-server, OpenAI, or the native
  macOS Speech engines).
- **Translation** — `POST /v1/audio/translations` (audio → English) and the
  custom `POST /v1/translations` (text → English). Proxied to an
  independently-configured upstream because a deployment may want a larger
  translation model than its transcription model.
- **Moderation** — `POST /v1/moderations`, proxied to LM Studio (or any
  chat-completions server) with a best-effort local classifier fallback.

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

### Operator pull worker (optional)

In addition to the push-in HTTP server, this app can also run a long-lived
**Operator pull worker** that polls a remote Operator for queued
transcription, translation, and moderation jobs and posts results back. The
worker dispatches each leased job back through this app's own loopback HTTP
server, so all routing, middleware, and backend selection apply identically.
This makes inbound reachability to the Mac optional: only outbound HTTPS to
the Operator is required.

See [`operator-pull.md`](operator-pull.md) for setup, wire format, and
status semantics.

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
