#!/usr/bin/env python3
"""Warns about the strings of app/Localizable.xcstrings that miss a translation or are no longer used.

Run by build.sh after `xcstringstool sync` has added the strings found in app/*.swift to the catalog.
"""
import json
import pathlib
import sys

CATALOG = pathlib.Path(__file__).with_name("Localizable.xcstrings")
LANGUAGES = ["fr"]


def translated(localization):
    """A plain string, or every case of its plural / device variations, marked translated."""
    if not localization:
        return False
    if "stringUnit" in localization:
        return localization["stringUnit"].get("state") == "translated"
    cases = [case for kind in localization.get("variations", {}).values() for case in kind.values()]
    return bool(cases) and all(translated(case) for case in cases)


def main():
    strings = json.loads(CATALOG.read_text())["strings"]
    for key, entry in sorted(strings.items()):
        if entry.get("extractionState") == "stale":
            print(f"warning: {CATALOG.name}: no longer used in the code, remove it: {key!r}", file=sys.stderr)
        elif entry.get("shouldTranslate") is not False:
            for language in LANGUAGES:
                if not translated(entry.get("localizations", {}).get(language)):
                    print(f"warning: {CATALOG.name}: no {language} translation: {key!r}", file=sys.stderr)


if __name__ == "__main__":
    main()
