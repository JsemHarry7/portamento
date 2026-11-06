#!/bin/bash
# Build CodeWeavers' open-source Wine (from the CrossOver source release) as an
# x86_64 runtime for porta. It is the Wine that Apple's D3DMetal is made for, and
# it brings msync.
#
# Third-party libraries (freetype, gnutls, vulkan, ...) aren't built here: Wine
# is linked against the x86_64 copies in Gcenx's wine-staging build, with headers
# from Homebrew. They aren't installed with it either; `porta setup` clones them
# into the runtime's lib/ from the staging Wine.
#
# Usage: scripts/build-crossover-wine.sh [crossover-version]    (default: 26.3.0)
# Needs: Xcode CLT, Homebrew bison, freetype, gnutls and mingw-w64, and Gcenx's
#        wine-staging (a finished `porta setup`, or PORTA_DEPS).
# Env:   PORTA_HOME        data directory (default ~/Library/Application Support/Portamento)
#        PORTA_DEPS        directory with the x86_64 libraries (default: the staging Wine's lib/)
#        PORTA_SOURCE_OUT  also write the patched source tree to this .tar.xz (for releases)
set -euo pipefail

VER="${1:-26.3.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORTA_HOME="${PORTA_HOME:-$HOME/Library/Application Support/Portamento}"
SRC="$ROOT/build/src/crossover-$VER"
OBJ="$ROOT/build/crossover-$VER-x64"
DEST="$PORTA_HOME/runtimes/wine-cx-$VER"
TARBALL="$PORTA_HOME/downloads/crossover-sources-$VER.tar.gz"
# configure splits LDFLAGS on spaces, so reach the libraries through a link without any
LIBS="$ROOT/build/deps-x64"
mkdir -p "$ROOT/build"
ln -sfn "${PORTA_DEPS:-$PORTA_HOME/runtimes/wine-11.21-staging/lib}" "$LIBS"
[ -f "$LIBS/libfreetype.6.dylib" ] || { echo "no x86_64 libraries in $LIBS, run porta setup first" >&2; exit 1; }
export PATH="/opt/homebrew/opt/bison/bin:$PATH"
# Without this the binaries would only load on the macOS of the SDK they were built with.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
# Background QoS keeps the build off the performance cores; CI sets PORTA_NICE= for full speed.
NICE="${PORTA_NICE-taskpolicy -b}"

mkdir -p "$(dirname "$TARBALL")"
[ -f "$TARBALL" ] || curl -fsSL -o "$TARBALL" "https://media.codeweavers.com/pub/crossover/source/crossover-sources-$VER.tar.gz"
rm -rf "$SRC"
mkdir -p "$SRC"
tar -xzf "$TARBALL" -C "$SRC" sources/wine
# Steam's web UI is black without this one, the other patches are for upstream Wine only
(cd "$SRC/sources/wine" && patch -p1 --forward < "$ROOT/patches/kernelbase-steamwebhelper-in-process-gpu.patch")
if [ -n "${PORTA_SOURCE_OUT:-}" ]; then
    tar -C "$SRC/sources" -cJf "$PORTA_SOURCE_OUT" wine
fi

rm -rf "$OBJ"
mkdir -p "$OBJ"
cd "$OBJ"
$NICE "$SRC/sources/wine/configure" --build=x86_64-apple-darwin --enable-archs=i386,x86_64 \
    --disable-tests --disable-winebth_sys --without-x --without-gstreamer --without-cups \
    --without-krb5 --without-netapi --without-gettext --without-opencl --without-pcap \
    --without-pcsclite --without-usb --without-v4l2 --without-ffmpeg \
    CC="clang -arch x86_64" OBJC="clang -arch x86_64" LDFLAGS="-L$LIBS" \
    FREETYPE_CFLAGS="-I/opt/homebrew/include/freetype2" FREETYPE_LIBS="-L$LIBS -lfreetype" \
    GNUTLS_CFLAGS="-I/opt/homebrew/opt/gnutls/include -I/opt/homebrew/opt/nettle/include -I/opt/homebrew/opt/libtasn1/include -I/opt/homebrew/opt/p11-kit/include/p11-kit-1" \
    GNUTLS_LIBS="-L$LIBS -lgnutls" > configure.log 2>&1

# The bundled libraries have bare install names, which configure turns into
# garbage sonames; use the names they are shipped under.
sed -i '' -E \
    -e 's|^#define SONAME_LIBFREETYPE .*|#define SONAME_LIBFREETYPE "libfreetype.6.dylib"|' \
    -e 's|^#define SONAME_LIBGNUTLS .*|#define SONAME_LIBGNUTLS "libgnutls.30.dylib"|' \
    -e 's|^#define SONAME_LIBVULKAN .*|#define SONAME_LIBVULKAN "libvulkan.1.dylib"|' include/config.h

# sfnt2fon runs during the build and links freetype by its bare install name, which
# dyld can't resolve (and SIP strips DYLD_* from make), so point it at the real file.
$NICE make -j"$(sysctl -n hw.ncpu)" tools/sfnt2fon/sfnt2fon > make.log 2>&1
install_name_tool -change libfreetype.dylib "$LIBS/libfreetype.6.dylib" tools/sfnt2fon/sfnt2fon
$NICE make -j"$(sysctl -n hw.ncpu)" >> make.log 2>&1

rm -rf "$OBJ/install" "$DEST.tmp"
make install DESTDIR="$OBJ/install" > install.log 2>&1
mv "$OBJ/install/usr/local" "$DEST.tmp"

# Unix modules find the bundled libraries in lib/, like the Gcenx builds do.
for so in "$DEST.tmp"/lib/wine/x86_64-unix/*.so; do
    install_name_tool -add_rpath @loader_path/../../ "$so" 2>/dev/null || true
done
# Anything linked directly against a bundled library (wineserver, winebus.so
# use libinotify) records its bare install name; make those @rpath-relative.
find "$DEST.tmp/bin" "$DEST.tmp/lib/wine/x86_64-unix" -type f | while read -r f; do
    file "$f" | grep -q Mach-O || continue
    for dep in $(otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -vE '^(/|@)'); do
        install_name_tool -change "$dep" "@rpath/$dep" "$f"
    done
    case "$f" in */bin/*) install_name_tool -add_rpath @executable_path/../lib "$f" 2>/dev/null || true;; esac
done
mkdir -p "$DEST.tmp/share/doc/wine"
cp "$SRC/sources/wine/COPYING.LIB" "$SRC/sources/wine/LICENSE" "$SRC/sources/wine/AUTHORS" \
    "$ROOT/patches/kernelbase-steamwebhelper-in-process-gpu.patch" "$DEST.tmp/share/doc/wine/"
# This Wine reaches Vulkan through the loader, which needs a manifest to find
# MoltenVK (one of the libraries porta setup clones in).
mkdir -p "$DEST.tmp/share/vulkan/icd.d"
cat > "$DEST.tmp/share/vulkan/icd.d/MoltenVK_icd.json" <<'EOF'
{
    "file_format_version": "1.0.0",
    "ICD": {
        "library_path": "../../../lib/libMoltenVK.dylib",
        "api_version": "1.4.0",
        "is_portability_driver": false
    }
}
EOF

rm -rf "$DEST"
mv "$DEST.tmp" "$DEST"
echo "$DEST"
