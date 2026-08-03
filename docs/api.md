# TranscriptionCore API

`TranscriptionCore` is a standalone library retained for existing integrations.
The shipped macOS and iOS apps do not link it, expose HTTP routes, or listen on
a network port.

Library consumers construct a `ServerConfig`, token store, request-log store,
and shared `AsyncHTTPClient.HTTPClient`, then create a `TranscriptionServer`:

```swift
import AsyncHTTPClient
import TranscriptionCore

var config = ServerConfig()
config.bindHost = "127.0.0.1"
config.bindPort = 8089

let client = HTTPClient(eventLoopGroupProvider: .singleton)
let tokenStore = InMemoryTokenStore()
let bearerToken = try tokenStore.current()
let server = TranscriptionServer(
    config: config.validated(),
    tokenStore: tokenStore,
    logStore: InMemoryRequestLogStore(),
    httpClient: client
)
let application = server.makeApplication()
try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { await server.logWriter.run() }
    group.addTask { try await application.runService() }
    // runService() exits on signal; shut down the writer so run() drains and returns
    _ = try await group.next()
    await server.logWriter.shutdown()
    await group.waitForAll()
}
```

Use `bearerToken` as `Authorization: Bearer <token>` for every route except
`/healthz`.

Production consumers should provide persistent `TokenStore` and
`RequestLogStoring` implementations and shut down the shared HTTP client during
their own lifecycle teardown.

## Routes

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/healthz` | Unauthenticated liveness probe. |
| `GET` | `/v1/models` | Aggregated upstream model discovery. |
| `GET` | `/v1/requests` | Request-log metadata. |
| `POST` | `/v1/audio/transcriptions` | OpenAI-compatible transcription. |
| `POST` | `/v1/audio/translations` | OpenAI-compatible audio translation. |
| `POST` | `/v1/translations` | Text-to-English translation. |
| `POST` | `/v1/moderations` | OpenAI-compatible moderation. |

Every route except `/healthz` requires the bearer token supplied by the
configured `TokenStore`. Errors use the shared envelope:

```json
{
  "error": {
    "type": "server_error",
    "code": "example_code",
    "message": "Human-readable description"
  }
}
```

See the route implementations in
`Sources/TranscriptionCore/Server/Routes/` and their live-server tests in
`Tests/TranscriptionCoreTests/` for request and response details.
