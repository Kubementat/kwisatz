#!/usr/bin/env python3
"""Turn a Renovate `--dry-run=lookup` JSON log into the versions.yml report.

Usage: renovate-report.py <renovate.log> [--json]

Shared by utilities/check-versions.sh and templates/concourse/renovate-check-pipeline.yml.
Prints one line per versions.yml entry (`key  current  →  latest`), or Renovate's
per-dependency result as JSON with --json. Renovate warnings/errors go to stderr.
"""
import json
import sys

log, as_json = sys.argv[1], "--json" in sys.argv[2:]
deps, problems = [], []
with open(log) as fh:
    for line in fh:
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        if rec.get("level", 0) >= 40:
            problems.append(rec.get("msg", ""))
        if rec.get("msg") == "packageFiles with updates":
            for files in rec["config"].values():
                for f in files:
                    if f.get("packageFile") == "versions.yml":
                        deps.extend(f["deps"])
for msg in problems:
    print(f"[WARN]  renovate: {msg}", file=sys.stderr)
if not deps:
    sys.exit("[ERROR] renovate reported no dependencies for versions.yml")
if as_json:
    json.dump(deps, sys.stdout, indent=2)
    print()
    sys.exit(0)
width = max(len(d["depName"]) for d in deps)
for d in sorted(deps, key=lambda d: d["depName"]):
    current = d.get("currentValue", "")
    if d.get("currentDigest"):
        current += f"@{d['currentDigest'][:12]}"
    if d.get("skipReason"):
        latest = f"(skipped: {d['skipReason']})"
    else:
        news = []
        for u in d.get("updates", []):
            new = u.get("newValue") or current
            if u.get("updateType") == "digest" or (u.get("newDigest") and new == d.get("currentValue")):
                new += f"@{u['newDigest'][:12]}"
            news.append(f"{new} ({u.get('updateType')})")
        latest = ", ".join(news) if news else "up to date"
    print(f"{d['depName']:<{width}}  {current}  →  {latest}")
