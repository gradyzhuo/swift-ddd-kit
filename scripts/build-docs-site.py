#!/usr/bin/env python3
"""Assemble the GitHub Pages site: the landing page plus one DocC build per version.

    /<base>/                                     landing page (docs/)
    /<base>/documentation/                       latest release: every module, one overview
    /<base>/documentation/<module>/              latest release, one module
    /<base>/<label>/documentation/<module>/      every release (including the latest) and main
    /<base>/doc-versions.json                    the version menu's entries, newest first

`--inputs` holds one directory per label (`1.3`, ..., `main`), laid out as

    <label>/symbol-graphs/<Module>/<Module>.symbols.json   (and <Module>@<Other>.symbols.json)
    <label>/catalogs/<Module>.docc                         (optional)

Each module is converted on its own and the modules of a version are combined with
`docc merge`, which adds the overview page that lists them. `--releases` is the output of
scripts/doc-versions.py; `main` is added after the releases.

Every generated page loads `/<base>/doc-versions.js` (from docs/), which draws the menu.

Usage:
  scripts/build-docs-site.py --inputs DIR --releases JSON --output DIR [--docc "xcrun docc"]
"""

import argparse
import json
import shlex
import shutil
import subprocess
import tempfile
from pathlib import Path

SITE_NAME = "swift-ddd-kit"


def convert(docc: list[str], source: Path, module: str, output: Path) -> None:
    catalog = source / "catalogs" / f"{module}.docc"
    subprocess.run(
        [
            *docc, "convert",
            *([str(catalog)] if catalog.is_dir() else []),
            "--additional-symbol-graph-dir", str(source / "symbol-graphs" / module),
            "--fallback-display-name", module,
            "--fallback-bundle-identifier", module,
            "--enable-experimental-external-link-support",
            "--output-path", str(output),
        ],
        check=True,
    )


def build_archive(docc: list[str], source: Path, work: Path) -> Path:
    """Convert every module of one version and merge them into a single archive."""
    modules = sorted(entry.name for entry in (source / "symbol-graphs").iterdir() if entry.is_dir())
    if not modules:
        raise SystemExit(f"error: {source} has no modules")
    work.mkdir(parents=True)
    archives = []
    for module in modules:
        archive = work / f"{module}.doccarchive"
        convert(docc, source, module, archive)
        archives.append(str(archive))
    combined = work / "combined.doccarchive"
    subprocess.run(
        [
            *docc, "merge", *archives,
            "--synthesized-landing-page-name", SITE_NAME,
            "--synthesized-landing-page-kind", "Package",
            "--output-path", str(combined),
        ],
        check=True,
    )
    return combined


def host(docc: list[str], archive: Path, hosting_base_path: str, output: Path) -> None:
    subprocess.run(
        [
            *docc, "process-archive", "transform-for-static-hosting", str(archive),
            "--hosting-base-path", hosting_base_path,
            "--output-path", str(output),
        ],
        check=True,
    )


def merge(source: Path, destination: Path, origin: str) -> None:
    """Copy `source` into `destination`; a name both sides use is an error, not an overwrite."""
    for entry in source.iterdir():
        target = destination / entry.name
        if target.exists():
            raise SystemExit(f"error: {origin}/{entry.name} collides with an existing site path")
        if entry.is_dir():
            shutil.copytree(entry, target)
        else:
            shutil.copy2(entry, target)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--inputs", type=Path, required=True)
    parser.add_argument("--releases", required=True, help="JSON from scripts/doc-versions.py")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--landing", type=Path, default=Path("docs"))
    parser.add_argument("--base", default="swift-ddd-kit", help="GitHub Pages path of the site")
    parser.add_argument("--docc", default="docc", help='docc command, e.g. "xcrun docc"')
    arguments = parser.parse_args()

    docc = shlex.split(arguments.docc)
    releases = json.loads(arguments.releases)
    versions = [*releases, {"label": "main", "ref": "main"}]
    output: Path = arguments.output
    output.mkdir(parents=True)
    work = Path(tempfile.mkdtemp())

    for version in versions:
        label = version["label"]
        archive = build_archive(docc, arguments.inputs / label, work / label)
        host(docc, archive, f"{arguments.base}/{label}", output / label)

        # The latest release is also published at the root, so the plain
        # /documentation/ links always show what users install.
        if releases and label == releases[0]["label"]:
            host(docc, archive, arguments.base, work / "root")
            (work / "root" / "index.html").unlink()  # the landing page owns /index.html
            merge(work / "root", output, "DocC (latest release)")

    shutil.rmtree(work)

    menu_script = f'<script defer src="/{arguments.base}/doc-versions.js"></script>'
    for page in output.rglob("index.html"):
        html = page.read_text()
        page.write_text(html.replace("</head>", f"{menu_script}</head>", 1))

    entries = [
        {"title": version["ref"], "path": version["label"], "latest": index == 0 and bool(releases)}
        for index, version in enumerate(versions)
    ]
    (output / "doc-versions.json").write_text(json.dumps(entries, indent=2) + "\n")

    merge(arguments.landing, output, str(arguments.landing))


if __name__ == "__main__":
    main()
