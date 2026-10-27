# Kobe Agent

The connectors behind the Kobe app's Stripe, GitHub, Vercel and Google pages. A small Python 3 program (standard
library only) that runs as you, fetches each service on a schedule and writes the snapshot files the app draws into
the exchange folder (`widgets/<id>.json`). The app asks for a refresh by dropping a file in `requests/`; the answer
goes to `results/`.

Snapshot contract: snake_case keys, ISO 8601 UTC dates without fractions, money in minor units, `version: 1`,
`source: "agent"`, written atomically. Never a secret.

## How the app installs it

Kobe's onboarding copies `kobe_agent/` to `~/.hermes/kobe/` and the skill `skills/kobe-mac-snapshots/` to
`~/.hermes/skills/`, writes `config.json` and the keys, and starts a LaunchAgent (`com.kobe-assistant.agent`,
`launchd/com.kobe-assistant.agent.plist` is its template). This folder ships inside the app at
`Kobe.app/Contents/Resources/agent/`.

## Run it by hand

```bash
cd ~/.hermes/kobe
python3 -m kobe_agent status          # each connector: key present, last snapshot
python3 -m kobe_agent once stripe     # run one connector now
python3 -m kobe_agent run             # the loop (launchd runs this)
python3 -m kobe_agent set-key stripe  # type a key at a prompt (also github, vercel)
```

Tests: `agent/scripts/test.sh`.

## `~/.hermes/kobe/config.json`

| Key | Meaning |
|---|---|
| `exchange_folder` | Where `widgets/`, `requests/` and `results/` live. Default `~/Library/Application Support/Kobe/exchange`. |
| `version` | Config format, `1`. |
| `google_property` | GA4 property id for the Google page. |
| `google_site` | Search Console site, e.g. `sc-domain:example.com`. |
| `shared` | `true` only for the two-users setup (group-writable folder and files, see `docs/advanced-two-users.md`). |

Missing or unreadable file means defaults. `KOBE_EXCHANGE_ROOT` overrides `exchange_folder`.

## `~/.hermes/kobe/secrets/`

One file per service, mode 0600, the folder 0700: `stripe`, `github`, `vercel` hold the bare key (the app writes
them from its Keychain; whitespace is stripped). `google` holds the sign-in as JSON, written by `google-auth`.
A connector without a key is not run by the agent, and the app keeps running it itself.

## Google

Setup is in `docs/google.md`. `python3 -m kobe_agent google-auth --client-file FILE --property ID --site SITE`
signs in (read-only scopes) and saves the property and site to `config.json`. Without both, the Google page
says "not set up".
