"""GitHub (port of GitHubClient.swift, GitHubPulse.swift, GitHubActivity.swift and
SnapshotBuilders.github): one GraphQL query for the pulse, one for the contribution calendar, REST for the stars."""

from __future__ import annotations

from datetime import datetime

from .. import http
from ..timefmt import now as utcnow
from .common import bad_key_message, not_set_up, plural, result

API = "https://api.github.com"

PULSE_QUERY = """
query {
  viewer {
    login
    pullRequests(states: OPEN, first: 20, orderBy: {field: UPDATED_AT, direction: DESC}) {
      nodes {
        number title url isDraft reviewDecision
        repository { nameWithOwner url }
        commits(last: 1) {
          nodes { commit { oid statusCheckRollup { state } } }
        }
      }
    }
    repositories(first: 10, ownerAffiliations: [OWNER], orderBy: {field: PUSHED_AT, direction: DESC}) {
      nodes {
        nameWithOwner url isArchived
        defaultBranchRef {
          name
          target { ... on Commit { oid statusCheckRollup { state } } }
        }
      }
    }
  }
  reviewRequested: search(query: "is:pr is:open review-requested:@me archived:false", type: ISSUE, first: 20) {
    issueCount
    nodes {
      ... on PullRequest {
        number title url isDraft
        author { login }
        repository { nameWithOwner url }
      }
    }
  }
}
"""

ACTIVITY_QUERY = """
query {
  viewer {
    login
    contributionsCollection {
      contributionCalendar {
        totalContributions
        weeks {
          contributionDays {
            date contributionCount contributionLevel weekday
          }
        }
      }
    }
  }
}
"""


def _empty() -> dict:
    return {"needs_you": [], "my_prs": [], "mains": [], "activity": [], "total": 0, "stars": 0}


def _state(raw) -> str:
    raw = (raw or "").upper()
    if raw in ("PENDING", "EXPECTED"):
        return "running"
    if raw == "SUCCESS":
        return "passing"
    if raw in ("ERROR", "FAILURE"):
        return "failing"
    return "unknown"


def _nodes(connection) -> list[dict]:
    return [n for n in ((connection or {}).get("nodes") or []) if isinstance(n, dict)]


def _pr(node: dict) -> dict | None:
    repo = (node.get("repository") or {}).get("nameWithOwner")
    if not (isinstance(node.get("number"), int) and isinstance(node.get("title"), str)
            and isinstance(node.get("url"), str) and isinstance(repo, str)):
        return None
    return {"id": f"{repo}#{node['number']}", "repo": repo, "number": node["number"], "title": node["title"],
            "state": "unknown", "branch": None, "author": None, "url": node["url"]}


def _graphql(fetch, headers, query) -> dict:
    root = fetch(f"{API}/graphql", headers=headers, method="POST", body={"query": query}, timeout=15)
    if not isinstance((root or {}).get("data"), dict):
        message = ((root or {}).get("errors") or [{}])[0].get("message")
        raise http.Failed(200, message or "Unexpected answer from GitHub.")
    return root["data"]


def _pulse(data: dict) -> tuple[list, list, list]:
    viewer = data.get("viewer") or {}
    my_prs, seen = [], set()
    for node in _nodes(viewer.get("pullRequests")):
        pr = _pr(node)
        if not pr or pr["id"] in seen:
            continue
        seen.add(pr["id"])
        commits = _nodes(node.get("commits"))
        rollup = ((commits[-1].get("commit") or {}).get("statusCheckRollup") or {}) if commits else {}
        pr["state"] = _state(rollup.get("state"))
        my_prs.append(pr)
    mains = []
    for node in _nodes(viewer.get("repositories")):
        ref = node.get("defaultBranchRef") or {}
        if node.get("isArchived") or not (node.get("nameWithOwner") and node.get("url") and ref.get("name")):
            continue
        rollup = (ref.get("target") or {}).get("statusCheckRollup") or {}
        mains.append({"id": f"main-{node['nameWithOwner']}", "repo": node["nameWithOwner"], "number": None,
                      "title": ref["name"], "state": _state(rollup.get("state")), "branch": ref["name"],
                      "author": None, "url": node["url"]})
    reviews, seen = [], set()
    for node in _nodes(data.get("reviewRequested")):
        pr = _pr(node)
        if pr and pr["id"] not in seen:
            seen.add(pr["id"])
            reviews.append(pr)
    return my_prs, mains, reviews


def _activity(data: dict) -> tuple[list[int], int]:
    calendar = (((data.get("viewer") or {}).get("contributionsCollection") or {}).get("contributionCalendar") or {})
    days = [d["contributionCount"] for w in calendar.get("weeks") or [] for d in w.get("contributionDays") or []
            if isinstance(d.get("contributionCount"), int)]
    return days[-7:], calendar.get("totalContributions") or 0


def run(secret: dict | None, *, fetch=http.get_json, now: datetime | None = None) -> dict:
    now = now or utcnow()
    if not secret:
        return not_set_up("github", _empty(), now)
    headers = {"Authorization": f"Bearer {secret.get('token', '')}", "Accept": "application/vnd.github+json"}
    try:
        my_prs, mains, reviews = _pulse(_graphql(fetch, headers, PULSE_QUERY))
        activity, total = _activity(_graphql(fetch, headers, ACTIVITY_QUERY))
        repos = fetch(f"{API}/user/repos?per_page=100&affiliation=owner&sort=pushed", headers=headers, timeout=15)
    except http.HttpError as e:
        error = bad_key_message("github") if isinstance(e, http.BadKey) else str(e)
        return result("github", error=error, needs_you=False, ok_headline="", needs_headline="", detail="",
                      data=_empty(), now=now)
    stars = sum(r.get("stargazers_count") or 0 for r in repos if isinstance(r, dict)) if isinstance(repos, list) else 0
    needs_you = reviews + [m for m in mains if m["state"] == "failing"]
    failing = sum(1 for p in my_prs if p["state"] == "failing")
    data = {"needs_you": needs_you, "my_prs": my_prs, "mains": mains, "activity": activity, "total": total,
            "stars": stars}
    return result("github", error=None, needs_you=bool(needs_you),
                  ok_headline=f"{failing} failing" if failing else "All green",
                  needs_headline=f"{len(needs_you)} need you",
                  detail=plural(len(my_prs), "open PR") if my_prs else "No open PRs", data=data, now=now)
