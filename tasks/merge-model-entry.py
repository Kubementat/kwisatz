#!/usr/bin/env python3
"""merge-model-entry.py — additively merge a rendered catalog fragment into models.yml.

Used by tasks/setup-tensorfold.sh: replaces (or adds) one model entry in the
local llama-swap catalog. The catalog is seeded from models.yml.default when
missing. A re-run is a no-op (no write, no comment loss) while the rendered
entry is unchanged; --force writes anyway.

The fragment must be a valid catalog with exactly one provider and exactly
one model, and the model name must match --name.
"""

import argparse
import shutil
import sys
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent  # parent of tasks/
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

import yaml  # noqa: E402

from sync_models import PreflightError  # noqa: E402
from sync_models.atomicio import atomic_write_text  # noqa: E402
from sync_models.catalog import load_catalog, validate_catalog  # noqa: E402


class _BlockDumper(yaml.SafeDumper):
    pass


def _str_representer(dumper, value):
    # Multi-line values (serve.cmd) must serialize as literal blocks.
    style = "|" if "\n" in value else None
    return dumper.represent_scalar("tag:yaml.org,2002:str", value, style=style)


_BlockDumper.add_representer(str, _str_representer)


def extract_entry(fragment_path: Path, expected_name: str) -> tuple[dict, dict]:
    """Return (model_dict, provider_dict) from the fragment.

    The fragment must validate as a catalog with exactly one provider and
    exactly one model, and the model name must equal expected_name.
    """
    data = load_catalog(fragment_path)
    validate_catalog(data, fragment_path)
    providers = data["providers"]
    if len(providers) != 1:
        raise PreflightError(
            f"fragment {fragment_path} must contain exactly one provider"
        )
    provider = providers[0]
    models = provider.get("models") or []
    if len(models) != 1:
        raise PreflightError(
            f"fragment {fragment_path} must contain exactly one model"
        )
    model = models[0]
    if model.get("name") != expected_name:
        raise PreflightError(
            f"fragment model name '{model.get('name')}' does not match "
            f"--name '{expected_name}'"
        )
    return model, provider


def merge(
    catalog_data: dict, model: dict, provider_name: str
) -> tuple[dict, str]:
    """Merge *model* into *catalog_data*; return (data, status).

    Status: "unchanged" (an identical entry already exists), "replaced"
    (an existing local entry was updated in place), "added" (appended to the
    provider named *provider_name*).
    """
    for prov in catalog_data["providers"]:
        for existing in prov.get("models") or []:
            if (
                existing.get("name") == model.get("name")
                and existing.get("type") == "local"
            ):
                if existing == model:
                    return catalog_data, "unchanged"
                prov["models"][prov["models"].index(existing)] = model
                return catalog_data, "replaced"

    for prov in catalog_data["providers"]:
        if prov.get("name") == provider_name:
            prov.setdefault("models", []).append(model)
            return catalog_data, "added"

    raise PreflightError(
        f"catalog has no provider named '{provider_name}' to host the entry"
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="merge-model-entry.py",
        description=__doc__,
    )
    parser.add_argument("--catalog", required=True, type=Path)
    parser.add_argument("--default", type=Path, default=None)
    parser.add_argument("--entry", required=True, type=Path)
    parser.add_argument("--name", required=True)
    parser.add_argument("--provider", default="local")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args(argv)

    try:
        model, _ = extract_entry(args.entry, args.name)

        if not args.catalog.is_file():
            if args.default is not None and args.default.is_file():
                shutil.copyfile(args.default, args.catalog)
                print(f"catalog {args.catalog} seeded from {args.default}")
            else:
                print(
                    f"ERROR: catalog not found: {args.catalog} "
                    "(and no --default to seed from)"
                )
                return 1

        data = load_catalog(args.catalog)
        validate_catalog(data, args.catalog)

        data, status = merge(data, model, args.provider)
        if status == "unchanged" and not args.force:
            print(f"catalog entry '{args.name}' unchanged — no write")
            return 0

        # The merged document must still validate (schema is global).
        validate_catalog(data, args.catalog)
        print(
            f"WARNING: rewriting {args.catalog} as YAML — any user comments in "
            "the file are not preserved"
        )
        text = yaml.dump(
            data,
            Dumper=_BlockDumper,
            sort_keys=False,
            default_flow_style=False,
            allow_unicode=True,
        )
        atomic_write_text(
            args.catalog, text, validate=yaml.safe_load, expected=data,
            label="catalog",
        )
        print(f"catalog entry '{args.name}' {status} in {args.catalog}")
        return 0
    except PreflightError as exc:
        for message in exc.messages:
            print(f"ERROR: {message}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
