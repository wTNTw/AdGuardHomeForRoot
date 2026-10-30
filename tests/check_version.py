#!/usr/bin/env python3
"""Check that the version and update-channel files tell the same story.

`version*.json` drives the root manager's update check, `src/module.prop` is what
the device shows, and a release tag is what CI publishes. If any of them drift,
users either never receive the update or are offered a package for the wrong
architecture.

Each architecture gets its own JSON (one file can only name one zipUrl), and
pack.sh / pack.ps1 stamp the matching URL into that build's module.prop:

  version.json        -> arm64, also the default channel baked into module.prop
  version-armv7.json  -> armv7

Run locally with no arguments. In CI (tag builds) the tag is compared as well:
GITHUB_REF_TYPE=tag and GITHUB_REF_NAME=<tag> are set by GitHub Actions.
"""
import json
import os
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MODULE_PROP = ROOT / "src/module.prop"

# file name -> architecture that the zipUrl must name
CHANNELS = {
    "version.json": "arm64",
    "version-armv7.json": "armv7",
}


def module_prop():
    values = {}
    for line in MODULE_PROP.read_text(encoding="utf-8").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    return values


def main():
    failed = False
    prop = module_prop()
    version, code = prop.get("version", ""), prop.get("versionCode")

    if not re.fullmatch(r"\d{8}", str(version)):
        failed = True
        print(f"FAIL  module.prop version must be YYYYMMDD, got {version!r}")
    if not str(code or "").isdigit():
        failed = True
        print(f"FAIL  module.prop versionCode must be an integer, got {code!r}")

    for key in ("id", "name", "author", "updateJson"):
        if not prop.get(key):
            failed = True
            print(f"FAIL  module.prop is missing {key}")

    # module.prop ship in src/ is the arm64 channel; pack.sh stamps the other
    # architectures into their own build.
    if not prop.get("updateJson", "").endswith("/version.json"):
        failed = True
        print(f"FAIL  src/module.prop must point at version.json, got {prop.get('updateJson')!r}")

    found = sorted(p.name for p in ROOT.glob("version*.json"))
    unknown = [name for name in found if name not in CHANNELS]
    if unknown:
        failed = True
        print(f"FAIL  unknown update channel file(s): {unknown} (add them to CHANNELS)")
    missing = [name for name in CHANNELS if name not in found]
    if missing:
        failed = True
        print(f"FAIL  missing update channel file(s): {missing}")

    for name, arch in sorted(CHANNELS.items()):
        path = ROOT / name
        if not path.exists():
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as err:
            failed = True
            print(f"FAIL  {name} is not valid JSON: {err}")
            continue

        problems = []
        if data.get("version") != version:
            problems.append(f"version {data.get('version')!r} != module.prop {version!r}")
        # module.prop stores everything as text; compare in that type.
        if str(data.get("versionCode")) != str(code):
            problems.append(f"versionCode {data.get('versionCode')!r} != module.prop {code!r}")
        expected_zip = f"AdGuardHomeForRoot_{arch}.zip"
        if not str(data.get("zipUrl", "")).endswith("/" + expected_zip):
            problems.append(f"zipUrl does not name {expected_zip}")
        if not str(data.get("changelog", "")).endswith("/changelog.md"):
            problems.append("changelog URL does not point at changelog.md")

        if problems:
            failed = True
            print(f"FAIL  {name} ({arch}): " + "; ".join(problems))
        else:
            print(f"PASS  {name} -> {expected_zip}, version {version} ({code})")

    if os.environ.get("GITHUB_REF_TYPE") == "tag":
        tag = os.environ.get("GITHUB_REF_NAME", "")
        if tag != str(version):
            failed = True
            print(f"FAIL  release tag {tag!r} != version {version!r}")
        else:
            print(f"PASS  release tag matches the version ({tag})")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
