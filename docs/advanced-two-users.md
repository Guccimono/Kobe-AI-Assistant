# Advanced: Kobe Agent as a second macOS user

The normal setup runs everything as you. This older layout keeps the engine under its own macOS user (`hermes`) and
shares one folder with your account. Use it only if you want that separation.

## Layout

- Your account runs the Kobe app. A second user `hermes` runs the engine and Kobe Agent.
- The exchange folder is shared (for example `/Users/Shared/hermes-exchange`, mode 2770, group `staff`).
- `~hermes/.hermes/kobe/` holds the code, `secrets/` (0700) and `logs/`.

## Config

In the second user's `~/.hermes/kobe/config.json` set `"shared": true` and `exchange_folder` to the shared folder.
With `shared`, folders are created 2770 and snapshot files 0660; otherwise 0755 and 0644.

## Stage (as you)

Copy what the other user installs into a folder only you can write, so it cannot be swapped:

```bash
DIST=/Users/Shared/hermes-exchange/kobe-agent-dist
[[ -e "$DIST" ]] || mkdir -m 755 "$DIST"
[[ -O "$DIST" && ! -L "$DIST" ]] || { echo "$DIST is not yours"; exit 1; }
rsync -a --delete --exclude __pycache__ agent/kobe_agent/ "$DIST/kobe_agent/"
rsync -a --delete agent/skills/ "$DIST/skills/"
chmod -R a+rX "$DIST"
```

## Install (as the second user)

```bash
sudo -iu hermes zsh -c '
  A=$HOME/.hermes/kobe
  mkdir -p "$A/logs" "$A/secrets" && chmod 700 "$A/secrets"
  rsync -a --delete --exclude __pycache__ /Users/Shared/hermes-exchange/kobe-agent-dist/kobe_agent/ "$A/kobe_agent/"
  mkdir -p "$HOME/.hermes/skills/kobe-mac-snapshots"
  rsync -a --delete /Users/Shared/hermes-exchange/kobe-agent-dist/skills/kobe-mac-snapshots/ "$HOME/.hermes/skills/kobe-mac-snapshots/"
'
```

Keys, each typed at a prompt: `sudo -iu hermes sh -c 'cd ~/.hermes/kobe && python3 -m kobe_agent set-key stripe'`
(likewise `github`, `vercel`). Google: pipe the client file in from your own folder with
`python3 -m kobe_agent google-auth --client-file - --property ID --site SITE`, as the second user.

## Daemon

A LaunchDaemon (system-wide, runs as `hermes`) instead of a LaunchAgent. Start from
`agent/launchd/com.kobe-assistant.agent.plist`, add `UserName` = `hermes`, absolute paths under `~hermes`, and
`ThrottleInterval` 30. Install it from your own checkout, never from the shared staging folder (the other user can
write there, and a swapped plist would run as root):

```bash
sudo install -o root -g wheel -m 644 com.kobe-assistant.agent.plist /Library/LaunchDaemons/
sudo launchctl bootstrap system /Library/LaunchDaemons/com.kobe-assistant.agent.plist
sudo -iu hermes sh -c 'cd ~/.hermes/kobe && python3 -m kobe_agent status'
```
