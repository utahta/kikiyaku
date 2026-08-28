# Kikiyaku

Kikiyaku is a macOS menu bar app for live transcription and translation. It listens to the microphone or to system audio, transcribes speech on-device with Apple's speech recognition, and shows the translation in a floating panel.

Transcription appears as people speak, and the translation follows about a second later. Rather than a dedicated translation engine, the transcript goes to an LLM — local or in the cloud — so the translation can draw on the conversation so far: it recovers words the recognizer got wrong, resolves phrases that are ambiguous on their own, and keeps terminology consistent throughout.

https://github.com/user-attachments/assets/38354c67-776a-458b-8b22-b666bfda33ed

Translating a public-domain recording of *Alice's Adventures in Wonderland* — read by a LibriVox volunteer — from system audio, with a 26B model running locally through Ollama.

## What it's for

Anything spoken that your Mac can play, or that a microphone can hear.

- **A call in a language you only half follow** — system audio picks up the other side, and the panel floats over the call window without taking focus from it.
- **A video with no subtitles**, or with automatic ones that are not much help — a recorded talk, a lecture, a conference session.
- **A live stream**, where subtitles are never going to arrive afterwards.
- **A podcast**, or anything else playing on your Mac.
- **Talking with someone in front of you** — the microphone with bidirectional translation, so each of you reads the panel in your own language.
- **Keeping a record** — transcription-only mode saves the session without translating anything.

## Features

- **On-device speech recognition** — Apple SpeechAnalyzer / SpeechTranscriber (macOS 26+). Recognition runs on-device and audio never leaves your Mac (an Internet connection may be required once to download the selected language's recognition model). Translation is a separate, explicit choice: a local LLM keeps everything on your machine, a remote backend receives text and recent conversation context, never audio (see [Privacy](#privacy)). Live in-progress text is shown while a sentence is still being spoken.
- **Four modes**, from one language pair:
  - **One-direction translation** — the source language is recognized and translated into the target language.
  - **Bidirectional translation** — both languages are recognized at once and each utterance is translated into the other, for conversations where both are spoken. Which language an utterance was in is judged from recognition confidence, which throws out most of what the other language's recognizer made of it — though now and then a reading clears the bar in both, and the utterance turns up twice.
  - **Transcription only** — one language, no translation.
  - **Bilingual transcription** — both languages recognized and recorded, no translation.
- **Microphone, system audio, or both** — system audio transcribes whatever your Mac is playing; with both, your own voice comes from the microphone at the same time.
- **Pluggable LLM translation backends**
  - **OpenAI-compatible API** (the default) — works with OpenAI's cloud (`https://api.openai.com`) or any OpenAI-compatible local / self-hosted server such as LM Studio, llama.cpp, Ollama, or vLLM. With a local MoE model this gives fully-offline translation at sub-second latency.
  - **Claude CLI** — drives a persistent `claude` process using your existing Claude subscription. Launched in an isolated, minimal configuration (no settings, no MCP servers, no tools, no session persistence).
- **Conversation-aware translation** — every request carries the session's history, so terminology stays consistent and mis-recognized words are often recovered.
- **Provisional translation** (one-direction modes, OpenAI-compatible backend) — a long utterance is translated sentence by sentence as it is spoken, shown in a pale style and replaced by the final translation when the utterance ends.
- **Floating panel** — always on top, never steals focus (works over full-screen apps). Adjustable font size, background opacity, and ordering (newest-on-top with a pinned live region, or bottom-follow, which keeps the newest line in view until you scroll up to re-read something). Timestamps come from when the words were spoken, not when they were recognized, so both panels and the saved transcript agree.
- **A panel per language, in the bidirectional modes** — with translation on, each panel carries the whole conversation in one language: what was said in it, plus translations of everything said in the other, so you can read one and share the other. Bilingual transcription has no translations to fill those gaps, so there each panel holds only what was actually said in its language. They snap into alignment when dragged together, and a menu command arranges them.
- **Language pairs** — any two languages SpeechTranscriber supports (about 30 locales), script-aware (e.g. zh-Hans vs zh-Hant).
- **Confidence filter** — in the one-direction modes, an utterance recognized with low confidence (usually chatter in another language) stays in the transcript but is not translated. In the bidirectional modes the same threshold discards low-confidence candidates as probable wrong-language readings; results that land close together may still both survive.
- **Session transcripts** — on stop, the session is saved as JSONL (one utterance per line: time, capture channel, recognized language, source, translation, confidence).
- **Auto-stop** — stops and saves after N minutes of silence.
- **Japanese / English UI.**

## Requirements

- macOS 26.0 or later, Apple Silicon
- For translation, one of:
  - An OpenAI-compatible endpoint (the default backend) — a local server such as [LM Studio](https://lmstudio.ai/), which needs no key, or OpenAI's cloud with an API key
  - [Claude Code CLI](https://code.claude.com/) (`claude`) with an active subscription or API login

Transcription-only use needs no backend at all.

## Install

Download `Kikiyaku_v*_macos_arm64.zip` from the [releases page](https://github.com/utahta/kikiyaku/releases), unzip it, and move `Kikiyaku.app` to your Applications folder. Then clear the quarantine flag once:

```sh
xattr -dr com.apple.quarantine /Applications/Kikiyaku.app
```

Kikiyaku is not notarized by Apple, so macOS quarantines the download and refuses to open it — usually with a message claiming the app is damaged. Nothing is damaged; macOS simply cannot check a signature Apple never issued, and since macOS 15 there is no longer a right-click-to-open way around it. The command above is you saying you trust this app anyway, so run it only for a copy you got from the releases page above. [Building it yourself](#building-from-source) avoids the question entirely.

The app is signed ad hoc, which means its signature changes with every release. macOS ties permissions to that signature, so the microphone and speech recognition prompts come back after each update.

## Setup

1. Launch the app — a captions icon appears in the menu bar and the panel opens.
2. Open **Settings…** from the menu bar icon and pick the mode, the audio input, and the two languages. The less obvious settings have a **?** beside them with a short explanation.
3. Press the round **record button** in the panel's footer. On first use, macOS asks for microphone (or system audio recording) and speech recognition permission, and the recognition model for each language in use is downloaded automatically.

Session settings are fixed while a session is running — stop first to change the mode, the audio input, the languages, or the backend. The display settings (font size, opacity, ordering, and so on) can be changed at any time and take effect immediately.

For the bidirectional modes, earphones are recommended when capturing both the microphone and system audio, so the microphone does not pick up the speakers as well.

### Backend: OpenAI API

Select **OpenAI-compatible (API / local)**, keep the URL `https://api.openai.com` and the model `gpt-5.6-terra` (the default — see [Choosing a model](#choosing-a-model)), and paste your API key. Keys are stored in the macOS Keychain, **per endpoint** (scheme, host, and port), and are only ever sent to that endpoint.

### Backend: local server (Ollama, LM Studio etc.)

Select **OpenAI-compatible (API / local)** and point the URL at your server — `http://localhost:11434` for Ollama, `http://localhost:1234` for LM Studio (a trailing `/v1` also works). No key needed.

Any OpenAI-compatible server will do — llama.cpp, vLLM and the rest — and each can be set up however you prefer. What follows is one way, using Ollama:

```sh
brew install ollama                         # or download it from ollama.com

# in one terminal — everything below talks to this
OLLAMA_CONTEXT_LENGTH=16384 OLLAMA_KEEP_ALIVE=1h ollama serve

# in another
ollama run gemma4:26b-a4b-it-qat --think=false "hi"   # the 32 GB pick — see Choosing a model
```

The server has to be running before anything else: `ollama pull` and `ollama list` both talk to it and fail without it. `ollama run` downloads the model if it is not there yet, so it doubles as the first fetch — 16 GB, once. `--think=false` is there only so that this one command returns promptly instead of waiting out a paragraph of reasoning about the word "hi"; it says nothing about how Kikiyaku will use the model.

Then point Kikiyaku at `http://localhost:11434` with the model name `gemma4:26b-a4b-it-qat`. `ollama ps` shows what is in memory and the context it was loaded with.

Both environment variables are worth setting, because their defaults cause problems that are hard to attribute:

- **`OLLAMA_CONTEXT_LENGTH`.** Kikiyaku sends the conversation so far with every request, which is what lets the translation keep terminology consistent and recover mis-recognized words. A long meeting reaches some 8,600 tokens of history, and a model loaded with less silently drops the oldest part of each request rather than refusing it — so the translation quietly stops benefiting from the context it appears to have. Kikiyaku asks the server how much context the model was loaded with and trims its history to fit, so nothing breaks either way; loading with more simply lets it keep more.
- **`OLLAMA_KEEP_ALIVE`.** Ollama unloads an idle model after five minutes by default. Reloading takes tens of seconds, which lands in the middle of whatever is being said.

Ollama listens on `127.0.0.1` only; set `OLLAMA_HOST=0.0.0.0:11434` to reach it from another machine.

See [Choosing a model](#choosing-a-model) for which model to run on which machine.

### Backend: Claude CLI

Select **Claude (CLI)** as the backend. The `claude` binary is auto-detected (`~/.local/bin`, `/opt/homebrew/bin`, …) and the path can be overridden in settings. Choose a model (Sonnet is the default; Haiku is cheapest).

The CLI session is strictly serial, at roughly two to three seconds per utterance. That is fine for one-direction translation, but the bidirectional modes translate every utterance from both sides, so a lively conversation can queue up behind it; an OpenAI-compatible backend is the better fit there.

Privacy notes: recognized text (not audio) is sent to Anthropic for translation. The CLI is launched with `--setting-sources ""`, `--strict-mcp-config`, `--disallowedTools "*"` and `--no-session-persistence`, so your local Claude configuration (hooks, plugins, MCP servers) is not applied and nothing you transcribe is written to Claude's session history.

## Choosing a model

Latency is what decides whether captions are usable, so the models behind each backend were measured against each other: 33 utterances from a recorded interview, sent with the conversation history, thinking disabled, non-streaming. Local models ran in LM Studio on Apple Silicon with 64 GB. Figures are the mean per utterance, measured in August 2026.

**Local models (OpenAI-compatible API)** — what to run on which machine

| Machine | Model | Per utterance | |
|---|---|---|---|
| Apple Silicon, 64 GB | **qwen3.6 35B A3B** (MoE, ~3B active, MLX 4bit) | **0.84 s** | best on both counts: fastest, and the most faithful with figures |
| Apple Silicon, 32 GB | **gemma4 26B A4B QAT** (MoE, ~3.8B active) | 0.91 s\* | recommended because 15.6 GB loaded leaves the rest of a 32 GB machine room to work; a little looser with figures than the 64 GB pick |
| Less than 32 GB | — | | nothing tried here fit with room to spare; a remote endpoint is the better answer |

Model names differ by server: `gemma4:26b-a4b-it-qat` on Ollama is `google/gemma-4-26b-a4b-qat` in LM Studio, and `qwen3.6-35b-a3b` likewise carries a `qwen/` prefix there. `ollama list` and `lms ls` give the exact string to put in the settings.

\* Every local figure was measured on the 64 GB machine. The 32 GB row says what fits there, not what it clocks there.

**OpenAI API**

| Model | Per utterance | |
|---|---|---|
| **gpt-5.6-terra** | **1.3 s** | the pick of those tried — and at $2 / $12 per 1M tokens, 40% of what gpt-5.5 costs |
| gpt-5.5 | 1.5 s | $5 / $30 per 1M tokens |
| gpt-5.4-mini | 0.95 s | quicker still, but the least reliable with figures |

**Claude CLI**

Measured through the persistent `claude` process, which is how this backend runs. (Driving the same models over the HTTP API instead was no faster, so the CLI costs nothing in latency.)

| Model | Per utterance | |
|---|---|---|
| **Sonnet 5** | 2.2 s | the default, and the balanced choice |
| Opus 5 | 2.3 s | the same speed, and the best of the three at recovering mis-recognitions |
| Haiku 4.5 | 1.0–1.7 s | the quickest and cheapest, with the least to give when the recognition is poor |

What the numbers amount to:

- **Active parameters decide the speed, not the model's size.** An MoE model with about 3B active runs comfortably under a second, which is why the recommendations above are all MoE. A dense model of comparable total size took ten times as long in the same test — a dense 14B came in at 8.7 s per utterance, and a dense 27B was abandoned after one — so a model that is not MoE is unlikely to keep up whatever its size.
- **Thinking is time spent not translating**, and Kikiyaku asks for none of it. A model left to think produced 452–766 tokens of reasoning for a sentence whose translation is 17, taking 6.8–11.9 s instead of 0.3 s. The request carries `reasoning_effort: none` to every endpoint, which costs nothing where thinking was already off and saves that much where it was not, so there is no per-model setting to remember.
- **A good local MoE model beats every remote backend on latency**, with nothing leaving the machine.
- **Numbers are where the cheaper models give way.** A figure like "180 million units" comes back with the wrong magnitude, the wrong unit, or converted into a currency nobody asked for. The failure is not loud — the sentence still reads well — so if figures matter, stay with the larger models.

Local figures depend on the machine as much as on the model, so another Apple Silicon generation will land somewhere else. Remote latency varies with the time of day; the ordering above held up across alternating runs, but small gaps between neighbouring models should not be read as settled.

## Usage

- **Start / Stop** — the round button in the panel's footer. Stopping saves the session as JSONL to `~/Library/Application Support/kikiyaku/` (changeable in settings).
- **Click a line** to see the other side of it: a translation reveals the original it came from, and clicking again hides it. (With "Show source text" on, both are always visible.)
- Closing a panel hides it; reopen from the menu bar icon (**Show Panel**). **Arrange Panels Side by Side** lines the two language panels up.
- Changing the mode or the language pair clears the panel, since the rows on screen belong to the pair that produced them. The transcript itself is already on disk — this only affects the copy on screen.

## Privacy

Speech recognition always runs on-device; audio is never sent anywhere. (Downloading a language's recognition model on first use is the one network access recognition itself may need.) What leaves your machine beyond that depends only on the translation backend you configure:

| Backend | Audio | Recognized text |
|---|---|---|
| None (the transcription-only modes) | never sent | never sent |
| OpenAI-compatible — local server (LM Studio etc.) | never sent | stays on your machine / LAN |
| OpenAI-compatible — remote endpoint (OpenAI cloud, or any URL you configure) | never sent | sent to that endpoint, together with recent conversation history |
| Claude CLI | never sent | sent to Anthropic, together with the session's conversation history |

- The OpenAI-compatible backend sends text to exactly the URL you configure — the destination is determined entirely by that setting.
- Translation requests include recent conversation history (recognized text and translations from the session) as context, not just the current utterance. In the bidirectional modes both languages share one session, so that history holds both sides of the conversation.
- Capturing system audio sends nothing anywhere by itself, but it does mean everyone else on a call — and anything else your Mac plays — is transcribed, and if translation is on, their words go to the backend you configured, the same as your own.
- Transcripts are only written to the local save directory you configure.
- API keys are stored in the macOS Keychain, per endpoint, and are only ever sent to that endpoint.

## Building from source

Building needs a Swift 6 toolchain — Xcode, or the Command Line Tools.

```sh
./scripts/build.sh
open build/Kikiyaku.app
```

The script builds with SwiftPM, assembles `build/Kikiyaku.app`, signs it, and stamps the version from the `VERSION` file into the bundle. With Xcode installed it also compiles the app icon into an `Assets.car`, without which macOS 26 draws the icon on a plate in the Dock.

### Signing (recommended)

By default the app is signed ad hoc, which means macOS resets the microphone and speech recognition permissions on **every rebuild**. To keep permissions across rebuilds, create a self-signed code signing certificate named `kikiyaku-dev` — the build script picks it up automatically:

1. Open **Keychain Access** → menu **Keychain Access > Certificate Assistant > Create a Certificate…**
2. Name: `kikiyaku-dev`, Identity Type: *Self-Signed Root*, Certificate Type: *Code Signing* → Create.

Alternatively, set `KIKIYAKU_CODESIGN_IDENTITY` to any identity you prefer.

## License

[MIT](LICENSE)
