# Patches

| Patch | Applies to | Used by | License |
|---|---|---|---|
| `winemac-metal-compat.patch` | Wine 11.21 + Staging | `scripts/build-wine-mods.sh` | LGPL-2.1-or-later, like Wine |
| `kernelbase-steamwebhelper-in-process-gpu.patch` | Wine 11.21 + Staging, CrossOver 26.3 Wine | `build-wine-mods.sh`, `build-crossover-wine.sh` | LGPL-2.1-or-later, like Wine |
| `ntdll-export-wine-unix-call.patch` | Wine 11.21 + Staging | `build-wine-mods.sh` | LGPL-2.1-or-later, like Wine |
| `mesa-kosmickrisp-fill-mode-non-solid.patch` | Mesa 26.3.0-rc3 | `scripts/build-kosmickrisp.sh` | MIT, like Mesa |
| `mesa-wsi-metal-drawable-count.patch` | Mesa 26.3.0-rc3 | `scripts/build-kosmickrisp.sh` | MIT, like Mesa |

They apply with `patch -p1` from the top of the source tree. What each one is
for is in the main [README](../README.md#how-it-works).

The Mesa patches were written with an AI assistant and are labelled
`Generated-by: LLM`, as [Mesa's policy](https://docs.mesa3d.org/submittingpatches.html#expectations-on-contributors)
asks; they carry no code comments or descriptions of their own for the same
reason. Anyone sending one upstream has to do that themselves, in their own
words.
