# Architecture

## Shipped apps

The macOS and iOS targets share the same review-client architecture:

```text
┌────────────────────── TranscriptionApp ──────────────────────┐
│ SwiftUI ReviewView / ReviewDetailView / SettingsView         │
│                                                              │
│ AuthManager ── OIDC + Keychain                               │
│ ReviewStore ── HTTPOperatorReviewClient ──► Operator API     │
│      │                                                       │
│      └── OnDeviceReviewPipeline                              │
│            ├── SpeechAnalyzerTranscriber                     │
│            ├── FoundationModelsTranslationService            │
│            └── FoundationModelsModerationService             │
└──────────────────────────────────────────────────────────────┘
```

Neither app target links `TranscriptionCore`, starts Hummingbird, binds a port,
maintains an inbound bearer token, writes a request log, or holds a power
assertion. Both platforms fetch message audio through pre-signed URLs and send
reviewed results to the Operator over outbound HTTPS.

`AppState` is deliberately small. It satisfies the review module's optional
transcription re-run interface, while local Apple Intelligence work is owned by
`ReviewView` and remains draft-only until submission.

## Library boundaries

- **TranscriptionAuth** owns OIDC session restoration and Keychain token
  persistence.
- **TranscriptionReview** owns Operator review models, polling, filtering,
  drafts, and submissions.
- **TranscriptionOnDevice** adapts Apple Speech and Foundation Models.
- **TranscriptionPipeline** owns the app-linked in-process job dispatcher and
  audio integrity checks.
- **TranscriptionOperator** preserves the historical public package surface and
  contains the unlinked background worker, worker client, WebSocket channel,
  and loopback dispatcher.
- **TranscriptionShared** contains shared service protocols and job models.

## Legacy server library

`TranscriptionCore` remains in the package as an independently tested library
for compatibility with existing integrations. It contains the Hummingbird
router, middleware, upstream proxies, request logging, and server configuration.
It is not linked into `TranscriptionApp` or `TranscriptionAppiOS`, and therefore
none of that code is present in the shipped app dependency graph.
