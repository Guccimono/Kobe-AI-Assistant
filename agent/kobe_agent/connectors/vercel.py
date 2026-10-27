"""Vercel: the newest finished deployment of each project (port of VercelClient.swift and SnapshotBuilders.vercel)."""

from __future__ import annotations

from datetime import datetime

from .. import http
from ..timefmt import from_epoch, iso, now as utcnow
from .common import bad_key_message, not_set_up, plural, result

API = "https://api.vercel.com"
FINISHED = ("READY", "ERROR", "CANCELED")


def _deployments(answer) -> list[dict]:
    out = []
    for d in (answer or {}).get("deployments") or []:
        if not (isinstance(d.get("uid"), str) and isinstance(d.get("name"), str) and d.get("state") in FINISHED):
            continue
        meta = d.get("meta") or {}
        commit = meta.get("githubCommitMessage") or meta.get("gitlabCommitMessage") or meta.get("bitbucketCommitMessage")
        branch = meta.get("githubCommitRef") or meta.get("gitlabCommitRef") or meta.get("bitbucketBranch")
        out.append({"name": d["name"], "state": d["state"], "url": d.get("url") or "", "branch": branch,
                    "commit": commit.split("\n")[0] if commit else None,
                    "at": from_epoch(d.get("createdAt") or d.get("created") or 0)})
    return out


def run(secret: dict | None, *, fetch=http.get_json, now: datetime | None = None) -> dict:
    now = now or utcnow()
    if not secret:
        return not_set_up("vercel", {"projects": []}, now)
    try:
        answer = fetch(f"{API}/v6/deployments?limit=20", headers={"Authorization": f"Bearer {secret.get('token', '')}"})
    except http.HttpError as e:
        error = bad_key_message("vercel") if isinstance(e, http.BadKey) else str(e)
        return result("vercel", error=error, needs_you=False, ok_headline="", needs_headline="", detail="",
                      data={"projects": []}, now=now)
    newest: dict[str, dict] = {}
    for d in _deployments(answer):
        if d["name"] not in newest or newest[d["name"]]["at"] < d["at"]:
            newest[d["name"]] = d
    rows = sorted(newest.values(), key=lambda d: (d["state"] != "ERROR", -d["at"].timestamp()))
    projects = [{"name": d["name"], "state": d["state"].lower(), "branch": d["branch"], "commit": d["commit"],
                 "at": iso(d["at"]), "url": f"https://{d['url']}" if d["url"] else None,
                 "is_production": d["branch"] in ("main", "master")} for d in rows]
    failed = sum(1 for d in rows if d["state"] == "ERROR")
    return result("vercel", error=None, needs_you=failed > 0, ok_headline="All live", needs_headline=f"{failed} failed",
                  detail=plural(len(projects), "project") if projects else "No deployments",
                  data={"projects": projects}, now=now)
