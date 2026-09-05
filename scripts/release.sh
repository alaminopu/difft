#!/bin/bash
# Build the app and zip it for a GitHub release.
# Usage: scripts/release.sh <version>   e.g. scripts/release.sh 0.1.0
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>}"
OUT="dist"

scripts/package.sh "$OUT" >/dev/null

# ditto rather than zip: it preserves the bundle's symlinks and resource
# forks, which a plain zip mangles enough to break the signature.
ZIP="$OUT/Difft-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$OUT/Difft.app" "$ZIP"

echo "version: $VERSION"
echo "archive: $ZIP"
echo "size:    $(du -h "$ZIP" | cut -f1)"
echo "sha256:  $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
