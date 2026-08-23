# Kikiyaku

A macOS menu bar app that transcribes meeting audio with Apple's on-device
speech recognition and shows live LLM translations in a floating panel.

Built for situations like sitting in a meeting held in a language you only
half catch: the panel floats above your meeting window, shows what is being
said as it is recognized, and fills in a translation a second later.

## Features

- **On-device speech recognition** — Apple SpeechAnalyzer / SpeechTranscriber
  (macOS 26+). Audio never leaves your Mac. Live in-progress text is shown
  while a sentence is still being spoken.
- **Pluggable LLM translation backends**
  - **Claude CLI** — drives a persistent `claude` process using your existing
    Claude subscription. Launched in an isolated, minimal configuration
    (no settings, no MCP servers, no tools, no session persistence).
  - **OpenAI-compatible API** — works with OpenAI's cloud
    (`https://api.openai.com`) or any OpenAI-compatible local / self-hosted
    server such as LM Studio, llama.cpp, Ollama, or vLLM. With a local MoE
    model this gives fully-offline translation at sub-second latency.
- **Conversation-aware translation** — the backend sees the meeting history as
  context, so speech-recognition errors are often recovered from context.
- **Floating panel** — always on top, never steals focus (works over
  full-screen meeting apps). Adjustable font size, background opacity, and
  ordering (newest-on-top with a pinned live region, or classic bottom-follow).
- **Language pairs** — any source language SpeechTranscriber supports
  (about 30 locales), script-aware target list (e.g. zh-Hans vs zh-Hant).
- **Confidence filter** — utterances recognized with low confidence (usually
  chatter in a different language) are skipped instead of mistranslated.
- **Session transcripts** — on stop, the session is saved as JSONL
  (one utterance per line: time, source, translation, confidence).
- **Auto-stop** — stops and saves after N minutes of silence.
- **Japanese / English UI.**

## Requirements

- macOS 26.0 or later, Apple Silicon
- Swift 6 toolchain (Xcode or Command Line Tools) to build
- For translation, one of:
  - [Claude Code CLI](https://code.claude.com/) (`claude`) with an active
    subscription or API login
  - An OpenAI API key, or a local OpenAI-compatible server
    (e.g. [LM Studio](https://lmstudio.ai/))

Transcription-only use needs no backend at all.

## Build

```sh
./scripts/build.sh
open build/Kikiyaku.app
```

The script builds with SwiftPM, assembles `build/Kikiyaku.app`, and signs it.

### Signing (recommended)

By default the app is signed ad hoc, which means macOS resets the microphone
and speech recognition permissions on **every rebuild**. To keep permissions
across rebuilds, create a self-signed code signing certificate named
`kikiyaku-dev` — the build script picks it up automatically:

1. Open **Keychain Access** → menu **Keychain Access > Certificate Assistant >
   Create a Certificate…**
2. Name: `kikiyaku-dev`, Identity Type: *Self-Signed Root*,
   Certificate Type: *Code Signing* → Create.

Alternatively, set `KIKIYAKU_CODESIGN_IDENTITY` to any identity you prefer.

## Setup

1. Launch the app — a captions icon appears in the menu bar and the panel opens.
2. Press **Start**. On first use, macOS asks for microphone and speech
   recognition permission, and the recognition model for your source language
   is downloaded automatically.
3. Open **Settings…** from the menu bar icon to configure translation.

### Backend: Claude CLI

Select **Claude (CLI)** as the backend. The `claude` binary is auto-detected
(`~/.local/bin`, `/opt/homebrew/bin`, …) and the path can be overridden in
settings. Choose a model (Sonnet is the default; Haiku is cheapest).

Privacy notes: recognized meeting text (not audio) is sent to Anthropic for
translation. The CLI is launched with `--setting-sources ""`,
`--strict-mcp-config`, `--disallowedTools "*"` and
`--no-session-persistence`, so your local Claude configuration (hooks,
plugins, MCP servers) is not applied and no meeting content is written to
Claude's session history.

### Backend: OpenAI cloud

Select **OpenAI-compatible (API / local)**, keep the URL
`https://api.openai.com`, set a model (e.g. `gpt-5.5`), and paste your API
key. Keys are stored in the macOS Keychain, **per endpoint** (scheme, host,
and port), and are only ever sent to that endpoint.

### Backend: local server (LM Studio etc.)

Select **OpenAI-compatible (API / local)** and point the URL at your server,
e.g. `http://localhost:1234` (a trailing `/v1` also works). No key needed.

Tips for real-time performance with local models:

- Use a **MoE model with a small number of active parameters** and
  **thinking disabled**. Dense models ≥9B are generally too slow for
  real-time subtitles on Apple Silicon.
- In LM Studio, **turn off "Enable Thinking" in the model's settings** for
  models that support it (e.g. the Qwen family). This must be done per model;
  with thinking left on, translations are roughly 10× slower.

## Usage

- **Start / Stop** — button in the panel. Stopping saves the session as JSONL
  to `~/Library/Application Support/kikiyaku/` (changeable in settings).
- Closing the panel hides it; reopen it from the menu bar icon
  (**Show Panel**).
- Everything in settings notes whether it applies immediately or from the
  next Start.

## Privacy

- Speech recognition runs entirely on-device.
- With translation enabled, the recognized **text** is sent to the backend you
  configured — Anthropic (Claude CLI), OpenAI, or your own server. Audio is
  never sent anywhere.
- With a local backend, nothing leaves your machine.
- Transcripts are only written to the local save directory you configure.

## License

[MIT](LICENSE)
