#!/usr/bin/env python3
"""List the releases whose documentation is published on GitHub Pages.

Prints a JSON array, newest first, with one entry per minor release: the latest patch tag
of every `major.minor` from the minimum version on. Pre-release tags (`1.4.0-beta.11`) are
ignored, and a new patch replaces the previous one of its minor.

    [{"label": "1.3", "ref": "1.3.0", "commit": "30c8067c..."}, ...]

`label` is the URL segment (`/swift-ddd-kit/1.3/documentation/`), so a minor
keeps its URL across patches; `ref` is the tag the documentation is built from and `commit`
the commit it points at (the CI cache key, so a moved tag is rebuilt).

Usage: scripts/doc-versions.py [--minimum 1.0]   (reads the tags with `git tag`)
"""

import argparse
import json
import re
import subprocess

RELEASE_TAG = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")


def git(*arguments: str) -> str:
    return subprocess.run(["git", *arguments], check=True, capture_output=True, text=True).stdout


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--minimum", default="1.0", help="oldest major.minor to publish")
    arguments = parser.parse_args()
    minimum = tuple(int(part) for part in arguments.minimum.split("."))

    tags = git("tag", "--list").split()

    latest_patch: dict[tuple[int, int], int] = {}
    for tag in tags:
        match = RELEASE_TAG.match(tag)
        if not match:
            continue
        major, minor, patch = (int(part) for part in match.groups())
        if (major, minor) >= minimum:
            latest_patch[(major, minor)] = max(patch, latest_patch.get((major, minor), patch))

    releases = [
        {"label": f"{major}.{minor}", "ref": f"{major}.{minor}.{patch}"}
        for (major, minor), patch in sorted(latest_patch.items(), reverse=True)
    ]
    for release in releases:
        release["commit"] = git("rev-list", "-n", "1", release["ref"]).strip()
    print(json.dumps(releases))


if __name__ == "__main__":
    main()
