// Re-export the platform-neutral shared layer so existing
// `import TranscriptionCore` consumers (the macOS app and the test suite)
// continue to see the Operator job models and polling config without changes.
//
// `TranscriptionShared` carries no Hummingbird/GRDB dependency, so future
// non-macOS worker clients can depend on it directly without linking the HTTP
// server stack.
@_exported import TranscriptionShared
// Preserve the historical TranscriptionOperator surface for existing
// TranscriptionCore consumers. The shipped apps link TranscriptionPipeline
// directly and therefore do not include the worker implementation.
@_exported import TranscriptionOperator
