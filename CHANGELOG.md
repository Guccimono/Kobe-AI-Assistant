# Changelog

## 1.0 — unreleased

- Onboarding: an eight-step first run (Welcome, Your assistant, The engine, The brain, Connecting, Your Mac,
  Connections, Ready) that detects Hermes Agent, offers its official installer, and never triggers a macOS
  permission prompt on its own.
- The brain: pick a model provider (Claude, OpenAI, OpenRouter) or Ollama; the key is checked before it is saved.
- Kobe Agent in `agent/`: the Stripe, GitHub, Vercel and Google connectors, running as you under a LaunchAgent.
- Public repository: personal data scrubbed from sources and fixtures, identifiers rebranded
  (`com.kobe-assistant.app`), the assistant's name configurable, MIT licence and NOTICE.

### Known gaps (follow-ups)

- No uninstall path yet for the two LaunchAgents Kobe installs (`com.kobe-assistant.gateway`,
  `com.kobe-assistant.agent`). By hand: `launchctl bootout gui/$(id -u)/<label>`, then delete
  `~/Library/LaunchAgents/<label>.plist`.
