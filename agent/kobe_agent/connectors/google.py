"""Google Analytics (GA4 visitors) and Search Console (clicks, position, top queries, daily clicks), last 7 days
against the 7 before. Business Profile joins when Google grants its API (plan 2c)."""

from __future__ import annotations

from datetime import datetime, timedelta
from urllib.parse import quote

from .. import config as agent_config
from .. import http
from ..envelope import envelope
from ..google_auth import Reconnect, access_token
from ..timefmt import now as utcnow
from .common import result

DAYS = 7
GA4 = "https://analyticsdata.googleapis.com/v1beta/properties/{}:runReport"
GSC = "https://searchconsole.googleapis.com/webmasters/v3/sites/{}/searchAnalytics/query"
RECONNECT = "Reconnect Google: run python3 -m kobe_agent google-auth"
DROP = 0.30


def _empty(prop: str | None, site: str | None) -> dict:
    prop, site = prop or "", site or ""
    return {"period_days": DAYS, "visitors": 0, "visitors_prev": 0, "clicks": 0, "clicks_prev": 0, "position": 0.0,
            "position_prev": 0.0, "calls": None, "calls_prev": None, "top_queries": [], "daily_clicks": [0] * DAYS,
            "business_profile": "waiting_access",
            "report_urls": {"analytics": f"https://analytics.google.com/analytics/web/#/p{prop}/reports/intelligenthome",
                            "search": "https://search.google.com/search-console/performance/search-analytics"
                                      f"?resource_id={quote(site, safe='')}"}}


def _visitors(answer) -> tuple[int, int]:
    by = {r["dimensionValues"][0]["value"]: int(r["metricValues"][0]["value"]) for r in (answer or {}).get("rows") or []
          if r.get("dimensionValues") and r.get("metricValues")}
    return by.get("current", 0), by.get("previous", 0)


def _drop(now: int, before: int) -> int:
    """Percent fallen, 0 when it rose or there was nothing before."""
    return round((before - now) * 100 / before) if before and now < before else 0


def run(secret: dict | None, *, fetch=http.request_json, now: datetime | None = None,
        config: dict | None = None) -> dict:
    """The sign-in is in secrets/google; the GA4 property and Search Console site are in config.json
    (google_property, google_site). Without all three the connector says not_set_up."""
    now = now or utcnow()
    if config is None:
        prop, site = agent_config.google_property(), agent_config.google_site()
    else:
        prop, site = config.get("google_property"), config.get("google_site")
    prop = str(prop) if prop else None
    data = _empty(prop, site)
    if not secret or not prop or not site:
        return envelope("google", "not_set_up", "Not set up", "Connect Google: python3 -m kobe_agent google-auth",
                        data, now=now)
    today = now.astimezone().date()
    cur = (today - timedelta(days=DAYS), today - timedelta(days=1))
    prev = (today - timedelta(days=2 * DAYS), today - timedelta(days=DAYS + 1))
    site = GSC.format(quote(site, safe=""))

    def gsc(span, **extra):
        return fetch(site, headers=auth, method="POST",
                     body={"startDate": span[0].isoformat(), "endDate": span[1].isoformat(), **extra})

    try:
        auth = {"Authorization": f"Bearer {access_token(secret, fetch=fetch)}"}
        ga4 = fetch(GA4.format(prop), headers=auth, method="POST", body={
            "dateRanges": [{"startDate": f"{DAYS}daysAgo", "endDate": "yesterday", "name": "current"},
                           {"startDate": f"{2 * DAYS}daysAgo", "endDate": f"{DAYS + 1}daysAgo", "name": "previous"}],
            "metrics": [{"name": "activeUsers"}]})
        totals, totals_prev = gsc(cur), gsc(prev)
        top = gsc(cur, dimensions=["query"], rowLimit=4)
        daily = gsc(cur, dimensions=["date"])
    except Reconnect:
        return result("google", error=RECONNECT, needs_you=False, ok_headline="", needs_headline="", detail="",
                      data=data, now=now)
    except http.HttpError as e:
        error = "Google refused: check the property and site, or reconnect with python3 -m kobe_agent google-auth" \
            if isinstance(e, http.BadKey) else str(e)
        return result("google", error=error, needs_you=False, ok_headline="", needs_headline="", detail="",
                      data=data, now=now)

    def total(answer, key, cast):
        rows = (answer or {}).get("rows") or []
        return cast(rows[0].get(key) or 0) if rows else cast(0)

    visitors, visitors_prev = _visitors(ga4)
    per_day = {r["keys"][0]: int(r.get("clicks") or 0) for r in (daily or {}).get("rows") or [] if r.get("keys")}
    data.update({
        "visitors": visitors, "visitors_prev": visitors_prev,
        "clicks": total(totals, "clicks", int), "clicks_prev": total(totals_prev, "clicks", int),
        "position": round(total(totals, "position", float), 1),
        "position_prev": round(total(totals_prev, "position", float), 1),
        "top_queries": [{"query": r["keys"][0], "clicks": int(r.get("clicks") or 0)}
                        for r in (top or {}).get("rows") or [] if r.get("keys")][:4],
        "daily_clicks": [per_day.get((cur[0] + timedelta(days=i)).isoformat(), 0) for i in range(DAYS)],
    })
    drops = [("Visitors", _drop(visitors, visitors_prev)), ("Clicks", _drop(data["clicks"], data["clicks_prev"]))]
    word, worst = max(drops, key=lambda d: d[1])
    return result("google", error=None, needs_you=worst > DROP * 100, ok_headline="All good",
                  needs_headline=f"{word} down {worst} %",
                  detail=f"{visitors:,} visitors · {data['clicks']:,} clicks", data=data, now=now)
