from __future__ import annotations

import unittest

from kobe_agent import http
from kobe_agent.connectors import github
from tests import contract_check
from tests.support import FakeFetch, at, contract, fixture

NOW = at(1792765690)


def fetch():
    return FakeFetch({"/graphql#pulse": fixture("github_pulse"), "/graphql#activity": fixture("github_activity"),
                      "/user/repos": fixture("github_user_repos"), "/user": fixture("github_user")})


class GitHubTests(unittest.TestCase):
    def test_github_matches_contract(self):
        s = github.run({"token": "t"}, fetch=fetch(), now=NOW)
        self.assertEqual(contract_check.same_shape(s, contract("github")), [])

    def test_github_headline_and_status(self):
        s = github.run({"token": "t"}, fetch=fetch(), now=NOW)
        self.assertEqual((s["status"], s["headline"], s["detail"]), ("needs_you", "2 need you", "3 open PRs"))
        d = s["data"]
        self.assertEqual([i["id"] for i in d["needs_you"]], ["x/y#9", "main-octo-org/kobe-notch"])
        self.assertEqual([i["state"] for i in d["my_prs"]], ["failing", "running", "unknown"])
        self.assertEqual([i["repo"] for i in d["mains"]], ["octo-org/acme", "octo-org/kobe-notch", "octo-org/site"])
        self.assertEqual(d["mains"][1]["branch"], "trunk")
        self.assertIsNone(d["mains"][0]["number"])
        days = [day["contributionCount"] for w in fixture("github_activity")["data"]["viewer"]["contributionsCollection"]
                ["contributionCalendar"]["weeks"] for day in w["contributionDays"] if "contributionCount" in day]
        self.assertEqual(d["activity"], days[-7:])
        self.assertEqual((d["total"], d["stars"]), (1234, 1234))

    def test_github_all_green(self):
        pulse = {"data": {"viewer": {"login": "g", "pullRequests": {"nodes": []}, "repositories": {"nodes": []}},
                          "reviewRequested": {"nodes": []}}}
        f = FakeFetch({"/graphql#pulse": pulse, "/graphql#activity": fixture("github_activity"),
                       "/user/repos": [], "/user": {}})
        s = github.run({"token": "t"}, fetch=f, now=NOW)
        self.assertEqual((s["status"], s["headline"], s["detail"]), ("ok", "All green", "No open PRs"))

    def test_github_query_matches_the_app(self):
        f = fetch()
        github.run({"token": "t"}, fetch=f, now=NOW)
        bodies = [c["body"]["query"] for c in f.calls if c["method"] == "POST"]
        self.assertTrue(any("reviewRequested: search" in q for q in bodies))
        self.assertTrue(all(c["headers"]["Authorization"] == "Bearer t" for c in f.calls))

    def test_github_no_secret_is_not_set_up(self):
        self.assertEqual(github.run(None, fetch=fetch(), now=NOW)["status"], "not_set_up")

    def test_github_bad_key_is_failed_without_secret_in_error(self):
        s = github.run({"token": "ghp_SECRET"}, fetch=FakeFetch({}, error=http.BadKey(401)), now=NOW)
        self.assertEqual(s["status"], "failed")
        self.assertNotIn("ghp_SECRET", str(s))

    def test_github_graphql_error_without_data(self):
        f = FakeFetch({"/graphql#pulse": {"errors": [{"message": "Bad credentials"}]}})
        s = github.run({"token": "t"}, fetch=f, now=NOW)
        self.assertEqual((s["status"], s["error"]), ("failed", "Bad credentials"))
