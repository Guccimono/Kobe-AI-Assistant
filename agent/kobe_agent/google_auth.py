"""Google sign-in for an installed app: PKCE, a loopback redirect on 127.0.0.1, read-only scopes. Run once by hand
(`python3 -m kobe_agent google-auth`); the refresh token goes to secrets/google (0600) and is never printed."""

from __future__ import annotations

import base64
import hashlib
import http.server
import json
import secrets as pysecrets
import sys
import threading
import urllib.parse
from pathlib import Path

from . import http as khttp
from . import config, secrets

AUTH = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN = "https://oauth2.googleapis.com/token"
SCOPES = ("https://www.googleapis.com/auth/analytics.readonly", "https://www.googleapis.com/auth/webmasters.readonly")


class Reconnect(Exception):
    """The refresh token was refused (revoked, expired, client deleted): sign in again."""


def pkce() -> tuple[str, str]:
    verifier = pysecrets.token_urlsafe(64)[:96]
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    return verifier, challenge


def consent_url(client_id: str, redirect: str, challenge: str, state: str) -> str:
    return AUTH + "?" + urllib.parse.urlencode({
        "client_id": client_id, "redirect_uri": redirect, "response_type": "code", "scope": " ".join(SCOPES),
        "code_challenge": challenge, "code_challenge_method": "S256", "state": state,
        "access_type": "offline", "prompt": "consent"})


def read_client(obj: dict) -> tuple[str, str]:
    """The "Desktop app" client JSON Google lets you download: {"installed": {"client_id", "client_secret", …}}."""
    installed = obj.get("installed")
    if not isinstance(installed, dict) or not installed.get("client_id") or not installed.get("client_secret"):
        raise ValueError("Not a Desktop app client file (no \"installed\" section)")
    return installed["client_id"], installed["client_secret"]


def load_client(arg: str, *, stdin=None) -> dict:
    """The client file, or "-" for standard input: the downloaded file stays in your own folder and is
    piped in, never copied where another user could read it."""
    if arg == "-":
        return json.loads((stdin or sys.stdin).read())
    return json.loads(Path(arg).read_text())


def access_token(secret: dict, *, fetch=khttp.request_json) -> str:
    """A fresh access token from the refresh token. Offline stays Offline; any refusal means sign in again."""
    try:
        answer = fetch(TOKEN, method="POST", form={
            "client_id": secret["client_id"], "client_secret": secret["client_secret"],
            "refresh_token": secret["refresh_token"], "grant_type": "refresh_token"})
    except khttp.Offline:
        raise
    except khttp.HttpError:
        raise Reconnect() from None
    token = (answer or {}).get("access_token")
    if not token:
        raise Reconnect()
    return token


def authorize(client_file: str, property_id: str | None, site_url: str | None, *, timeout: float = 300) -> None:
    """Prints a consent link to open in the browser, waits for Google's redirect, stores secrets/google and the property and site in config.json."""
    client_id, client_secret = read_client(load_client(client_file))
    verifier, challenge = pkce()
    state = pysecrets.token_urlsafe(16)
    got: dict = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            if query.get("state") == [state] and "code" in query:
                got["code"] = query["code"][0]
                text = "Kobe Agent is connected to Google. You can close this tab."
            else:
                got.setdefault("error", (query.get("error") or ["no code"])[0])
                text = "Google sign-in did not finish. Run python3 -m kobe_agent google-auth again."
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(text.encode())

        def log_message(self, *args):  # the request line holds the code: never log it
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    redirect = f"http://127.0.0.1:{server.server_port}/"
    print("Open this link in your browser and sign in with the Google account that sees Analytics and Search Console:")
    print(consent_url(client_id, redirect, challenge, state))
    timer = threading.Timer(timeout, lambda: got.setdefault("error", "timed out"))
    timer.start()
    try:
        while "code" not in got and "error" not in got:
            server.timeout = 1
            server.handle_request()
    finally:
        timer.cancel()
        server.server_close()
    if "code" not in got:
        raise SystemExit(f"Google sign-in failed: {got['error']}")
    answer = khttp.request_json(TOKEN, method="POST", form={
        "code": got["code"], "client_id": client_id, "client_secret": client_secret, "redirect_uri": redirect,
        "grant_type": "authorization_code", "code_verifier": verifier})
    if not answer.get("refresh_token"):
        raise SystemExit("Google sent no refresh token. Remove Kobe at myaccount.google.com/permissions and retry.")
    secrets.save("google", {"client_id": client_id, "client_secret": client_secret,
                            "refresh_token": answer["refresh_token"]})
    if property_id and site_url:
        config.update(google_property=str(property_id), google_site=site_url)
    print("Google connected.")
