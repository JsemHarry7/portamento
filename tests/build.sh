#!/bin/bash
# Build the Windows smoke tests used by `porta selftest` (and wincap, the macOS
# helper for capturing a single window).
#
# Usage: tests/build.sh [output-dir]    (default: tests/)
# Needs: Homebrew mingw-w64 and vulkan-headers (or a Vulkan SDK in VULKAN_INCLUDE).
set -euo pipefail

cd "$(dirname "$0")"
OUT="${1:-.}"
mkdir -p "$OUT"
CC=x86_64-w64-mingw32-gcc
if [ -z "${VULKAN_INCLUDE:-}" ]; then
    for dir in /opt/homebrew/include /usr/local/include \
               "${PORTA_HOME:-$HOME/Library/Application Support/Portamento}"/runtimes/vulkan-sdk-*/macOS/include; do
        [ -f "$dir/vulkan/vulkan.h" ] && VULKAN_INCLUDE="$dir" && break
    done
fi
[ -f "${VULKAN_INCLUDE:-}/vulkan/vulkan.h" ] || { echo "no Vulkan headers: brew install vulkan-headers" >&2; exit 1; }

# d3d11test_shaders.h is generated (by shadergen.exe, run under Wine) and checked in.
$CC -O2 -o "$OUT/d3d9test.exe" d3d9test.c -ld3d9
$CC -O2 -o "$OUT/shadergen.exe" shadergen.c -ld3dcompiler_47
$CC -O2 -o "$OUT/d3d11test.exe" d3d11test.c -ld3d11 -ldxguid -luuid
$CC -O2 -o "$OUT/d3d12test.exe" d3d12test.c -ld3d12 -ldxgi -ldxguid -luuid
$CC -O2 -I"$VULKAN_INCLUDE" -o "$OUT/vktest.exe" vktest.c
$CC -O2 -o "$OUT/gltest.exe" gltest.c -lopengl32 -lgdi32
$CC -O2 -o "$OUT/tone.exe" tone.c -lwinmm -lm
$CC -O2 -o "$OUT/xprocgdi.exe" xprocgdi.c -lgdi32
clang -O2 -o "$OUT/wincap" wincap.c -framework CoreGraphics -framework CoreFoundation
