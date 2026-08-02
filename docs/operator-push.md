# Operator work

Earlier macOS releases included a push worker that routed Operator jobs through
an embedded loopback HTTP server. The shipped Mac app no longer includes that
worker or server.

Current macOS and iOS releases use `OnDeviceReviewPipeline` directly from the
review UI. Audio is fetched from a pre-signed URL, verified, processed
in-process with Apple Intelligence, and shown as a draft. The operator must
explicitly submit the result.

The transport and dispatcher types remain in `TranscriptionOperator` for library
compatibility and unit testing, but no background worker is started by either
app target.
