#!/bin/bash
# Rebuild the Wine modules porta patches, from the same sources as the stock
# Gcenx wine-staging build (upstream + every staging patch) plus ours:
#
#   patches/winemac-metal-compat.patch              -> winemac.so     (DXMT/D3DMetal on upstream Wine)
#   patches/kernelbase-steamwebhelper-in-process-gpu.patch
#                                                   -> kernelbase.dll (Steam UI not black)
#   patches/ntdll-export-wine-unix-call.patch       -> ntdll.dll      (D3DMetal PE modules)
#
# Only these modules are built; they replace the ones in a stock build of the
# same version. They are installed into $PORTA_HOME/runtimes/wine-mods-<version>/,
# laid out like a Wine's lib/wine/, where `porta setup` picks them up.
#
# Usage: scripts/build-wine-mods.sh [wine-version]    (default: 11.21)
# Needs: Xcode CLT, Homebrew bison, autoconf and mingw-w64.
# Env:   PORTA_HOME        data directory (default ~/Library/Application Support/Portamento)
#        PORTA_BUILD       where the source and build trees go (default build/ in the checkout)
#        PORTA_SOURCE_OUT  also write the patched source tree to this .tar.xz (for releases)
set -euo pipefail

VER="${1:-11.21}"
MAJOR="${VER%%.*}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${PORTA_BUILD:-$ROOT/build}"  # build trees; porta moves them out of an app bundle
PORTA_HOME="${PORTA_HOME:-$HOME/Library/Application Support/Portamento}"
SRC="$BUILD/src"
TREE="$SRC/wine-$VER-full"
OBJ="$BUILD/wine-$VER-full-x64"
DEST="$PORTA_HOME/runtimes/wine-mods-$VER"
export PATH="/opt/homebrew/opt/bison/bin:$PATH"
# Without this the binaries would only load on the macOS of the SDK they were built with.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
# Background QoS keeps the build off the performance cores; CI sets PORTA_NICE= for full speed.
NICE="${PORTA_NICE-taskpolicy -b}"

mkdir -p "$SRC"
cd "$SRC"
[ -f "wine-$VER.tar.xz" ] || curl -fsSL -o "wine-$VER.tar.xz" "https://dl.winehq.org/wine/source/$MAJOR.x/wine-$VER.tar.xz"
[ -f "wine-staging-$VER.tar.gz" ] || curl -fsSL -o "wine-staging-$VER.tar.gz" "https://github.com/wine-staging/wine-staging/archive/refs/tags/v$VER.tar.gz"

# Start from a fresh tree so the patches always apply to pristine sources.
rm -rf "$TREE" "wine-staging-$VER" "wine-$VER"
tar -xf "wine-$VER.tar.xz"
mv "wine-$VER" "$TREE"
tar -xzf "wine-staging-$VER.tar.gz"
python3 -I "wine-staging-$VER/staging/patchinstall.py" DESTDIR="$TREE" --all > "$SRC/patchinstall.log" 2>&1

cd "$TREE"
for p in winemac-metal-compat kernelbase-steamwebhelper-in-process-gpu ntdll-export-wine-unix-call; do
    patch -p1 --forward < "$ROOT/patches/$p.patch"
done
if [ -n "${PORTA_SOURCE_OUT:-}" ]; then
    tar -C "$SRC" -cJf "$PORTA_SOURCE_OUT" "$(basename "$TREE")"
fi

rm -rf "$OBJ"
mkdir -p "$OBJ"
cd "$OBJ"
$NICE "$TREE/configure" --build=x86_64-apple-darwin --enable-archs=x86_64 \
    --without-x --without-freetype --without-gnutls --without-gstreamer --without-sdl \
    --without-cups --without-opencl --without-pcap --without-pcsclite --without-ffmpeg \
    --without-inotify --without-gettext --without-krb5 --without-netapi --without-usb \
    --without-v4l2 --disable-tests --disable-winebth_sys \
    CC="clang -arch x86_64" OBJC="clang -arch x86_64" > configure.log 2>&1
$NICE make -j"$(sysctl -n hw.ncpu)" dlls/winemac.drv/winemac.so dlls/kernelbase/x86_64-windows/kernelbase.dll \
    dlls/ntdll/x86_64-windows/ntdll.dll > make.log 2>&1

# Gcenx builds use a plain install name and stripped PE files; match them.
install_name_tool -id winemac.so dlls/winemac.drv/winemac.so
x86_64-w64-mingw32-strip dlls/kernelbase/x86_64-windows/kernelbase.dll dlls/ntdll/x86_64-windows/ntdll.dll
nm -gU dlls/winemac.drv/winemac.so | grep -q " _macdrv_functions$"

rm -rf "$DEST"
mkdir -p "$DEST/x86_64-unix" "$DEST/x86_64-windows" "$DEST/doc"
cp dlls/winemac.drv/winemac.so "$DEST/x86_64-unix/"
cp dlls/kernelbase/x86_64-windows/kernelbase.dll dlls/ntdll/x86_64-windows/ntdll.dll "$DEST/x86_64-windows/"
cp "$TREE/COPYING.LIB" "$TREE/LICENSE" "$TREE/AUTHORS" "$DEST/doc/"
cp "$ROOT"/patches/{winemac-metal-compat,kernelbase-steamwebhelper-in-process-gpu,ntdll-export-wine-unix-call}.patch "$DEST/doc/"
echo "$DEST"
