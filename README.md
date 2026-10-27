# Kobe Assistant

A personal assistant that lives in the notch of your Mac. Move the pointer to the notch and it opens: a chat with
your assistant, a ranked "what needs you" list, and one page per connection (WhatsApp, Mail, Calendar, Reminders,
Notes, Google, Stripe, GitHub, Vercel). You can rename it; it is called Kobe until you do.

Kobe is the front end. The thinking is done by [Hermes Agent](https://hermes-agent.nousresearch.com), a separate
open-source engine that runs on your Mac and calls the model you choose.

Screenshots coming.

## What you need

- macOS 26 (Tahoe) or later, on Apple Silicon.
- The Xcode Command Line Tools (`xcode-select --install`; Swift 6.2).
- Hermes Agent. The first run installs it for you if it is missing
  (`curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash`). Docs:
  [installation](https://hermes-agent.nousresearch.com/docs/getting-started/installation/),
  [API server](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server).
- A model: a key for Claude (recommended), OpenAI or OpenRouter, or [Ollama](https://ollama.com) running on the Mac
  (free, private, weaker answers).

## Install

```bash
git clone https://github.com/guccimono/Kobe-AI-Assistant.git
cd Kobe-AI-Assistant
scripts/bundle.sh      # builds build/Kobe.app; makes a local signing certificate on first run
scripts/install.sh     # copies it to /Applications and starts it
```

The local certificate keeps macOS permissions (Calendar, Mail...) from resetting after every rebuild. A notarized
download will come once there is an Apple Developer ID; until then you build it yourself.

## The first run (about five minutes)

Kobe opens a window with eight steps. Nothing asks macOS for a permission until you say so.

1. **Welcome.** What Kobe is, and the two parts it needs: an engine and a brain.
2. **Your assistant.** Name it, pick a voice (or none) and a tone.
3. **The engine.** Kobe looks for Hermes Agent. If it is missing, one button opens Terminal with the official
   installer, where you can read what it does. Then press Check.
4. **The brain.** Choose Claude, OpenAI, OpenRouter or Ollama and paste the key. Kobe tests the key with one call
   to the provider before saving it.
5. **Connecting.** Kobe turns on the engine's local API, hands it your key, restarts it and says hello.
6. **Your Mac.** What your assistant can see: Mail, Calendar, Reminders and Notes. Nothing to choose here: each
   one asks macOS for permission the first time you open its page, and you can say no to any of them.
7. **Connections.** Add Stripe, GitHub, Vercel, WhatsApp or Google now, or later in Settings.
8. **Ready.** Move the pointer to the notch. From any app, Control-Option-Space asks a quick question.

Rerun it any time: Settings › Home › Set up again.

## Connections

| Connection | What it needs |
|---|---|
| Mail, Calendar, Reminders, Notes | Nothing to install. macOS permission when you switch each on. Mail and Notes must be open while Kobe reads them. Read-only, except adding and ticking reminders. |
| WhatsApp | One click installs [GOWA](https://github.com/aldinokemal/go-whatsapp-web-multidevice) (the gateway), then scan a QR code with your phone. Replies only go into chats that exist, and only on your click. |
| Stripe | A restricted, read-only API key. |
| GitHub | A fine-grained token with read access to the repositories you want. |
| Vercel | A token. |
| Google | Your own Google Cloud client, signed in once in Terminal: [docs/google.md](docs/google.md). |

Stripe, GitHub, Vercel and Google are fetched by Kobe Agent (`agent/`), which the first run installs next to the
engine. Hermes under a separate macOS user is possible: [docs/advanced-two-users.md](docs/advanced-two-users.md).

## Privacy

- Keys live in the macOS Keychain, plus the engine's own files (`~/.hermes/.env` for the model key,
  `~/.hermes/kobe/secrets`, mode 0600).
- Nothing leaves your Mac except calls to the model you chose and to the services you connected.
- No account with us, no analytics, no telemetry.
- Mail, Calendar, Reminders and Notes are read locally and only shown in the notch, or sent to the engine when you
  ask something that needs them.
- Nothing is approved, sent or deleted without your click.

## Build and test

```bash
scripts/test.sh                       # Swift tests (KobeKit, the app) and the agent's Python tests
swift test --filter <Suite>           # one suite
build/Kobe.app/Contents/MacOS/Kobe --demo --open home    # sample data, no Keychain
```

See [CONTRIBUTING.md](CONTRIBUTING.md) and [CLAUDE.md](CLAUDE.md) (code layout and rules, for people and agents).

## Write your own widget

Every page draws a JSON file; anything can write one. Put it in
`~/Library/Application Support/Kobe/exchange/widgets/<id>.json`:

```json
{
  "id": "stripe", "version": 1, "updated_at": "2026-10-24T09:30:00Z", "status": "ok",
  "headline": "3 payments today", "detail": "EUR 120.00 gross", "error": null, "source": "agent", "data": {}
}
```

- `status` is `ok`, `needs_you`, `failed` or `not_set_up`. `source` is `app` or `agent`.
- snake_case keys, ISO 8601 UTC dates, money in minor units (cents), never a secret.
- Write atomically (temp file, then rename). The app watches the folder; a stale file is shown as stale.
- Actions go the other way: the app drops a request in `requests/`, you answer in `results/`.

Details: `Sources/KobeKit/Snapshots/WidgetSnapshot.swift` and `agent/README.md`.

## Credits

Released under the [MIT License](LICENSE); see [NOTICE](NOTICE).

- The notch look and motion, and the Stripe, Vercel and GitHub clients, derive from Coucou by Louis Raillé (MIT).
- Icons: [Phosphor Icons](https://phosphoricons.com) (MIT).
- [Hermes Agent](https://hermes-agent.nousresearch.com) (Nous Research) and GOWA are separate projects, installed by
  their own installers. Kokoro (local voice) is set up by `scripts/setup-kokoro.sh`; its model files (`kokoro-v1.0.onnx`, `voices-v1.0.bin`) come from the [kokoro-onnx releases](https://github.com/thewh1teagle/kokoro-onnx) and go in `~/Library/Application Support/Kobe/kokoro`.
