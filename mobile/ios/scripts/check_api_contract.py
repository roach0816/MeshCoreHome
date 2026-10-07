#!/usr/bin/env python3
"""Checks that every server endpoint the iOS app calls exists in the server's API description.

Finds "/api/..." paths in the app's Swift sources, with the HTTP method where the call shows it
(get(...) is GET; send("PUT", ...) is PUT), and looks each one up in backend/openapi.json. Path
parameters ("\\(id)") match any "{name}". Run from anywhere: python3 mobile/ios/scripts/check_api_contract.py
"""

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
spec = json.loads((ROOT / "backend/openapi.json").read_text())

CALL = re.compile(r'(?:\bget\(\s*|download\(\s*|send(?:RawJSON)?\("(GET|POST|PUT|PATCH|DELETE)",\s*)"(/api/[^"]*)"')
LITERAL = re.compile(r'"(/api/[^"]*)"')
uses: list[tuple[str, str | None, str]] = []  # (path, method or None, where)
for f in sorted((ROOT / "mobile/ios/MeshHome").rglob("*.swift")):
    for n, line in enumerate(f.read_text().splitlines(), 1):
        where = f"{f.relative_to(ROOT)}:{n}"
        seen = set()
        for m in CALL.finditer(line):  # each call's own method: get(...)/download(...) are GET
            uses.append((m.group(2), m.group(1) or "GET", where))
            seen.add(m.start(2))
        line_methods = set(re.findall(r'send(?:RawJSON)?\("(\w+)"', line))
        for m in LITERAL.finditer(line):  # paths built elsewhere on the line (ternaries, closures)
            if m.start(1) not in seen:
                uses.append((m.group(1), next(iter(line_methods)) if len(line_methods) == 1 else None, where))

def matches(app_path: str) -> set[str]:
    """Methods of every API path this app path can be. A Swift interpolation matches any one
    segment, so "/api/contacts/\\(id)" matches "/api/contacts/{contact_id}"."""
    marked = re.sub(r"\\\([^)]*\)", "\0", app_path.split("?")[0])
    pattern = re.compile("^" + re.escape(marked).replace("\0", "[^/]+") + "$")
    out: set[str] = set()
    for path, ops in spec["paths"].items():
        if pattern.match(path):
            out.update(m.upper() for m in ops)
    return out

problems = []
for path, method, where in uses:
    methods = matches(path)
    if not methods:
        problems.append(f"{where}: {method or '?'} {path} is not in the API")
    elif method and method not in methods:
        problems.append(f"{where}: {method} {path}: the API has only {', '.join(sorted(methods))}")

print(f"Checked {len(uses)} API uses in the iOS app against backend/openapi.json")
for p in problems:
    print("  " + p)
sys.exit(1 if problems else 0)
