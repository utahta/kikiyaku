# Model measurements — August 2026

These are historical translation measurements, not an end-to-end caption latency benchmark or a ranking of currently available models. For setup instructions, return to the [README](../README.md#translation-backends).

## Scope and conditions

- Input: 33 utterances from a recorded interview, with recognition errors, translated with conversation history.
- Measurement: complete translation response time per utterance, non-streaming, with thinking disabled. Values below are means unless otherwise stated.
- Local hardware: Apple Silicon with 64 GB of memory. The original summary does not identify the chip generation or server versions, so the figures are not sufficient to reproduce the exact environment.
- Local repeatability check: 10 runs of the same 33 utterances through Ollama for Gemma 4. This repeats the same sample; it is not a survey of different languages or conversations.
- Remote measurements: hosted OpenAI API requests and a persistent Claude CLI process. These include service and network delay at the time of testing.

These results predate the current default of resetting OpenAI-compatible conversation history after 20 completed exchanges while retaining one exchange, and the explicit request for temperature zero. They should not be presented as measurements of the current application settings. Speech recognition delay, waiting for an utterance to finalize, and panel rendering are outside the measurement.

## Local model

| Model | Mean per utterance | Other recorded results |
|---|---|---|
| Gemma 4 26B A4B QAT | 0.88 s | Per-run means: 0.85–0.90 s; median: 0.80 s; p90: 1.37 s across the 10-run test. |

The model identifier used with Ollama was `gemma4:26b-a4b-it-qat`; the LM Studio identifier recorded separately was `google/gemma-4-26b-a4b-qat`. Use the identifier reported by your server when configuring Kikiyaku.

The recorded loaded size was 15.6 GB. This motivated the 32 GB-or-more guidance for this model, but does not establish its latency on a 32 GB Mac. Memory use also depends on context size and server settings, and speech recognition and other applications need additional memory.

### Translation quality

In nine of the ten runs, the model rendered a passage about “180 million units” as “1.8 trillion yen of revenue.” Another passage with garbled recognition of film box-office figures produced different numbers in every run. Round figures and percentages in this sample were translated correctly in all ten runs.

These observations show why fluent output is not enough to establish accuracy. They are not a general numerical-accuracy score. Check important numbers against the original recording, not only the recognized text.

## OpenAI API

| Model used in the test | Mean per utterance | Observation on this sample |
|---|---|---|
| gpt-5.6-terra | 1.3 s | The choice favored in the original comparison. |
| gpt-5.5 | 1.5 s | Slower than gpt-5.6-terra in these runs. |
| gpt-5.4-mini | 0.95 s | Faster, but the least reliable of these three with figures. |

These identifiers and measurements describe the August tests. They do not establish current availability or pricing; use a model available to your account and check the provider's billing before use.

## Claude CLI

These measurements used a persistent `claude` process, as Kikiyaku does. Separate HTTP API tests did not show a latency advantage under the conditions tested.

| Model used in the test | Mean per utterance | Observation on this sample |
|---|---|---|
| Sonnet 5 | 2.2 s | A balance of speed and recognition-error recovery. |
| Opus 5 | 2.3 s | Best recognition-error recovery among the three tested Claude models. |
| Haiku 4.5 | 1.0–1.7 s | Faster, but weaker when recognition was poor. |

The CLI handles translation requests serially. These single-request timings do not include the extra queueing that a live conversation can create.

## What the comparison supports

- The tested local MoE model completed translations quickly on the measured machine. That result does not establish that local inference always beats a hosted service, or that every dense model is too slow.
- Some tested dense models were much slower: a 14B model averaged 8.7 s per utterance, and a 27B trial was stopped after one utterance. Model architecture, output length, and server configuration all matter; total parameter count alone is not enough to choose a model.
- Reasoning can add substantial delay. In a separate short test, a model generated 452–766 reasoning tokens for a 17-token translation, taking 6.8–11.9 s instead of 0.3 s. That is an observation from that test, not an expected penalty for every model. Kikiyaku requests no reasoning where supported; a backend may reject or ignore that option.
- Numerical mistakes appeared in otherwise fluent translations. Neither a larger model nor conversation context should be treated as a guarantee of accuracy.

Local latency depends on the chip, available memory, server version, and inference settings. Remote latency also varies with network and service load. A fresh comparison should record those conditions, the application revision, history policy, temperature, streaming mode, and separate timings for the first displayed text and the completed translation.
