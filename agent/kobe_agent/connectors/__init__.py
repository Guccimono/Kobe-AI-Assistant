"""Every connector: `run(secret, *, fetch, now) -> envelope`. The secret file has the connector's name."""

from . import github, google, stripe, vercel

REGISTRY = {"stripe": stripe.run, "github": github.run, "vercel": vercel.run, "google": google.run}
