from __future__ import annotations

import unittest

from kobe_agent import http
from kobe_agent.connectors import vercel
from tests import contract_check
from tests.support import FakeFetch, at, contract, fixture

NOW = at(1792765690)


class VercelTests(unittest.TestCase):
    def test_vercel_matches_contract(self):
        s = vercel.run({"token": "t"}, fetch=FakeFetch({"/v6/deployments": fixture("vercel_deployments")}), now=NOW)
        self.assertEqual(contract_check.same_shape(s, contract("vercel")), [])

    def test_vercel_headline_and_status(self):
        s = vercel.run({"token": "t"}, fetch=FakeFetch({"/v6/deployments": fixture("vercel_deployments_mixed")}), now=NOW)
        self.assertEqual((s["status"], s["headline"], s["detail"]), ("needs_you", "1 failed", "3 projects"))

    def test_vercel_failures_first(self):
        s = vercel.run({"token": "t"}, fetch=FakeFetch({"/v6/deployments": fixture("vercel_deployments_mixed")}), now=NOW)
        rows = s["data"]["projects"]
        self.assertEqual([p["name"] for p in rows], ["bare", "menu-app", "docs"])
        self.assertEqual([p["state"] for p in rows], ["error", "canceled", "ready"])
        self.assertIsNone(rows[0]["url"])
        self.assertEqual((rows[1]["branch"], rows[1]["commit"], rows[1]["is_production"]),
                         ("header", "Try new header", False))

    def test_from_epoch_ms_in_vercel(self):
        s = vercel.run({"token": "t"}, fetch=FakeFetch({"/v6/deployments": fixture("vercel_deployments_mixed")}), now=NOW)
        rows = {p["name"]: p for p in s["data"]["projects"]}
        self.assertEqual(rows["menu-app"]["at"], "2026-10-21T16:26:40Z")
        self.assertEqual(rows["bare"]["at"], "1970-01-01T00:00:00Z")

    def test_vercel_no_secret_is_not_set_up(self):
        s = vercel.run(None, fetch=FakeFetch({}), now=NOW)
        self.assertEqual((s["status"], s["detail"]), ("not_set_up", "Add the key: kobe-agent set-key vercel"))

    def test_vercel_bad_key_is_failed_without_secret_in_error(self):
        s = vercel.run({"token": "tok_SECRET"}, fetch=FakeFetch({}, error=http.BadKey(403)), now=NOW)
        self.assertEqual(s["status"], "failed")
        self.assertEqual(s["error"], "The key was refused. Set it again: kobe-agent set-key vercel")
        self.assertNotIn("tok_SECRET", str(s))
