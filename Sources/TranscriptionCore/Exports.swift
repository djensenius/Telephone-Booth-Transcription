// Re-export the platform-neutral shared layer so existing
// `import TranscriptionCore` consumers (the macOS app and the test suite)
// continue to see the Operator job models and polling config without changes.
//
// `TranscriptionShared` carries no Hummingbird/GRDB dependency, so future
// non-macOS pull clients can depend on it directly without linking the HTTP
// server stack.
@_exported import TranscriptionShared
// Re-export the operator-pull layer (worker, client, dispatchers) so the macOS
// app and existing tests keep importing it via `TranscriptionCore`. It carries
// no Hummingbird/GRDB dependency, so mobile pull clients depend on it directly.
@_exported import TranscriptionOperator
