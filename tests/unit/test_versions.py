"""versions.yml is the one place a pinned upstream version lives.

Guards: the file's schema; every `kw_* <key>` call names an entry and every entry is
used; no task script carries its own version literal; each `# HELD` entry has its
`allowedVersions` rule in renovate.json and vice versa. Also the `kw_*` helpers
themselves (they are what every migrated script calls).
"""

from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path

import pytest
import yaml

REPO = Path(__file__).resolve().parents[2]
VERSIONS = REPO / "versions.yml"
RENOVATE = REPO / "renovate.json"

DATASOURCES = {"docker", "github-releases", "github-tags", "pypi", "git-refs", "custom"}
FIELDS = {"datasource", "package", "version", "digest", "versioning"}
KEY = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
USE = re.compile(r"\bkw_(?:image|version|pin)\s+([a-z0-9-]+)")

# ── hard-coded pins ────────────────────────────────────────────────────────────────
# `<SOMETHING>_IMAGE|VERSION|TAG|REF|COMMIT|DIGEST…` given a literal default
PIN_DEFAULT = re.compile(
    r"\b(?P<var>(?:[A-Z0-9]+_)*(?:IMAGE|VERSION|TAG|REF|COMMIT|DIGEST)(?:_[A-Z0-9]+)*)"
    r"(?::?[-=]|=)\"?(?P<value>[^\"'$\s)}][^\"\s)};]*)"
)
# a help text that prints a literal image default: `(default: postgres:16-alpine`
HELP_DEFAULT = re.compile(r"default:\s*(?P<value>[\w.-]+(?:/[\w.-]+)*:[\w.-]*\d[\w.@:-]*)")
# an `image:` line in an inline compose heredoc
INLINE_IMAGE = re.compile(r"^\s*image:\s*(?P<value>[^\s$\"'][^\s\"']*)")
# a full commit SHA or an image digest anywhere
HASH = re.compile(r"\b(?P<value>sha256:[0-9a-f]{64}|[0-9a-f]{40})\b")
HOST_PORT = re.compile(r"^[0-9.]+:[0-9]+$")
# values that are not a version even when the variable name says so
NOT_A_PIN = re.compile(r"^(?:[0-9]+|true|false|unknown|-.*|/.*|https?://.*)$|^[A-Z_]+$|\$")
# (script, variable) pairs that are constraints or local names, not installs
ALLOWED = {
    ("setup-gufo-strix-halo-qwen38-flash.sh", "HSA_OVERRIDE_GFX_VERSION"),
    ("setup-gufo-strix-halo-qwen38-27b.sh", "HSA_OVERRIDE_GFX_VERSION"),
    ("setup-deepseek-harness.sh", "DSH_NODE_VERSION"),
}
#: flipped to False once every script reads versions.yml (step 3 of the plan)
REPORT_ONLY = True


def load() -> dict:
    return yaml.safe_load(VERSIONS.read_text())


def entry_comments() -> dict[str, str]:
    """Comment text that belongs to each top-level entry (its block in the raw file)."""
    out: dict[str, str] = {}
    key = None
    for line in VERSIONS.read_text().splitlines():
        top = re.match(r"^([a-z0-9-]+):\s*$", line)
        if top:
            key = top.group(1)
            out[key] = ""
        elif key and "#" in line:
            out[key] += line.split("#", 1)[1] + "\n"
    return out


def held_rules() -> dict[str, str]:
    rules = json.loads(RENOVATE.read_text()).get("packageRules", [])
    out = {}
    for rule in rules:
        if "allowedVersions" in rule:
            for name in rule.get("matchDepNames", []):
                out[name] = rule["allowedVersions"]
    return out


def code_lines(path: Path):
    for n, line in enumerate(path.read_text().splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        yield n, line


def hard_coded_pins() -> list[str]:
    found = []
    for script in sorted((REPO / "tasks").glob("*.sh")):
        for n, line in code_lines(script):
            hits = []
            for m in PIN_DEFAULT.finditer(line):
                if (script.name, m["var"]) in ALLOWED or NOT_A_PIN.search(m["value"]):
                    continue
                hits.append(f"{m['var']}={m['value']}")
            hits += [
                f"default: {m['value']}"
                for m in HELP_DEFAULT.finditer(line)
                if not HOST_PORT.match(m["value"])
            ]
            if m := INLINE_IMAGE.match(line):
                hits.append(f"image: {m['value']}")
            hits += [m["value"] for m in HASH.finditer(line)]
            found += [f"{script.name}:{n}: {hit}" for hit in dict.fromkeys(hits)]
    return found


# ── schema ─────────────────────────────────────────────────────────────────────────


def test_versions_file_schema():
    data = load()
    assert isinstance(data, dict) and data
    for key, entry in data.items():
        assert KEY.match(key), f"{key}: keys are kebab-case"
        assert isinstance(entry, dict), f"{key}: an entry is a mapping"
        assert {"datasource", "package", "version"} <= entry.keys(), f"{key}: missing fields"
        assert entry.keys() <= FIELDS, f"{key}: unknown fields {entry.keys() - FIELDS}"
        assert entry["datasource"] in DATASOURCES, f"{key}: datasource {entry['datasource']}"
        for field in entry.keys() - {"datasource"}:
            # an unquoted 7.20 would load as the float 7.2 and pin the wrong tag
            assert isinstance(entry[field], str) and entry[field], f"{key}.{field}: quote it"


def test_every_used_key_exists_and_every_entry_is_used():
    data = load()
    used: dict[str, set[str]] = {}
    for path in [*REPO.glob("tasks/*.sh"), *REPO.glob("lib/*.sh"), *REPO.glob("utilities/*.sh")]:
        for _, line in code_lines(path):
            for key in USE.findall(line):
                used.setdefault(key, set()).add(path.name)
    missing = {k: sorted(v) for k, v in used.items() if k not in data}
    assert not missing, f"kw_* calls name keys absent from versions.yml: {missing}"
    dead = sorted(set(data) - set(used))
    assert not dead, f"versions.yml entries no script reads: {dead}"


def test_no_hard_coded_pins_in_tasks():
    pins = hard_coded_pins()
    if REPORT_ONLY:
        print(f"\n{len(pins)} hard-coded pin(s) left in tasks/:\n" + "\n".join(pins))
        return
    assert not pins, "version literals belong in versions.yml:\n" + "\n".join(pins)


def test_held_entries_match_renovate_allowed_versions():
    held = {k for k, text in entry_comments().items() if "HELD" in text}
    rules = held_rules()
    assert held == set(rules), (
        f"HELD without allowedVersions: {sorted(held - set(rules))}; "
        f"allowedVersions without HELD: {sorted(set(rules) - held)}"
    )


# ── the kw_* helpers ───────────────────────────────────────────────────────────────


def kw(snippet: str, versions: Path | None = None) -> subprocess.CompletedProcess:
    env = {"PATH": "/usr/bin:/bin"}
    if versions is not None:
        env["KW_VERSIONS_FILE"] = str(versions)
    return subprocess.run(
        ["bash", "-c", f'source "{REPO}/lib/helpers.sh"; {snippet}'],
        capture_output=True,
        text=True,
        env=env,
    )


@pytest.fixture
def versions_file(tmp_path: Path) -> Path:
    path = tmp_path / "versions.yml"
    path.write_text(
        'plain:\n  datasource: docker\n  package: ex/plain\n  version: "1.2"\n'
        'pinned:\n  datasource: docker\n  package: ex/pinned\n  version: "2.0"\n'
        '  digest: "sha256:abc"\n'
    )
    return path


def test_kw_image_and_version(versions_file):
    out = kw("kw_image plain; kw_image pinned; kw_version pinned; kw_pin pinned digest", versions_file)
    assert out.returncode == 0, out.stderr
    assert out.stdout.split() == ["ex/plain:1.2", "ex/pinned:2.0@sha256:abc", "2.0", "sha256:abc"]


@pytest.mark.parametrize("call", ["kw_image nope", "kw_pin plain digest", "kw_version"])
def test_kw_failure_is_loud(versions_file, call):
    out = kw(call, versions_file)
    assert out.returncode != 0
    assert "kw_pin" in out.stderr


def test_kw_failure_aborts_a_set_e_assignment(versions_file):
    out = kw('set -e; X="${X:-$(kw_image nope)}"; echo reached', versions_file)
    assert out.returncode != 0 and "reached" not in out.stdout


def test_override_still_wins(versions_file):
    out = kw('X=mine; X="${X:-$(kw_image nope)}"; echo "$X"', versions_file)
    assert out.stdout.strip() == "mine"


def test_kw_reads_the_repo_file_by_default():
    out = kw("kw_image renovate")
    assert out.returncode == 0, out.stderr
    assert out.stdout.strip() == f"renovate/renovate:{load()['renovate']['version']}"
