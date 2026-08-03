# Configuring proxy backends

This setup applies only to consumers embedding the standalone
`TranscriptionCore` library. The shipped apps do not proxy to LM Studio,
Whisper servers, or OpenAI.

Configure proxy backends programmatically through `ServerConfig`:

```swift
import TranscriptionCore

var config = ServerConfig()
config.transcriptionBackend = .proxy(
    UpstreamConfig(baseURL: "http://127.0.0.1:8000/v1")
)
config.moderationBackend = .proxy
config.moderationUpstream = UpstreamConfig(
    baseURL: "http://127.0.0.1:1234/v1"
)
config.moderationModel = "your-loaded-model"
```

## Transcription

Point `transcriptionBackend` at any service implementing OpenAI's
`POST /v1/audio/transcriptions` multipart format. A local
[`faster-whisper-server`](https://github.com/fedirz/faster-whisper-server)
instance commonly listens at `http://127.0.0.1:8000/v1`.

For OpenAI, use `https://api.openai.com/v1` and supply the API key through the
consumer's secure `APIKeyStoring` integration rather than source control.

## Moderation

[LM Studio](https://lmstudio.ai) provides `/v1/chat/completions` but not
`/v1/moderations`. With `moderationFallbackEnabled` enabled,
`TranscriptionCore` first tries `/v1/moderations`, then uses its
chat-completion classifier fallback.

Load an instruct model with reliable JSON output, start LM Studio's local
server, and set `moderationUpstream.baseURL` plus `moderationModel` as shown
above.

Loopback HTTP is appropriate for local services without credentials. Remote
services carrying API keys must use HTTPS; `UpstreamConfig` strips keys from
insecure remote connections.
