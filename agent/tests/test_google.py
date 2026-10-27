from __future__ import annotations

import base64
import hashlib
import unittest
from urllib.parse import parse_qs, urlparse

from kobe_agent import google_auth, http
from kobe_agent.connectors import google
from tests import contract_check
from tests.support import FakeFetch, at, contract, fixture, utc

NOW = at(1792765690)  # 2026-10-23 14:28:10 UTC
SECRET = {"client_id": "cid.apps.googleusercontent.com", "client_secret": "CLIENT_SECRET",
          "refresh_token": "REFRESH_SECRET"}
CONFIG = {"google_property": "123456789", "google_site": "sc-domain:example.com"}


def gsc(body):
    if body.get("dimensions") == ["query"]:
        return fixture("gsc_top_queries")
    if body.get("dimensions") == ["date"]:
        return fixture("gsc_daily")
    return fixture("gsc_query") if body["startDate"] == "2026-10-16" else fixture("gsc_query_prev")


def fetch(ga4=None, gsc_answer=gsc, token=None):
    return FakeFetch({"oauth2.googleapis.com/token": token or fixture("google_token"),
                      "analyticsdata.googleapis.com": ga4 or fixture("ga4_run_report"),
                      "searchconsole.googleapis.com": gsc_answer})


class GoogleTests(unittest.TestCase):
    def setUp(self):
        utc()

    def test_google_matches_contract(self):
        s = google.run(SECRET, fetch=fetch(), now=NOW, config=CONFIG)
        self.assertEqual(contract_check.same_shape(s, contract("google")), [])

    def test_google_values(self):
        s = google.run(SECRET, fetch=fetch(), now=NOW, config=CONFIG)
        d = s["data"]
        self.assertEqual((s["status"], s["headline"], s["detail"]), ("ok", "All good", "1,240 visitors · 312 clicks"))
        self.assertEqual((d["visitors"], d["visitors_prev"], d["clicks"], d["clicks_prev"]), (1240, 1100, 312, 280))
        self.assertEqual((d["position"], d["position_prev"]), (8.4, 9.1))
        self.assertEqual(d["top_queries"][0], {"query": "menu digital qr", "clicks": 41})
        self.assertEqual(len(d["top_queries"]), 4)
        self.assertEqual(d["daily_clicks"], [40, 52, 0, 47, 0, 0, 41])
        self.assertEqual((d["calls"], d["business_profile"]), (None, "waiting_access"))

    def test_google_requests(self):
        f = fetch()
        google.run(SECRET, fetch=f, now=NOW, config=CONFIG)
        urls = [c["url"] for c in f.calls]
        self.assertIn("https://analyticsdata.googleapis.com/v1beta/properties/123456789:runReport", urls)
        self.assertIn("https://searchconsole.googleapis.com/webmasters/v3/sites/sc-domain%3Aexample.com/searchAnalytics/query", urls)
        api = [c for c in f.calls if "oauth2" not in c["url"]]
        self.assertTrue(all(c["headers"]["Authorization"] == "Bearer ya29.ACCESS_SECRET" for c in api))
        self.assertEqual(f.calls[0]["form"]["grant_type"], "refresh_token")

    def test_google_week_on_week_drop_is_needs_you(self):
        ga4 = fixture("ga4_run_report")
        ga4["rows"][1]["metricValues"][0]["value"] = "700"  # 1100 → 700: −36 %
        s = google.run(SECRET, fetch=fetch(ga4=ga4), now=NOW, config=CONFIG)
        self.assertEqual((s["status"], s["headline"]), ("needs_you", "Visitors down 36 %"))

    def test_google_refresh_failure_is_failed_with_reconnect_hint(self):
        s = google.run(SECRET, fetch=fetch(token=http.Failed(400)), now=NOW, config=CONFIG)
        self.assertEqual(s["status"], "failed")
        self.assertEqual(s["error"], "Reconnect Google: run python3 -m kobe_agent google-auth")
        for secret in ("CLIENT_SECRET", "REFRESH_SECRET", "ACCESS_SECRET"):
            self.assertNotIn(secret, str(s))

    def test_google_api_error_keeps_no_token(self):
        s = google.run(SECRET, fetch=fetch(ga4=http.BadKey(403)), now=NOW, config=CONFIG)
        self.assertEqual(s["status"], "failed")
        self.assertNotIn("ACCESS_SECRET", str(s))

    def test_google_no_secret_is_not_set_up(self):
        s = google.run(None, fetch=fetch(), now=NOW, config=CONFIG)
        self.assertEqual((s["status"], s["detail"]), ("not_set_up", "Connect Google: python3 -m kobe_agent google-auth"))

    def test_pkce_challenge_is_s256(self):
        verifier, challenge = google_auth.pkce()
        self.assertTrue(43 <= len(verifier) <= 128)
        expected = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
        self.assertEqual(challenge, expected)

    def test_consent_url(self):
        url = google_auth.consent_url("cid", "http://127.0.0.1:5555/", "chal", "st")
        q = parse_qs(urlparse(url).query)
        self.assertEqual(q["code_challenge_method"], ["S256"])
        self.assertEqual(q["access_type"], ["offline"])
        self.assertEqual(set(q["scope"][0].split()), {"https://www.googleapis.com/auth/analytics.readonly",
                                                      "https://www.googleapis.com/auth/webmasters.readonly"})
        self.assertEqual(q["redirect_uri"], ["http://127.0.0.1:5555/"])

    def test_client_file_reads_installed_section(self):
        cid, csecret = google_auth.read_client({"installed": {"client_id": "a", "client_secret": "b"}})
        self.assertEqual((cid, csecret), ("a", "b"))
        with self.assertRaises(ValueError):
            google_auth.read_client({"web": {"client_id": "a", "client_secret": "b"}})
