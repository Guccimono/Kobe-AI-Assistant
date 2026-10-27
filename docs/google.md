# Connect Google (Analytics and Search Console)

Kobe's Google page shows Google Analytics 4 and Search Console for one property and one site. It is read-only:
Kobe Agent asks for the `analytics.readonly` and `webmasters.readonly` scopes and nothing else. You create your own
Google Cloud client, so no one else's quota or app review is involved. Needs Kobe Agent installed (the onboarding
does it) and about ten minutes.

## 1. Create the Google Cloud client

1. In the [Google Cloud console](https://console.cloud.google.com/), create a project (any name).
2. APIs & Services › Library: enable **Google Analytics Data API** and **Google Search Console API**.
3. APIs & Services › OAuth consent screen: choose External, add yourself as a test user, save. Leaving the app in
   "Testing" is fine for personal use; Google may ask you to sign in again every seven days in that mode.
4. APIs & Services › Credentials › Create credentials › OAuth client ID › application type **Desktop app**.
5. Download the client JSON and keep it somewhere private (it holds a client secret), for example
   `~/Documents/Personal/google-client.json`.

## 2. Find your two ids

- GA4 property id: Analytics › Admin › Property settings, the number at the top (digits only).
- Search Console site: `sc-domain:example.com` for a domain property, or the full URL with a trailing slash
  (`https://www.example.com/`) for a URL-prefix property.

## 3. Sign in, once, in Terminal

```bash
cd ~/.hermes/kobe
python3 -m kobe_agent google-auth \
  --client-file ~/Documents/Personal/google-client.json \
  --property 123456789 \
  --site sc-domain:example.com
```

The command prints a link. Open it in your browser, sign in with the Google account that can see that property and
site, and allow the two read-only scopes. Google redirects to a temporary address on your own Mac
(`127.0.0.1`), the command stores the sign-in and prints "Google connected." It waits five minutes at most.

`--property` and `--site` go together; they are saved to `~/.hermes/kobe/config.json`. To change them later, edit that
file (`google_property`, `google_site`) or run the command again. The sign-in is saved in
`~/.hermes/kobe/secrets/google` (mode 0600).

## 4. Check

```bash
python3 -m kobe_agent once google
python3 -m kobe_agent status
```

Then open the Google page in the notch (⌘6) and press ⌘R. If it says "not set up", one of the two ids is missing
from `config.json`. If the sign-in is rejected, check that your account is a test user on the consent screen and that
both APIs are enabled.

To disconnect, delete `~/.hermes/kobe/secrets/google` and revoke access in your Google account's security settings.
In the two-users layout, run the same command as the engine's user (see `advanced-two-users.md`).
