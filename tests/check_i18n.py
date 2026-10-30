#!/usr/bin/env python3
"""Check that the web UI translation files stay in sync with the markup and code.

Fails when:
  * a key exists in only one of en.json / zh.json
  * index.html or index.js references a key that is missing from the locales

Unused keys are only reported, never fatal: dropping a key from the UI is not a
bug, but it should not go unnoticed either.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LOCALES = ROOT / "src/webroot/assets/locales"
HTML = ROOT / "src/webroot/index.html"
JS = ROOT / "src/webroot/assets/index.js"


def load(name):
    return json.loads((LOCALES / name).read_text(encoding="utf-8"))


def referenced_keys():
    keys = set()
    html = HTML.read_text(encoding="utf-8")
    keys |= set(re.findall(r'data-i18n="([^"]+)"', html))
    keys |= set(re.findall(r'data-i18n-placeholder="([^"]+)"', html))

    js = JS.read_text(encoding="utf-8")
    # t('literal') / t("literal"); template literals with expressions are runtime
    # values (status.<state>) and are checked through their prefixes below.
    keys |= set(re.findall(r"""\bt\(\s*['"]([^'"`$]+)['"]\s*\)""", js))
    return keys


def main():
    en, zh = load("en.json"), load("zh.json")
    failed = False

    only_en = sorted(set(en) - set(zh))
    only_zh = sorted(set(zh) - set(en))
    if only_en or only_zh:
        failed = True
        print(f"FAIL  locale key sets differ (en-only: {only_en}, zh-only: {only_zh})")
    else:
        print(f"PASS  en.json and zh.json carry the same {len(en)} keys")

    used = referenced_keys()
    missing = sorted(k for k in used if k not in en or k not in zh)
    if missing:
        failed = True
        print(f"FAIL  keys used by the UI but missing from the locales: {missing}")
    else:
        print(f"PASS  every key referenced by the UI exists in both locales ({len(used)})")

    # status.running / status.stopped are selected at runtime.
    for dynamic in ("status.running", "status.stopped"):
        if dynamic not in en or dynamic not in zh:
            failed = True
            print(f"FAIL  runtime key missing: {dynamic}")

    unused = sorted(k for k in en if k not in used and not k.startswith("status."))
    if unused:
        print(f"note  keys not referenced statically: {unused}")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
