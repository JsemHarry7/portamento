#!/bin/bash
# Pack a runtime for a release: <out-dir>/<name>.tar.xz holding <name>/, which is
# what `porta setup` unpacks into its runtimes/ directory.
#
# Usage: scripts/package-runtime.sh <runtime-dir> <out-dir>
set -euo pipefail

DIR="$(cd "$1" && pwd)"
OUT="$2"
NAME="$(basename "$DIR")"
mkdir -p "$OUT"
# no AppleDouble (._*) files or extended attributes in the archive
COPYFILE_DISABLE=1 tar -C "$(dirname "$DIR")" --no-mac-metadata -cf - "$NAME" | xz -T0 -6 > "$OUT/$NAME.tar.xz"
echo "$OUT/$NAME.tar.xz"
