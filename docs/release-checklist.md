# Release checklist

For the maintainer. Work top to bottom; do not publish until every box in 1 and 2 is ticked.

## 1. Pre-publish checks

- [ ] `swift test --filter ScrubTests` is green in the private repo (no personal names, keys or paths in the tree).
- [ ] `scripts/export-public.sh` finishes with "Export ready". It copies the tree to a new folder, makes one commit,
      greps for personal and third-party names (only `LICENSE`, `NOTICE`, the two-users guide, this file and the
      public repository URL may match) and runs `scripts/test.sh` inside the export.
- [ ] `git -C <export> log --oneline | wc -l` prints 1.
- [ ] Someone who has never seen the project reads `README.md` once and can install and reach the first chat
      without asking you anything.

## 2. End-to-end on a throwaway macOS user

Done by the owner, with the results read back by the agent.

1. System Settings › Users: add standard user `kobe-test`. Log in. Copy `build/Kobe.app` from the export to its
   `/Applications`.
2. **Run 1 — nothing installed.** Welcome → name "Mira" → engine shows "isn't installed yet" → Install (Terminal) →
   Check → Brain: Claude with a real key (the owner's, typed by the owner) → Connecting ticks five lines → hello
   appears → Mac → Connections (skip) → Ready opens the notch. Then check:
   - `~/.hermes/config.yaml` has `gateway.api_server` with a key;
   - `~/.hermes/.env` has `ANTHROPIC_API_KEY`;
   - `hermes config get provider` and `hermes config get model` show the provider and model Kobe set (Connecting
     line 1). The values in `Brain.modelConfig` couldn't be checked offline: if Hermes names them differently,
     adjust `Brain.modelConfig` and its test, then run this again;
   - `~/.hermes/SOUL.md` starts with the marker;
   - LaunchAgents `com.kobe-assistant.gateway` and `com.kobe-assistant.agent` are loaded.
3. **Run 2 — "Set up again" with Hermes running.** Engine is green at once; Brain shows "Hermes already has a
   brain: Claude — Keep it"; Connecting line 3 asks the two-button choice; "Paste the existing key" finishes
   without a restart.
4. **Run 3 — stop the gateway** (`launchctl bootout`), reopen: "installed, asleep" → Turn it on → green.
5. Delete the `kobe-test` user. Nothing of it remains.

Any failure becomes a bug task with a failing test first.

| Run | Date | Outcome |
|---|---|---|
| 1 — nothing installed | | |
| 2 — set up again, Hermes running | | |
| 3 — gateway stopped | | |
| 5 — user deleted, nothing left | | |

## 3. Maintainer's own Mac (one-time migration)

After installing the new build:

- [ ] Move the old app away first: `scripts/install.sh` refuses to replace a `/Applications/Kobe.app` whose bundle
      id isn't `com.kobe-assistant.app`, and the old build still carries the old one. Quit it, move it out of
      `/Applications` yourself, then install.

- [ ] Move `~/Library/Application Support/Kobe Notch` to `~/Library/Application Support/Kobe` once (keeps the
      WhatsApp gateway session and the Kokoro voice model).
- [ ] Re-enter the engine key under Settings › Engine › Advanced (the Keychain item was renamed).
- [ ] Turn on "Hermes runs as another user". The exchange folder switches to `/Users/Shared/hermes-exchange`
      (the old default) by itself while it is still the default; check it under Settings › Engine › Advanced.
- [ ] Re-install the Claude Code hook from Settings (its path changed with the data folder).

## 4. Publish

- [ ] Ask the owner for the go-ahead (external and irreversible), then run the command the export script printed:
      `gh repo create guccimono/Kobe-AI-Assistant --public --source <export> --push`
- [ ] Enable the CI badge: confirm the workflow ran green on the first push, then check the badge in `README.md`
      resolves.
- [ ] Tag the release: `git tag v1.0 && git push origin v1.0` (from the export).
