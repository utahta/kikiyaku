# Kikiyaku

Kikiyaku is a macOS menu bar app for live transcription and LLM-powered translation. It listens to the microphone or system audio, transcribes speech on-device with Apple's speech recognition, and shows captions in a floating panel.

Kikiyaku uses an LLM to translate the meaning behind what is said, not just the words — aiming for natural, readable captions even when speech is informal or fragmented. Recent conversation and an optional glossary provide additional context.

Use it to follow a call, watch a video without subtitles, read along with a podcast, or talk with someone in another language. Run translation with a local LLM or a remote backend, or use transcription alone without a translation backend.

https://github.com/user-attachments/assets/38354c67-776a-458b-8b22-b666bfda33ed

Translating a public-domain recording of *Alice's Adventures in Wonderland* — read by a LibriVox volunteer — from system audio, with a 26B model running locally through Ollama.

## Features

- **On-device speech recognition** with live in-progress text. Kikiyaku does not send audio to a translation service.
- **Microphone, system audio, or both**, with one-direction translation, bidirectional translation, and transcription-only modes.
- **Local or remote translation** through an OpenAI-compatible API or the Claude CLI.
- **Floating captions** that stay above other windows without taking focus, including over full-screen apps. Bidirectional modes have a panel for each language.
- **Session profiles and glossaries** for different meetings, language pairs, and terminology.
- **Saved transcripts** in JSONL format, with optional auto-stop after silence.
- **Japanese / English UI.**

## Requirements

- macOS 26.0 or later, Apple Silicon.
- For translation, an OpenAI-compatible endpoint such as [Ollama](https://ollama.com/), [LM Studio](https://lmstudio.ai/), or a hosted API; alternatively, an installed and authenticated [Claude CLI](https://code.claude.com/).

Transcription-only modes need no translation backend. Speech recognition models may require an Internet connection for their initial download.

Local translation has additional memory requirements depending on the model. The [Ollama example below](#ollama-example) uses a model intended for Macs with 32 GB or more; that is not a requirement for Kikiyaku itself. You can use a remote endpoint without loading an LLM on your Mac.

## Install

With [Homebrew](https://brew.sh/):

```sh
brew install --cask utahta/tap/kikiyaku
```

Use `brew upgrade --cask kikiyaku` to update.

Alternatively, download `Kikiyaku_v*_macos_arm64.zip` from the [releases page](https://github.com/utahta/kikiyaku/releases), unzip it, and move `Kikiyaku.app` to your Applications folder.

### Opening a downloaded app

The release app is signed ad hoc and is not notarized by Apple, so macOS may block it from opening. See [Apple's explanation of these security warnings](https://support.apple.com/en-us/102445). If you downloaded the app from this project's releases page and trust that copy, you can remove its quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/Kikiyaku.app
```

This removes the quarantine flag from that app; it does not verify that the app is safe. Do not use it to dismiss warnings for an untrusted download. You can also [build from source](#building-from-source). Ad-hoc signing can cause macOS to request permissions again after an update.

## Quick start

1. Launch Kikiyaku. A captions icon appears in the menu bar and the panel opens.
2. Press the panel's **record button**. On a fresh install, this opens the editor for the **Not configured** profile.
3. Choose a mode, audio input, and languages. For translation, configure a [backend](#translation-backends); the **Preset** menu fills in connection settings. For transcription only, no backend is needed. Save the profile.
4. Press the record button again to start. Approve the requested speech recognition and audio capture permissions. Any missing recognition models are downloaded automatically.
5. Press the button again to stop and save the transcript.

For a quick trial without setting up an LLM, choose **Transcription only** and **System audio**, then play something in the selected source language.

## Usage

### Modes and audio input

| Mode | What it does |
|---|---|
| One-direction translation | Recognizes the source language and translates into the target language. |
| Bidirectional translation | Recognizes both languages and translates each utterance into the other language. |
| Transcription only | Recognizes one language without translating. |
| Bilingual transcription | Recognizes both languages without translating. |

Choose **System audio** for sound playing on your Mac, **Microphone** for people speaking near you, or **Both** to capture a call and your own voice. Use earphones with **Both** to avoid capturing the speakers again through the microphone.

Recognized languages must be supported by Apple's SpeechTranscriber. In one-direction translation, the target language does not need speech recognition support; translation quality depends on the model.

### Captions and transcripts

- **Click a translated line** to reveal its source text; click again to hide it. Enable **Show source text** to keep both visible.
- **Close a panel** to hide it, then use **Show Panel** from the menu bar to reopen it. **Arrange Panels Side by Side** aligns the two language panels.
- **Adjust the display** in Settings: font size, opacity, and newest-first or bottom-follow ordering take effect immediately.
- **Stop to save** the session to `~/Library/Application Support/kikiyaku/` by default. The save directory and auto-stop silence interval are configurable in Settings.

Each saved JSONL line contains an utterance's time, capture channel, recognized language, source text, translation, and confidence. Changing the mode or language pair clears the displayed rows, not the saved transcript.

### Profiles and glossaries

A profile saves the mode, audio input, languages, translation connection, and a reference to one optional glossary. Create or edit profiles in **Settings…**, and switch them there or from the menu bar. Stop the session before editing or switching profiles. Display settings are shared across profiles; API keys are stored separately per endpoint.

Open **Settings… → Manage Glossaries…** to create a named glossary, then select it in each profile's **Glossary** menu. Multiple profiles can use the same glossary; copying a profile keeps that reference without duplicating the glossary. New profiles start with **None**. Enter names and technical terms in the glossary editor, one mapping per line:

```text
締め切り = deadline
ニューヨーク = New York
```

The glossary is included in the translation prompt for either translation direction and either backend, including when you use a custom system prompt. It guides the LLM rather than changing speech recognition or applying exact text replacements. Choose **None** to use no glossary. Transcription-only modes keep the reference but do not use its text.

Saving a glossary updates it for every profile that uses it. You can edit glossaries during a session, but that session keeps the text captured at startup; changes take effect on the next start. Editing uses a local draft, so Cancel leaves saved values unchanged. The manager lists the profiles using each glossary and allows deletion only when none refer to it. Removing a profile or changing its reference does not automatically delete a glossary.

Existing per-profile glossary text is migrated automatically, preserving whitespace and creating a separate glossary for each nonempty text, even when two texts match. Profiles with no text use **None**. The old settings are retained for recovery, but edits made after migration are stored only in the new catalog; switching back to an older app version does not synchronize those edits. If the catalog cannot be read, Settings offers a backup of the stored data before explicit recovery from the old settings (or initialization if none exist). Recovery loses post-migration edits, so prefer a valid backup or a compatible app version.

The existing CLI key remains available:

```sh
defaults write com.utahta.kikiyaku glossary -string '締め切り = deadline'
```

An external text change creates a new glossary for the selected profile only; it does not overwrite a shared glossary. Empty or whitespace-only text removes that profile's reference. Changes are read at startup, when the app is reactivated or settings/profile menus are opened, before recording, and before settings are saved. If a profile draft replaces a just-imported reference, the imported text is kept as an unused glossary and a notice is shown. Interrupted mirror writes are repaired from the catalog; an external write equal to the previous synchronization baseline cannot be distinguished from such an interruption, so the catalog wins in that case.

### Provisional translation

Provisional translation is optional and **off by default** for new profiles. With an OpenAI-compatible backend in one-direction translation, it can translate completed sentences within an ongoing utterance. These appear in a pale style and are replaced by the final translation when the utterance ends. Existing profiles retain their saved setting.

## Translation backends

### Local server

Choose the **Ollama** or **LM Studio** preset, then enter an installed model name or use **Fetch models** to select one. Default endpoint URLs are `http://localhost:11434` for Ollama and `http://localhost:1234` for LM Studio; a trailing `/v1` also works. A local server without authentication needs no API key.

Other servers exposing a compatible Chat Completions API, such as llama.cpp or vLLM, can be configured by choosing **OpenAI-compatible** and entering the endpoint and model name. The server must be running before you start translation.

#### Ollama example

One tested local model is `gemma4:26b-a4b-it-qat`. Its recorded loaded size was about 15.6 GB on a 64 GB Apple Silicon Mac; plan for 32 GB or more for this example, with room for speech recognition and other apps. See the [model measurements](docs/model-measurements.md) for test conditions and limitations.

```sh
brew install ollama

# In one terminal, start the server.
OLLAMA_KEEP_ALIVE=1h ollama serve

# In another terminal, download and load the model.
ollama run gemma4:26b-a4b-it-qat --think=false "hi"
```

If Ollama is already running as an app or service, use that server instead of starting a second one. Server environment variables must be configured on that running instance. The example keeps an idle model loaded for an hour to avoid reload delays; see the [Ollama configuration guide](https://docs.ollama.com/faq#how-do-i-keep-a-model-loaded-in-memory-or-make-it-unload-immediately).

In Kikiyaku, choose the **Ollama** preset and enter `gemma4:26b-a4b-it-qat`. The command's `--think=false` applies only to that command; Kikiyaku separately asks the backend to skip reasoning. If your model does not honor that request, disable thinking in the server's model settings.

### Hosted OpenAI-compatible API

Choose the **OpenAI** preset for OpenAI's API, or enter another provider's endpoint under **OpenAI-compatible**. Select a model available to your account and enter the API key. The preset fills in a model name, but you can change it or use **Fetch models**. Model availability and billing depend on the provider.

Keys are stored in the macOS Keychain per endpoint (scheme, host, and port), and sent only to that endpoint.

### Claude CLI

Install and authenticate the CLI first, then choose the **Claude CLI** preset. Kikiyaku detects the `claude` binary in common installation paths, including `~/.local/bin` and `/opt/homebrew/bin`; you can override its path in Settings. Sonnet is preselected.

This backend uses a persistent CLI process and translates utterances serially. A fast conversation can outpace translation and create a queue. See the [model measurements](docs/model-measurements.md) for recorded timings, rather than treating them as a fixed delay.

## Privacy and limitations

### Where data goes

Speech recognition runs on-device. Kikiyaku does not upload captured audio; downloading a recognition model on first use may require network access. Translation sends text according to the backend you configure:

| Translation setup | Text destination |
|---|---|
| Transcription-only modes | No translation service. |
| Local model running on the same Mac | The local server on your Mac. |
| Server on another machine, including your LAN | That machine. |
| Hosted API or Claude CLI | The configured API provider, or Anthropic for the CLI. |

Translation requests include source text, translations from retained conversation history, and your glossary. In bidirectional translation, the context includes both languages. A local server may itself forward requests elsewhere, so check its configuration if you need all processing to stay on your Mac.

The Claude CLI is launched without user settings, configured MCP servers, or tools, and with session-history persistence disabled. Kikiyaku still saves its own transcripts to your configured directory. A cloud-synced save directory may upload those files independently of Kikiyaku.

System audio includes other people on a call and anything else your Mac plays. Their words are transcribed and, when translation is enabled, sent to your chosen backend too.

### Accuracy and delay

- **Translations can be wrong**, especially names, numbers, and units. Context and glossaries can help but do not guarantee correctness; check the original audio when accuracy matters, since the source text can also contain recognition errors.
- **Conversation context is limited.** By default, the OpenAI-compatible backend resets its history after 20 completed exchanges, retaining only the latest exchange. It does not remember the whole meeting. Increasing the server's context window alone does not increase this limit.
- **Bilingual recognition can produce duplicates.** Both recognizers sometimes accept the same utterance. The confidence filter reduces wrong-language readings but does not eliminate them; it can also discard valid low-confidence speech. In one-direction modes, low-confidence speech remains in the transcript but is not translated.
- **Caption delay varies** with speech recognition, the model, hardware, network, and queued requests. The [historical model timings](docs/model-measurements.md) measure translation completion, not the time from speaking to seeing a caption.

## Building from source

Building needs a Swift 6 toolchain and the macOS 26 SDK, provided by a compatible Xcode or Command Line Tools installation. From the repository directory:

```sh
./scripts/build.sh
open build/Kikiyaku.app
```

The script builds with SwiftPM, assembles and signs `build/Kikiyaku.app`, and reads the version from `VERSION`. With Xcode installed, it also compiles the app icon into an asset catalog. Run `swift test` to execute the test suite.

### Signing

The script uses ad-hoc signing unless a signing identity is available. To keep a stable identity across local builds and avoid repeated permission prompts, create a self-signed code signing certificate:

1. Open **Keychain Access** → **Keychain Access > Certificate Assistant > Create a Certificate…**.
2. Name: `kikiyaku-dev`, Identity Type: *Self-Signed Root*, Certificate Type: *Code Signing* → Create.

The build script picks up `kikiyaku-dev` automatically. Alternatively, set `KIKIYAKU_CODESIGN_IDENTITY` to your preferred identity.

## License

[MIT](LICENSE)
