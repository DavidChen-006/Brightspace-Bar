#!/usr/bin/env python3
"""Approach A — does the D2L API hand us a per-assignment link directly?

Dumps the COMPLETE field list of every dropbox folder and content topic for the two
reachable courses, so we can see whether anything link-shaped exists rather than
guessing. Writes artifacts/approach-a.json.

Secrets: the cookie, CSRF token and JWT are never printed or stored. JWT length only.
Read-only apart from the one permitted token mint POST.
"""

import json
import pathlib
import sys
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
SESSION = pathlib.Path.home() / "Library/Application Support/BrightspaceBar/session.json"
TIMEOUT = 30
COURSES = {
    440703: "Scholarly Project Milestones",
    412690: "Purdue Civics Knowledge Test",
}
# Link-shaped field names worth flagging if they turn up anywhere.
LINKISH = ("url", "href", "link", "quicklink", "path", "location")


def mint_jwt(base: str, cookie: str, csrf: str) -> str:
    """The one permitted non-GET. A dead session answers 200 + an HTML stub."""
    req = urllib.request.Request(
        base + "/d2l/lp/auth/oauth2/token",
        data=b"scope=*:*:*",
        method="POST",
        headers={
            "content-type": "application/x-www-form-urlencoded",
            "cookie": cookie,
            "x-csrf-token": csrf,
        },
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT) as response:
        body = response.read()
    if b"sessionExpired=1" in body:
        sys.exit("session is dead — re-run Scripts/refresh-session.sh --capture")
    token = json.loads(body)["access_token"]
    print(f"JWT minted (length {len(token)})")
    return token


def get(base: str, jwt: str, path: str):
    """GET a JSON route. Returns (status, parsed-or-None)."""
    req = urllib.request.Request(base + path, headers={"Authorization": f"Bearer {jwt}"})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as error:
        return error.code, None


def shape(value):
    """Describe a value's type without echoing anything large."""
    if isinstance(value, dict):
        return f"object({len(value)} keys)"
    if isinstance(value, list):
        return f"array[{len(value)}]"
    if isinstance(value, str):
        return f"string({len(value)})"
    return type(value).__name__


def describe(obj: dict) -> dict:
    """Every field name, its type, and the value when small and safe to record."""
    out = {}
    for key, value in obj.items():
        entry = {"type": shape(value)}
        small_scalar = isinstance(value, (int, float, bool)) or value is None
        if small_scalar or (isinstance(value, str) and len(value) <= 200):
            entry["value"] = value
        if any(hint in key.lower() for hint in LINKISH):
            entry["LINKISH"] = True
        out[key] = entry
    return out


def walk_content(items, sink, depth=0) -> None:
    """Content is a module tree; topics are the leaves that may carry `Url`."""
    for item in items or []:
        fields = describe(item)
        sink.append(
            {
                "id": item.get("Id"),
                "type": item.get("Type"),
                "title": item.get("Title"),
                "topicType": item.get("TopicType"),
                "url": item.get("Url"),
                "linkishFields": [k for k, v in fields.items() if v.get("LINKISH")],
                "depth": depth,
            }
        )
        if item.get("Url"):
            print(f"    {'  ' * depth}Url: {item.get('Title', '')[:34]!r} -> {item['Url']}")
        walk_content(item.get("Structure"), sink, depth + 1)


def main() -> None:
    session = json.loads(SESSION.read_text())
    base = session["baseUrl"]
    jwt = mint_jwt(base, session["cookieHeader"], session.get("csrfToken") or "")

    findings = {"baseUrl": base, "courses": {}}

    for org_unit, name in COURSES.items():
        print(f"\n=== {org_unit} — {name}")
        course = {"name": name, "dropboxFolders": [], "contentTopics": []}

        status, folders = get(base, jwt, f"/d2l/api/le/1.96/{org_unit}/dropbox/folders/")
        course["dropboxStatus"] = status
        print(f"  dropbox/folders/ -> {status}, {len(folders or [])} folders")
        for folder in folders or []:
            fields = describe(folder)
            linkish = [k for k, v in fields.items() if v.get("LINKISH")]
            print(f"    Id={folder.get('Id')} {folder.get('Name', '')[:40]!r}")
            print(f"      fields: {', '.join(sorted(fields))}")
            print(f"      link-shaped: {linkish or 'NONE'}")
            course["dropboxFolders"].append(
                {
                    "id": folder.get("Id"),
                    "name": folder.get("Name"),
                    "dueDate": folder.get("DueDate"),
                    "fields": fields,
                    "linkishFields": linkish,
                    # The trap: instructor-attached external resources, NOT a deep link.
                    "linkAttachments": folder.get("LinkAttachments"),
                }
            )

        status, root = get(base, jwt, f"/d2l/api/le/1.96/{org_unit}/content/root/")
        course["contentStatus"] = status
        modules = root if isinstance(root, list) else []
        print(f"  content/root/ -> {status}, {len(modules)} top-level modules")

        walk_content(modules, course["contentTopics"])
        findings["courses"][str(org_unit)] = course

    out = ROOT / "artifacts" / "approach-a.json"
    out.write_text(json.dumps(findings, indent=2))
    print(f"\nwrote {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
