#!/bin/bash
# Builds kkbench for x86_64 (the architecture Wine's Vulkan drivers run as)
# and arm64.  Needs glslangValidator and a Vulkan loader + headers; by default
# the LunarG SDK that `porta` keeps in runtimes/.
set -euo pipefail
cd "$(dirname "$0")"
SDK="${VULKAN_SDK:-$(ls -d "${PORTA_HOME:-$HOME/Library/Application Support/Portamento}"/runtimes/vulkan-sdk-*/macOS | tail -n 1)}"
glslangValidator -V --target-env vulkan1.2 --vn draw_vert -o draw_vert.h draw.vert > /dev/null
glslangValidator -V --target-env vulkan1.2 --vn draw_frag -o draw_frag.h draw.frag > /dev/null
for arch in x86_64 arm64; do
    clang -arch $arch -O2 -Wall -I"$SDK/include" -L"$SDK/lib" -Wl,-rpath,"$SDK/lib" \
        -o kkbench-$arch kkbench.c -lvulkan
done
