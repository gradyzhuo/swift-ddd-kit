#!/usr/bin/env bash
# Builds a dddkit_<version>_<arch>.deb from a release binary.
#
# Usage: build-deb.sh <version> <arch> <path-to-dddkit-binary> <output-dir>
#   version: e.g. 1.0.2 (no leading "v" — matches this repo's tag convention)
#   arch:    amd64 | arm64 (Debian arch name, not Swift's x86_64/aarch64)
set -euo pipefail

VERSION="$1"
ARCH="$2"
BINARY="$3"
OUTPUT_DIR="$4"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

PKG_ROOT="$WORK_DIR/dddkit_${VERSION}_${ARCH}"
mkdir -p "$PKG_ROOT/DEBIAN" "$PKG_ROOT/usr/bin"

sed -e "s/@VERSION@/${VERSION}/" -e "s/@ARCH@/${ARCH}/" \
    "$SCRIPT_DIR/control.in" > "$PKG_ROOT/DEBIAN/control"

install -m 0755 "$BINARY" "$PKG_ROOT/usr/bin/dddkit"

mkdir -p "$OUTPUT_DIR"
dpkg-deb --build --root-owner-group "$PKG_ROOT" \
    "$OUTPUT_DIR/dddkit_${VERSION}_${ARCH}.deb"
