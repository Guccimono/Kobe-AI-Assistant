"""kobe-agent: run | once <id> | set-key <id> | google-auth --client-file F [--property P --site S] | status"""

import argparse
import getpass
import json
import sys
from datetime import datetime, timezone

from . import daemon, folder, google_auth, secrets
from .connectors import REGISTRY

KEY_FIELD = secrets.KEY_FIELD


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="kobe-agent")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("run", help="the daemon (launchd runs this)")
    once = sub.add_parser("once", help="run one connector now and write its snapshot")
    once.add_argument("id", choices=sorted(REGISTRY))
    key = sub.add_parser("set-key", help="store a Stripe, GitHub or Vercel key (typed, never echoed)")
    key.add_argument("id", choices=sorted(KEY_FIELD))
    auth = sub.add_parser("google-auth", help="connect Google Analytics and Search Console, read-only")
    auth.add_argument("--client-file", required=True)
    auth.add_argument("--property", help="GA4 property id (saved to config.json)")
    auth.add_argument("--site", help="Search Console site (saved to config.json)")
    sub.add_parser("status", help="each connector: key present, last snapshot")
    args = parser.parse_args(argv)

    if args.command == "run":
        daemon.run()
    elif args.command == "once":
        agent = daemon.Agent()
        if not agent.owns(args.id):
            print(f"No key for {args.id}: nothing written (the app keeps running it).")
            return 1
        agent.run_connector(args.id)
        print(json.loads((folder.widgets() / f"{args.id}.json").read_text())["status"])
    elif args.command == "set-key":
        value = getpass.getpass(f"{args.id} key: ").strip()
        if not value:
            print("Nothing stored.")
            return 1
        if args.id == "stripe" and not value.startswith("rk_"):
            print("Use a restricted key (rk_…) with read access to Balance, Charges and Payouts.")
            return 1
        secrets.save(args.id, {KEY_FIELD[args.id]: value})
        print(f"{args.id} key stored.")
    elif args.command == "google-auth":
        if bool(args.property) != bool(args.site):
            print("Give --property and --site together, or neither (then set them in config.json).")
            return 1
        google_auth.authorize(args.client_file, args.property, args.site)
    elif args.command == "status":
        now = datetime.now(timezone.utc)
        for id in sorted(REGISTRY):
            try:
                has = "key" if secrets.load(id) else "no key"
            except secrets.InsecureFile:
                has = "key file not 0600"
            except (ValueError, OSError):
                has = "key file unreadable"
            try:
                snap = json.loads((folder.widgets() / f"{id}.json").read_text())
                when = datetime.strptime(snap["updated_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
                last = f"{snap['status']} by {snap.get('source', 'app')}, {int((now - when).total_seconds() // 60)} min ago"
            except (OSError, ValueError, KeyError):
                last = "no snapshot"
            print(f"{id:8} {has:18} {last}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
