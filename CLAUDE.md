# Kobe Assistant — guide for AI coding agents

Kobe is a notch app for macOS (`/Applications/Kobe.app`, bundle id `com.kobe-assistant.app`): a window onto a
personal assistant. The assistant's brain is Hermes Agent, a separate project that answers on a local HTTP port
(default `http://127.0.0.1:8642`); Kobe is the front end. One user per Mac. Personal, maintainer-only rules, if any, are
in an untracked `CLAUDE.local.md`.

## Where things are
- `Package.swift` — SwiftPM. `KobeKit`: all logic, no UI, fully tested. `KobeApp`: the app (SwiftUI + AppKit) as a
  library. `Kobe`: the executable, only `Sources/KobeMain/main.swift` calling `KobeApp.run()`. `KobeHook`: the tiny
  `kobe-hook` helper Claude Code hooks call. Tests: `KobeKitTests` and `KobeTests`.
- `Sources/KobeKit/` — `Brand.swift` (every identifier), `NotchMachine.swift` (closed / wings / open), `Hermes/`
  (API client, SSE), `ChatStore.swift`, `Claude/` (hook events, Unix socket server, settings installer),
  `Services/` (Stripe, Vercel, GitHub clients and rules), `WhatsApp/`, `Snapshots/` (the snapshot envelope, per-page
  data, builders, the exchange folder), `Engine/` (engine detection, the brain's providers and key checks, the
  config merge, the onboarding step machine), `StripLayout.swift`, `PageActions.swift`, `PageSelection.swift`, `WorkFeed.swift`,
  `NowRanker.swift`, `Theme.swift`, `Icons.swift`, `MacConnectors/` (Mail/Agenda/Reminders/Notes).
- `Sources/KobeApp/` — `KobeApp.swift` (entry, app delegate, `--demo`/`--open`), `AppModel.swift`, `Island/` (the
  notch panel), `Kit/` (the view kit: tab bar, strip, widget header, row, status chip, badge, buttons, footer,
  handle, undo chip, KPI; every view uses it), `Onboarding/` (the first-run window and its `Steps/`), `Engine/`
  (running the installers and the engine commands), `Snapshots/`, `Views/` (Home, Chat, Quick views, `Pages/`),
  `Settings/`, `Services/` (background pollers), `WhatsApp/`, `Voice/`, `MenuBar/`, `MacConnectors/`.
- `agent/` — Kobe Agent: Python 3, standard library only, with its own tests (`agent/tests`). It fetches Stripe,
  GitHub, Vercel and Google and writes snapshots. See `agent/README.md`.
- `Tests/KobeKitTests/` — Swift Testing; fixtures in `Fixtures/`, HTTP stubs in `Support/`. `Tests/KobeTests/` — the
  app target, headless: `Support/Fakes.swift` (`FakeHermes`, `FakePanel`, `TestSnapshotFolder`, `TestApp.model()`
  on in-memory secrets with its own defaults suite, returning a cleanup to `defer`).
- `docs/` — user docs (`google.md`, `advanced-two-users.md`).
- The snapshot contract in one line: a producer writes `<exchange>/widgets/<id>.json` atomically (envelope: id,
  version, updated_at, status, headline, detail, error, source, data; snake_case, ISO 8601 UTC, money in minor
  units, never a secret), the app only reads it, and actions go to `requests/` with answers in `results/`. The
  exchange folder is `~/Library/Application Support/Kobe/exchange`; `KOBE_EXCHANGE_ROOT` overrides it.

## Build, test, install
```
scripts/test.sh          # all tests: Swift (both targets) and the agent's Python tests. Must stay green.
scripts/bundle.sh        # build/Kobe.app (makes the local signing identity on first run)
scripts/install.sh       # quits, replaces and restarts /Applications/Kobe.app
```
`build/Kobe.app/Contents/MacOS/Kobe --demo --open <view>` runs with sample data and without touching the Keychain.

## Rules
- Swift 6 strict concurrency, SwiftUI + AppKit, macOS 26+. No third-party dependencies (Python: stdlib only).
- Logic goes in KobeKit with a test written first; the app target only wires and draws.
- Secrets live in the Keychain: never on disk, in UserDefaults, logs, URLs or process arguments. The engine's own
  files (`~/.hermes/.env`, the `~/.hermes/kobe/secrets` folder, mode 0600) are the only exception, written by the app.
- No telemetry. Network only to services the user configured, the model they chose, and GitHub for the GOWA installer.
- 0 % CPU while the notch is hidden: no timers or animation unless something is on screen or being polled.
- Never block Claude Code: `kobe-hook` exits at once when the app doesn't answer.
- Never approve a permission, and never send a WhatsApp message, without an explicit click or hotkey from the user.
  WhatsApp replies only go into chats that already exist.
- Never overwrite `~/.claude/settings.json` silently: dated backup, diff, confirm.
- UI: kit views only (`Sources/KobeApp/Kit/`). Phosphor icons only (`PhosphorIcon`, then `scripts/fetch-icons.sh`),
  no SF Symbols, no emojis. Colours from `Theme`/`K`, radii from `Radius`, type from `KFont`. Copy is short, plain
  English; the assistant's name comes from settings (`Copy`), and "Hermes" appears in the UI only on the engine
  screen and Settings › Engine.
- Identifiers (bundle id, Keychain services, data folder, ports) live in `Brand.swift`; change them together.
- Commits are local until the maintainer pushes.
