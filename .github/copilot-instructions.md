# Copilot instructions — Telephone-Booth-Transcription

These instructions tell GitHub Copilot (and any other AI assistant) how to work
inside this repository. Read them in full before proposing changes.

## Highest-priority rules

1. **Never add a `Co-authored-by: Copilot …` trailer to commits or PRs.**
   The project owner has explicitly opted out. Strip it from any default
   template before committing. Same rule for `Signed-off-by:` lines naming an
   AI.
2. **Don't mention AI assistance in commit messages, PR titles, PR bodies, or
   changelog entries.** No "generated with Copilot", "written by AI", etc.
3. **Never log audio or text bodies** to the request log, even on errors. The
   request log is metadata-only by design (see [`docs/moderation.md`](../docs/moderation.md)).
4. **Don't commit secrets, real tokens, real API keys, or anything from a real
   `.env`.** The Keychain owns the server's bearer token; the configured
   upstream API keys live in `UserDefaults` and must never be checked in.
5. **`swift build -c release && swift test` must pass on macOS 26 before
   merging.** CI runs the same set plus `.app` packaging and docs lint, so this
   catches almost all CI failures up front.

## What this repo is

A native macOS app that exposes an **OpenAI-compatible HTTP API** for audio
transcription and text moderation, backed by user-configured local upstreams
(LM Studio for chat/moderation; faster-whisper-server or OpenAI for
transcription). It is a sibling of [`Telephone-Booth`][tb] (Rust phone client)
and [`Telephone-Booth-Operator`][tbo] (Hono + React backend); the three
projects collectively run the Telephone Booth art installation.

[tb]: https://github.com/djensenius/Telephone-Booth
[tbo]: https://github.com/djensenius/Telephone-Booth-Operator

## Workspace layout

| Path | Contents |
| --- | --- |
| `Sources/TranscriptionApp/` | `@main` SwiftUI executable. Owns lifecycle (server, power assertion, HTTPClient), settings persistence, and all UI. macOS-only — depends on AppKit, SwiftUI, IOKit, Security. |
| `Sources/TranscriptionCore/` | Platform-agnostic library. Auth, request log, upstream proxy, route handlers, server composition. Fully unit-testable; the SwiftUI app is a thin shell over this. |
| `Tests/TranscriptionCoreTests/` | Swift Testing suite. |
| `Resources/` | `AppIconSource.png` (source of truth), generated layer split, and `AppIcon.icns`. |
| `scripts/` | `make-icon.sh` (PNG source → `.icns`), `build-app.sh` (bundle `.app`). |
| `docs/` | Architecture, API reference, LM Studio + Whisper setup, moderation design. |
| `.github/workflows/` | macOS CI: `ci.yml` builds + tests + bundles + docs-lints. |

## Tech stack & conventions

- **Language:** Swift 6 with strict concurrency. Use `Sendable` everywhere it
  fits. Prefer `actor` for shared mutable state. Avoid `@unchecked Sendable`
  except where genuinely necessary (e.g. classes with internal locks).
- **HTTP server:** Hummingbird 2.x. Routes live in
  `Sources/TranscriptionCore/Server/Routes/`. New endpoints get a `*Route`
  struct conforming to a `handle(_:context:)` shape and are wired into
  `TranscriptionServer.makeRouter`.
- **HTTP client:** `AsyncHTTPClient`. A single `HTTPClient` is owned by the
  app and shared by upstreams; never create one per request.
- **Persistence:** GRDB + SQLite. Schema lives in
  `RequestLogStore.migrate()`. New columns require a new migration; never edit
  an already-shipped migration.
- **Auth:** A single bearer token in the macOS login Keychain via
  `KeychainTokenStore`. Comparisons go through `constantTimeEquals`. Every
  non-`/healthz` route is auth'd by `AuthMiddleware`.
- **Logging:** swift-log. Use `Logger(label: …)`, not `print`.
- **No `print` in production code.** Use the logger.
- **Tests:** Swift Testing (`@Suite`, `@Test`, `#expect`). Hummingbird routes
  are exercised via `HummingbirdTesting.test(.live)`.

## Commit & PR conventions

- Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`, `refactor:`,
  `test:`). Not strictly enforced but preferred.
- Branch naming: `djensenius/<short-topic>` (mirrors sibling Telephone-Booth
  repos).
- One logical change per PR. If a PR touches more than one of
  `TranscriptionCore` / `TranscriptionApp` / docs / CI, call that out in the
  description.
- Update [`README.md`](../README.md) and [`docs/`](../docs/) when changing the
  HTTP surface or the runtime configuration shape.

## How to add a new endpoint

1. Add a `*Route<Context: RequestContext>` struct in
   `Sources/TranscriptionCore/Server/Routes/`.
2. Take dependencies via the initializer (don't reach into globals).
3. Use the same JSON error envelope as the other routes (`{ "error": { "type",
   "code", "message" } }`).
4. Wire it into `TranscriptionServer.makeRouter`. Confirm it sits *after*
   `AuthMiddleware` unless it's an explicit unauthenticated endpoint (add it to
   `AuthMiddleware.excludedPaths` in that case).
5. Add a test in `Tests/TranscriptionCoreTests/`.
6. Document it in [`docs/api.md`](../docs/api.md).

## How to change the icon

- Edit `Resources/AppIconSource.png`. Stay within the sumi-ink visual language of
  the user's other apps (FluxHaus, Rhizome, gt3pro): a single black brush-stroke
  subject extracted onto the shared warm background, no extra ornament.
- Run `./scripts/make-icon.sh` to regenerate `Resources/AppIcon.icns`.
- The same script runs in CI; you don't need to commit the `.icns` if it's
  regenerable, but committing it keeps the artifact stable across runs.
