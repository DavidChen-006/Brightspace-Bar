#!/usr/bin/env python3
"""Probe D2L's global calendar route. GET-only except the token mint.

Never prints the cookie, CSRF token, or JWT — length only. Writes the full result
matrix to artifacts/findings.json.
"""

import json
import pathlib
import sys
import urllib.error
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
SESSION = pathlib.Path.home() / "Library/Application Support/BrightspaceBar/session.json"
TIMEOUT = 30

# The two courses experiment 6 proved still have API access.
LIVE = [412690, 440703]
# Real semester courses — all 403 on org-unit-scoped routes (experiment 6).
ENDED_FALL_2025 = [1360020, 1360027, 1360055, 1361997, 1372751, 1413404]
ENDED_SPRING_2026 = [1488325, 1495427, 1487623, 1488428, 1498777]


def mint(base: str, cookie: str, csrf: str | None) -> str:
    req = urllib.request.Request(
        base + "/d2l/lp/auth/oauth2/token",
        data=b"scope=*:*:*",
        method="POST",
        headers={
            "content-type": "application/x-www-form-urlencoded",
            "cookie": cookie,
            "x-csrf-token": csrf or "",
        },
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        body = r.read()
    if b"sessionExpired=1" in body:
        sys.exit("SESSION DEAD — re-run Scripts/refresh-session.sh --capture")
    token = json.loads(body)["access_token"]
    print(f"JWT minted (length {len(token)})")
    return token


def get(url: str, jwt: str) -> tuple[int, object]:
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {jwt}"})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        # Error bodies are RFC 7807 problem+json when D2L is being honest, and
        # HTML when it is not; either way the status is the signal we need.
        detail = ""
        try:
            detail = json.loads(e.read()).get("detail", "")
        except (ValueError, AttributeError) as parse_error:
            detail = f"unparseable error body ({type(parse_error).__name__})"
        return e.code, {"error": detail}


def calendar(base: str, jwt: str, le: str, ous: list[int], start: str, end: str):
    """One calendar query. Returns (status, event list or error, raw wrapper keys)."""
    q = urllib.parse.urlencode(
        {
            "startDateTime": start,
            "endDateTime": end,
            "orgUnitIdsCSV": ",".join(str(o) for o in ous),
        }
    )
    status, body = get(f"{base}/d2l/api/le/{le}/calendar/events/myEvents/?{q}", jwt)
    if status != 200 or not isinstance(body, dict):
        return status, body, []
    # The MCP notes the wrapper is "Objects", not "Items" — verify rather than trust.
    return status, body.get("Objects", body.get("Items", [])), sorted(body.keys())


def main() -> None:
    sess = json.loads(SESSION.read_text())
    base = sess["baseUrl"]
    jwt = mint(base, sess["cookieHeader"], sess.get("csrfToken"))

    findings: dict = {"experiment": "8 — calendar route", "probes": {}}

    # Probe 1: version discovery — do not assume 1.96.
    status, versions = get(f"{base}/d2l/api/versions/", jwt)
    le_version = "1.96"
    if status == 200 and isinstance(versions, list):
        for product in versions:
            if product.get("ProductCode") == "le":
                le_version = product.get("LatestVersion", le_version)
    print(f"versions: HTTP {status}, using LE {le_version}")
    findings["probes"]["versionDiscovery"] = {"status": status, "leVersion": le_version}

    windows = {
        "forward_90d": ("2026-08-09T00:00:00.000Z", "2026-11-07T00:00:00.000Z"),
        "fall_2025": ("2025-08-01T00:00:00.000Z", "2025-12-31T00:00:00.000Z"),
        "spring_2026": ("2026-01-01T00:00:00.000Z", "2026-05-31T00:00:00.000Z"),
    }
    cohorts = {
        "live_only": LIVE,
        "ended_fall_2025": ENDED_FALL_2025,
        "ended_spring_2026": ENDED_SPRING_2026,
        "all_mixed": LIVE + ENDED_FALL_2025 + ENDED_SPRING_2026,
    }

    results = []
    sample_event = None
    for cohort, ous in cohorts.items():
        for window, (start, end) in windows.items():
            status, events, keys = calendar(base, jwt, le_version, ous, start, end)
            count = len(events) if isinstance(events, list) else 0
            titles = []
            if isinstance(events, list):
                for ev in events[:4]:
                    titles.append(
                        f"{ev.get('Title', '?')} [{ev.get('OrgUnitName', '?')}] due {ev.get('EndDateTime', '?')}"
                    )
                if events and sample_event is None:
                    sample_event = events[0]
            row = {
                "cohort": cohort,
                "orgUnitCount": len(ous),
                "window": window,
                "status": status,
                "eventCount": count,
                "wrapperKeys": keys,
                "sampleTitles": titles,
            }
            if status != 200:
                row["error"] = events
            results.append(row)
            print(f"  {cohort:<18} {window:<13} HTTP {status}  events={count}")

    findings["probes"]["calendarQueries"] = results
    if sample_event:
        findings["probes"]["eventFields"] = sorted(sample_event.keys())
        findings["probes"]["deepLinkable"] = any(
            k.lower() in {"url", "href", "link", "activityid", "dropboxid"}
            for k in sample_event
        )
        print(f"\nevent fields: {sorted(sample_event.keys())}")
    else:
        findings["probes"]["eventFields"] = None
        print("\nNo events returned by any query — nothing to dump.")

    out = ROOT / "artifacts" / "findings.json"
    out.write_text(json.dumps(findings, indent=2))
    print(f"\nwrote {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
