from __future__ import annotations

import unittest

from kobe_agent import http
from kobe_agent.connectors import stripe
from tests import contract_check
from tests.support import FakeFetch, at, contract, fixture, utc

NOW = at(1792600100)  # just after ch_1, same UTC day as all three charges


def fetch():
    return FakeFetch({"/v1/balance": fixture("stripe_balance"), "/v1/charges": fixture("stripe_charges"),
                      "/v1/payouts": fixture("stripe_payouts")})


class StripeTests(unittest.TestCase):
    def setUp(self):
        utc()

    def test_stripe_matches_contract(self):
        produced = stripe.run({"key": "rk_test_x"}, fetch=fetch(), now=NOW)
        self.assertEqual(contract_check.same_shape(produced, contract("stripe")), [])

    def test_stripe_headline_and_status(self):
        s = stripe.run({"key": "rk_test_x"}, fetch=fetch(), now=NOW)
        self.assertEqual(s["status"], "needs_you")
        self.assertEqual(s["headline"], "1 failed")
        self.assertEqual(s["detail"], "€98 today · 2 payments")
        d = s["data"]
        self.assertEqual((d["total"], d["count"], d["failed"], d["available"]), (9800, 2, 1, 128450))
        self.assertEqual(d["next_payout"], "2026-10-27T00:00:00Z")
        self.assertEqual([p["customer"] for p in d["payments"]], ["Sarah L.", "Pro plan", ""])
        self.assertEqual(d["payments"][0]["url"], "https://dashboard.stripe.com/payments/ch_1")
        self.assertEqual(d["payments"][0]["at"], "2026-10-21T16:26:40Z")

    def test_stripe_no_secret_is_not_set_up(self):
        s = stripe.run(None, fetch=fetch(), now=NOW)
        self.assertEqual((s["status"], s["headline"], s["detail"]),
                         ("not_set_up", "Not set up", "Add the key: kobe-agent set-key stripe"))

    def test_stripe_bad_key_is_failed_without_secret_in_error(self):
        s = stripe.run({"key": "rk_live_SECRET123"}, fetch=FakeFetch({}, error=http.BadKey(401)), now=NOW)
        self.assertEqual(s["status"], "failed")
        self.assertEqual(s["error"], "Invalid API key (401)")
        self.assertNotIn("SECRET123", str(s))

    def test_stripe_refuses_sk_keys(self):
        f = fetch()
        s = stripe.run({"key": "sk_live_abc"}, fetch=f, now=NOW)
        self.assertEqual(s["status"], "failed")
        self.assertIn("restricted key", s["error"])
        self.assertNotIn("sk_live_abc", str(s))
        self.assertEqual(f.calls, [])

    def test_stripe_sends_basic_auth(self):
        f = fetch()
        stripe.run({"key": "rk_test_x"}, fetch=f, now=NOW)
        self.assertTrue(all(c["headers"]["Authorization"] == "Basic cmtfdGVzdF94Og==" for c in f.calls))
        self.assertTrue(all(c["url"].startswith("https://api.stripe.com/") for c in f.calls))
