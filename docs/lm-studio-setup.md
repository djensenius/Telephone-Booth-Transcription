# Setting up LM Studio + a Whisper server

This app proxies to two upstreams. Both speak the OpenAI HTTP wire format.

## Moderation / chat — LM Studio

[LM Studio](https://lmstudio.ai) bundles a server that mimics OpenAI's
`/v1/chat/completions`, `/v1/completions`, `/v1/embeddings`, `/v1/models`, and
`/v1/responses` endpoints. It does **not** ship an audio transcription endpoint
and it does **not** ship a dedicated `/v1/moderations` endpoint, so this app
uses LM Studio only for the moderation **fallback** classifier.

1. Install LM Studio.
2. Download a small instruct-tuned model (3B–8B is plenty for classification).
   Pick something with reliable JSON output — Llama 3.1 8B Instruct, Qwen2.5 7B
   Instruct, and Phi-3.5 Mini Instruct all work well.
3. Open **Developer → Local Server**, load the model, and start the server.
   The default URL is `http://localhost:1234/v1`.
4. In this app's Settings, set the moderation upstream base URL to that value
   and the model name to whatever LM Studio reports under "Loaded model".

## Transcription — a Whisper-compatible server

LM Studio cannot transcribe audio, so point the transcription upstream at a
real Whisper server. Pick one:

### Option A: `faster-whisper-server` (local, free, GPU-friendly)

```sh
docker run --rm -p 8000:8000 \
  fedirz/faster-whisper-server:latest-cpu
# or :latest-cuda on Linux/NVIDIA
```

Set the transcription upstream base URL to `http://127.0.0.1:8000/v1`.

### Option B: OpenAI

Set the transcription upstream base URL to `https://api.openai.com/v1` and put
your OpenAI key in the API key field. The app will forward it as
`Authorization: Bearer …` to OpenAI (separate from the token clients use to
authenticate to _this_ app).

### Option C: any other OpenAI-compatible ASR server

If it accepts `POST /v1/audio/transcriptions` with multipart input, it'll work.
The proxy is intentionally schema-blind — it forwards all multipart fields
verbatim.

## Skipping LM Studio entirely (native macOS transcription)

If you only need transcription and don't care about moderation, you can avoid
running LM Studio or `faster-whisper-server` altogether:

1. Open the app and go to **Settings → Transcription backend**.
2. Pick **Built-in macOS (Speech framework)**.
3. Pick a locale (the picker lists every locale `SFSpeechRecognizer.supportedLocales()`
   reports — typically 50+ languages).
4. Make a transcription request. The first one will trigger a permission prompt
   ("Telephone Booth Transcription would like to use Speech Recognition"). Accept.

Subsequent requests run fully on-device — no network involved, no external model
server required. Note that the response is the OpenAI default `{ "text": "…" }`
shape; verbose JSON / SRT / VTT formats are only available through the proxy
backend.
