#!/usr/bin/env python3
"""Check that the three version files tell the same story.

`version.json` drives the root manager's update check, `src/module.prop` is what
the device shows, and a release tag is what CI publishes. If any of them drift,
users either never receive the update or install a package whose version does not
match the release.

Run locally with no arguments. In CI (tag builds) the tag is compared as well:
GITHUB_REF_TYPE=tag and GITHUB_REF_NAME=<tag> are set by GitHub Actions.
"""
import json
import os
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
VERSION_JSON = ROOT / "version.json"
MODULE_PROP = ROOT / "src/module.prop"


def module_prop():
    values = {}
    for line in MODULE_PROP.read_text(encoding="utf-8").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    return values


def main():
    failed = False
    data = json.loads(VERSION_JSON.read_text(encoding="utf-8"))
    prop = module_prop()

    version, code = data.get("version", ""), data.get("versionCode")
    if not re.fullmatch(r"\d{8}", str(version)):
        failed = True
        print(f"FAIL  version.json version must be YYYYMMDD, got {version!r}")
    else:
        print(f"PASS  version.json version is {version}")

    if not isinstance(code, int):
        failed = True
        print(f"FAIL  version.json versionCode must be an integer, got {code!r}")

    if prop.get("version") != version:
        failed = True
        print(f"FAIL  module.prop version {prop.get('version')!r} != version.json {version!r}")
    elif str(prop.get("versionCode")) != str(code):
        failed = True
        print(f"FAIL  module.prop versionCode {prop.get('versionCode')!r} != version.json {code!r}")
    else:
        print(f"PASS  module.prop matches version.json (version {version}, versionCode {code})")

    for key in ("id", "name", "author", "updateJson"):
        if not prop.get(key):
            failed = True
            print(f"FAIL  module.prop is missing {key}")

    if os.environ.get("GITHUB_REF_TYPE") == "tag":
        tag = os.environ.get("GITHUB_REF_NAME", "")
        if tag != str(version):
            failed = True
            print(f"FAIL  release tag {tag!r} != version.json version {version!r}")
        else:
            print(f"PASS  release tag matches version.json ({tag})")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
