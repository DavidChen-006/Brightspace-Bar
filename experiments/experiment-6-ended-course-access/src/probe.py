#!/usr/bin/env python3
"""Experiment 6 probe: does the D2L API gate ended courses like the UI does?

GET-only except the token mint POST. Secrets (cookie, csrf, JWT) are never
printed or written — only the JWT length is logged. Writes the full result
matrix to artifacts/findings.json.
"""

import json
import os
import ssl
import urllib.error
import urllib.request
from datetime import datetime, timezone

SESSION_PATH = os.path.expanduser(
    "~/Library/Application Support/BrightspaceBar/session.json"
)
TIMEOUT = 30
ARTIFACTS = os.path.join(os.path.dirname(__file__), "..", "artifacts")

ORG_UNITS = [
    {"id": 1488325, "name": "Spring 2026 CS 25200", "bucket": "ended_recent"},
    {"id": 1495427, "name": "Spring 2026 CS 47100", "bucket": "ended_recent"},
    {"id": 1360027, "name": "Fall 2025 CS 25100", "bucket": "ended_older"},
    {"id": 1095299, "name": "Fall 2024 CS 17600", "bucket": "ended_older"},
    {"id": 412690, "name": "Civics Knowledge Test", "bucket": "live_control"},
    {"id": 440703, "name": "Scholarly Project Milestones", "bucket": "live_control"},
]

# (key, path template, LE/LP) — path filled with org unit id.
ROUTES = [
    ("course_info", "/d2l/api/lp/1.62/courses/{id}"),
    ("content_root", "/d2l/api/le/1.96/{id}/content/root/"),
    ("news", "/d2l/api/le/1.96/{id}/news/"),
    ("my_grades", "/d2l/api/le/1.96/{id}/grades/values/myGradeValues/"),
    ("dropbox_folders", "/d2l/api/le/1.96/{id}/dropbox/folders/"),
]

CTX = ssl.create_default_context()


def log(msg):
    print(f"[{datetime.now(timezone.utc).strftime('%H:%M:%S')}] {msg}")


def load_session():
    with open(SESSION_PATH) as f:
        s = json.load(f)
    return s["baseUrl"], s["cookieHeader"], s.get("csrfToken")


def mint_jwt(base_url, cookie_header, csrf):
    url = f"{base_url}/d2l/lp/auth/oauth2/token"
    data = b"scope=*:*:*"
    headers = {
        "Content-Type": "application/x-www-form-urlencoded",
        "Cookie": cookie_header,
    }
    if csrf:
        headers["X-Csrf-Token"] = csrf
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=TIMEOUT, context=CTX) as resp:
        body = resp.read().decode("utf-8", "replace")
    if "sessionExpired=1" in body:
        raise SystemExit("SESSION DEAD: mint returned sessionExpired stub. Refresh and retry.")
    token = json.loads(body).get("access_token")
    if not token:
        raise SystemExit("Mint returned no access_token and no expiry marker.")
    return token


def summarize(key, obj):
    """Small, non-secret shape summary proving real data came back."""
    try:
        if key == "course_info":
            return {"name": obj.get("Name"), "code": obj.get("Code"),
                    "isActive": obj.get("IsActive"),
                    "startDate": obj.get("StartDate"), "endDate": obj.get("EndDate")}
        if key == "content_root":
            n = len(obj) if isinstance(obj, list) else None
            first = obj[0].get("Title") if isinstance(obj, list) and obj else None
            return {"modules": n, "firstTitle": first}
        if key == "news":
            n = len(obj) if isinstance(obj, list) else None
            first = obj[0].get("Title") if isinstance(obj, list) and obj else None
            return {"items": n, "firstTitle": first}
        if key == "my_grades":
            n = len(obj) if isinstance(obj, list) else None
            return {"gradeValues": n}
        if key == "dropbox_folders":
            n = len(obj) if isinstance(obj, list) else None
            first = obj[0].get("Name") if isinstance(obj, list) and obj else None
            return {"folders": n, "firstName": first}
    except Exception as e:  # noqa: BLE001
        return {"summaryError": str(e)}
    return None


def probe(base_url, token, org_id, key, path_tmpl):
    url = base_url + path_tmpl.format(id=org_id)
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT, context=CTX) as resp:
            raw = resp.read().decode("utf-8", "replace")
            status = resp.status
        try:
            obj = json.loads(raw)
        except json.JSONDecodeError:
            return {"status": status, "note": "2xx but non-JSON body",
                    "bodyLen": len(raw)}
        return {"status": status, "summary": summarize(key, obj)}
    except urllib.error.HTTPError as e:
        detail = {}
        try:
            err = json.loads(e.read().decode("utf-8", "replace"))
            detail = {"title": err.get("title") or err.get("Title"),
                      "detail": err.get("detail") or err.get("Detail")}
        except Exception as parse_err:  # noqa: BLE001
            detail = {"parseError": str(parse_err)}
        return {"status": e.code, "error": detail}
    except (urllib.error.URLError, TimeoutError) as e:
        return {"status": None, "transport": str(e)}


def main():
    base_url, cookie_header, csrf = load_session()
    log(f"Session loaded. baseUrl={base_url}")
    token = mint_jwt(base_url, cookie_header, csrf)
    log(f"JWT minted (length {len(token)})")

    results = []
    for ou in ORG_UNITS:
        log(f"--- {ou['id']} {ou['name']} [{ou['bucket']}]")
        row = {"orgUnit": ou["id"], "name": ou["name"], "bucket": ou["bucket"],
               "routes": {}}
        for key, tmpl in ROUTES:
            res = probe(base_url, token, ou["id"], key, tmpl)
            row["routes"][key] = res
            st = res.get("status")
            extra = res.get("summary") or res.get("error") or res.get("transport") or ""
            log(f"      {key:16} -> {st}  {extra}")
        results.append(row)

    out = {
        "experiment": "6-ended-course-access",
        "capturedAt": datetime.now(timezone.utc).isoformat(),
        "baseUrl": base_url,
        "routes": [k for k, _ in ROUTES],
        "results": results,
    }
    os.makedirs(ARTIFACTS, exist_ok=True)
    path = os.path.join(ARTIFACTS, "findings.json")
    with open(path, "w") as f:
        json.dump(out, f, indent=2)
    log(f"Wrote {path}")


if __name__ == "__main__":
    main()
