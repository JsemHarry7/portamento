#!/bin/bash
# Build Mesa's KosmicKrisp (Vulkan on Metal) for x86_64, so Wine running under
# Rosetta can load it. LunarG's SDK only ships it for arm64, and MoltenVK lacks
# features games need (BeamNG's Vulkan renderer requires drawIndirectCount).
#
# Two passes: a native arm64 build of the shader tools Mesa runs while building
# (mesa_clc, kk_clc, kosmicomp, vtn_bindgen2, which need LLVM), then a cross
# build of the driver itself that uses those tools.
#
# Usage: scripts/build-kosmickrisp.sh [mesa-version]    (default: 26.2.6)
# Needs: Xcode CLT and Homebrew meson, ninja, pkgconf, bison, llvm,
#        spirv-llvm-translator, spirv-tools, glslang, libclc.
# Env:   PORTA_HOME        data directory (default ~/Library/Application Support/Portamento)
#        PORTA_SOURCE_OUT  also write the patched source tree to this .tar.xz (for releases)
set -euo pipefail

VER="${1:-26.2.6}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORTA_HOME="${PORTA_HOME:-$HOME/Library/Application Support/Portamento}"
BUILD="$ROOT/build"
SRC="$BUILD/src/mesa-$VER"
TARBALL="$PORTA_HOME/downloads/mesa-$VER.tar.xz"
DEST="$PORTA_HOME/runtimes/kosmickrisp-$VER"
# KosmicKrisp is built on Metal 4, which needs macOS 26.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-26.0}"
# Builds run at background QoS so they stay off the performance cores and out of
# the way of whatever else is running; CI sets PORTA_NICE= to run at full speed.
NICE="${PORTA_NICE-taskpolicy -b}"
# meson setup is chatty: keep its output in a log and show the end when it fails
setup() {
    local log="$1"; shift
    $NICE meson setup "$@" > "$log" 2>&1 || { tail -n 60 "$log" >&2; exit 1; }
}
COMMON=(-Dbuildtype=release -Dplatforms=macos -Dvulkan-drivers=kosmickrisp -Dgallium-drivers=
        -Dglx=disabled -Degl=disabled -Dgles1=disabled -Dgles2=disabled -Dopengl=false
        -Dxmlconfig=disabled -Dzstd=disabled -Dvalgrind=disabled -Dlibunwind=disabled)

mkdir -p "$(dirname "$TARBALL")" "$BUILD/src"
[ -f "$TARBALL" ] || curl -fsSL -o "$TARBALL" "https://archive.mesa3d.org/mesa-$VER.tar.xz"
rm -rf "$SRC"
tar -xf "$TARBALL" -C "$BUILD/src"
# wireframe polygon mode (fillModeNonSolid), required by BeamNG's Vulkan renderer
(cd "$SRC" && patch -p1 --forward < "$ROOT/patches/mesa-kosmickrisp-fill-mode-non-solid.patch")
if [ -n "${PORTA_SOURCE_OUT:-}" ]; then
    tar -C "$BUILD/src" -cJf "$PORTA_SOURCE_OUT" "mesa-$VER"
fi
[ -x "$BUILD/venv-mesa/bin/python3" ] || python3 -m venv "$BUILD/venv-mesa"
"$BUILD/venv-mesa/bin/pip" install -q mako pyyaml packaging

# Native tools
export PATH="$BUILD/venv-mesa/bin:/opt/homebrew/opt/llvm/bin:/opt/homebrew/opt/bison/bin:/opt/homebrew/bin:$PATH"
export PKG_CONFIG_PATH="/opt/homebrew/opt/libclc/share/pkgconfig:/opt/homebrew/opt/spirv-llvm-translator/lib/pkgconfig:/opt/homebrew/lib/pkgconfig"
rm -rf "$BUILD/mesa-native" "$BUILD/mesa-tools"
setup "$BUILD/mesa-native-setup.log" "$BUILD/mesa-native" "$SRC" "${COMMON[@]}" -Dllvm=enabled \
    -Dmesa-clc=enabled -Dinstall-mesa-clc=true -Dprecomp-compiler=enabled -Dinstall-precomp-compiler=true
TOOLS=(src/compiler/clc/mesa_clc src/kosmickrisp/clc/kk_clc src/kosmickrisp/kosmicomp src/compiler/spirv/vtn_bindgen2)
$NICE ninja -C "$BUILD/mesa-native" "${TOOLS[@]}"
mkdir -p "$BUILD/mesa-tools"
for t in "${TOOLS[@]}"; do ln -sf "$BUILD/mesa-native/$t" "$BUILD/mesa-tools/"; done

# The x86_64 driver
export PATH="$BUILD/mesa-tools:$PATH"
unset PKG_CONFIG_PATH
rm -rf "$BUILD/mesa-x86_64"
COMPAT="$ROOT/scripts/mesa-compat"  # endian.h shim, see the header
setup "$BUILD/mesa-x86_64-setup.log" "$BUILD/mesa-x86_64" "$SRC" --cross-file "$ROOT/scripts/mesa-x86_64.cross" \
    "${COMMON[@]}" -Dllvm=disabled -Dmesa-clc=system -Dprecomp-compiler=system \
    -Dc_args="-I$COMPAT" -Dcpp_args="-I$COMPAT" -Dobjc_args="-I$COMPAT" -Dobjcpp_args="-I$COMPAT"
$NICE ninja -C "$BUILD/mesa-x86_64"

rm -rf "$DEST"
mkdir -p "$DEST/lib" "$DEST/share/vulkan/icd.d" "$DEST/share/doc/mesa"
cp "$BUILD/mesa-x86_64/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.dylib" "$DEST/lib/"
cp "$SRC/docs/license.rst" "$ROOT/patches/mesa-kosmickrisp-fill-mode-non-solid.patch" "$DEST/share/doc/mesa/"
cat > "$DEST/share/vulkan/icd.d/kosmickrisp_icd.x86_64.json" <<EOF
{
    "ICD": {
        "api_version": "1.4.0",
        "library_path": "../../../lib/libvulkan_kosmickrisp.dylib"
    },
    "file_format_version": "1.0.0"
}
EOF
echo "$DEST"
