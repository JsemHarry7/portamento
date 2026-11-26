<p align="center"><img src="app/icon/Portamento-icon-512.png" width="128" alt="Portamento icon"></p>

# Portamento

Run Windows games on Apple Silicon Macs, without CrossOver. Portamento sets up
Wine, picks a graphics translation layer (Direct3D → Metal), and keeps each game
in its own Wine prefix. It comes in two halves:

- **`porta`**: a command line tool (one Python file, no dependencies) that does
  all the work: downloading runtimes, creating prefixes, launching programs,
  running smoke tests.
- **Portamento.app**: a native SwiftUI front end over `porta`, with a game
  library, per-game launch modes and settings, and a status page. In English,
  and in Czech on a Mac set to Czech.

> **Status: experimental.** It's a personal project that works on the
> author's machine (M5 MacBook Pro, macOS 27). BeamNG.drive runs through Steam
> on D3D11 at 50–60 fps. Expect rough edges.

## Requirements

- Apple Silicon Mac with Rosetta 2 (`porta setup` installs it if missing)
- macOS 26 or later: the app, and the KosmicKrisp Vulkan driver (Metal 4)
- Python 3 (comes with the Xcode Command Line Tools)

## Install

**The app:** download `Portamento-<version>.zip` from the [releases](../../releases)
(the `app-…` ones), unzip it and move `Portamento.app` to Applications. It isn't
signed with an Apple developer ID, so macOS refuses to open it the first time:
open it once, then click **Open Anyway** in System Settings → Privacy & Security
(or run `xattr -dr com.apple.quarantine /Applications/Portamento.app`). On first
start it downloads what it needs, with `porta` bundled inside.

**From source**, with the `porta` command line tool:

```sh
git clone https://github.com/JsemHarry7/portamento.git
cd portamento
./porta setup                                   # downloads everything, no compiling
ln -s "$PWD/porta" /opt/homebrew/bin/porta      # or anywhere else on your PATH
scripts/build-app.sh && open build/Portamento.app   # optional: the app (needs the Xcode CLT)
```

`porta setup` downloads Gcenx's Wine builds, DXMT and DXVK from their own
releases, and Portamento's own runtimes from this repository's
[releases](../../releases). With `porta setup --build` it builds those from
source instead (see [Building the runtimes](#building-the-runtimes)).

Everything lives in `~/Library/Application Support/Portamento` (set
`PORTA_HOME` to move it): `runtimes/`, `prefixes/<name>/` with each prefix's
`porta.json`, `downloads/` and `logs/`.

## Using it

```sh
porta create steam                               # a prefix, on the default Wine and backend
porta create steam-d3d12 --gfx d3dmetal          # one for D3D12 games, with Apple's D3DMetal
porta install steam steam                        # install Steam into it (and make it the prefix's program)
porta run steam                                  # start Steam; installed games show up in the app
porta install mygame ~/Downloads/setup.exe       # run a game's installer; its shortcuts become programs
porta run --hud steam 'C:\path\to\game.exe'      # with Apple's Metal performance HUD
porta set steam gfx dxvk                         # switch the graphics backend
porta set steam vulkan kosmickrisp               # switch the Vulkan driver
porta set steam retina on                        # Windows sees the display's pixels (applies from the next start)
porta override steam Game.exe d3dcompiler_47=native,builtin
porta game steam Wreckfest                       # what the game draws with (D3D11, D3D12, Vulkan...) and its settings
porta game steam Wreckfest metalfx 2             # DXMT: MetalFX enlarges the game's picture 2×
porta game steam Wreckfest fps 60                # DXMT: Metal paces the frames (a divisor of the refresh rate)
porta game steam-d3d12 BeamNG.drive dlss on      # D3DMetal: the game's DLSS runs on MetalFX
porta selftest                                   # D3D9/11/12, Vulkan, OpenGL on every combination
porta list
porta delete mygame                              # stop a prefix and move it to the Trash
```

The app does the same from its File menu and the + button: install Steam, or a
game from its installer (also by opening an `.exe`/`.msi` with Portamento in
Finder), and on first start it runs `porta setup` with a progress view.

Options go before the prefix name (`porta run --hud steam`, not `porta run steam --hud`).

`porta list` shows each prefix's games with the graphics APIs found in their
executables (the DLLs they import, and the D3D11/D3D12/Vulkan DLLs they name for
loading at run time). The app warns about games that only have D3D12, which
only D3DMetal runs. `porta game` settings go into a DXMT config file in the
prefix (`C:\portamento\dxmt.conf`) with a section per executable, so they apply
per game even when Steam starts it; turning MetalFX on or off needs a restart of
the prefix, as DXMT only enables it for a whole process tree. DLSS is the same:
D3DMetal turns it on for the prefix, and then every game in it sees an NVIDIA GPU.

A resolution picked in a game doesn't switch the Mac's display. porta turns on
Wine's `EmulateModeset` in every prefix: the game gets the mode it asks for, and
Wine scales its picture to the screen, with black bars where the shape differs.
Real mode switches put the picture in a corner or at a quarter of the screen.
With Retina (`porta set <prefix> retina on`, or the switch in the app) Windows
sees the display's pixels (3024×1964 on a 14" MacBook Pro) rather than its
points (1512×982). Wine programs read both settings when they start, so porta
writes them into a prefix only when nothing runs in it, and the app restarts a
running prefix when Retina changes.

### What a prefix can use

| Wine (`--wine`) | | |
|---|---|---|
| `cx` (default) | Wine 11.0 built from CodeWeavers' CrossOver 26.3 sources | msync; the fastest here; game controllers through SDL |
| `staging` | Gcenx's Wine 11.21 Staging with Portamento's patched modules | |
| `gptk` | Gcenx's CrossOver-based Wine 7.7 with Apple's D3DMetal 3.0 | current Steam crashes on it; `cx` runs D3DMetal too |

| Graphics (`--gfx`) | |
|---|---|
| `dxmt` (default) | D3D10/11 → Metal ([DXMT](https://github.com/3Shain/dxmt)). Replaces `dxgi.dll`, so D3D12 doesn't work in the same prefix |
| `dxvk` | D3D10/11 → Vulkan ([DXVK-macOS](https://github.com/Gcenx/DXVK-macOS) 1.10) |
| `wined3d` | Wine's own D3D → OpenGL/Vulkan; D3D12 via vkd3d |
| `d3dmetal` | Apple's D3DMetal: D3D12 (incl. DXR) and D3D10/11 on Metal, on the `cx` Wine (or `gptk`). The way to run D3D12-only games |

| Vulkan (`porta set <prefix> vulkan …`) | |
|---|---|
| `moltenvk` (default) | MoltenVK, bundled with the Wine builds |
| `kosmickrisp` | Mesa's KosmicKrisp, built for x86_64; has features MoltenVK lacks (e.g. `drawIndirectCount`) |

## How it works

Wine runs x86_64 under Rosetta 2. A runtime for a Wine and backend combination
is an APFS clone of that Wine with the backend's DLLs copied over Wine's own,
so it takes no extra disk space. A few things needed patches; they are in
[`patches/`](patches):

- **winemac-metal-compat**: DXMT and D3DMetal expect CrossOver's Mac driver
  interface (an exported `macdrv_functions` table and its window data layout).
  This is a separate implementation of it for upstream Wine.
- **kernelbase-steamwebhelper-in-process-gpu**: Wine's Mac driver doesn't show
  GDI drawing from another process, so Steam's Chromium UI stayed black. This
  starts `steamwebhelper.exe` with `--in-process-gpu`.
- **ntdll-export-wine-unix-call**: exports `__wine_unix_call` for D3DMetal's PE modules.
- **winemac-fullscreen-mask-retina**: the black bars around a fullscreen game
  whose picture doesn't fill the screen were placed in pixels where Cocoa wants
  points, so in Retina mode the bottom of the picture was cut off.
- **winemac-client-surface-rect** (CrossOver's Wine): the game's Metal view got
  its size from a rounded DPI rather than from the exact scaled rectangle,
  leaving a white strip next to a scaled picture. Upstream Wine already does it
  this way.
- **mesa-kosmickrisp-fill-mode-non-solid**: wireframe polygon mode for
  KosmicKrisp, which BeamNG's Vulkan renderer requires.
- **mesa-kosmickrisp-hoist-indirect-count**: KosmicKrisp emulates
  `vkCmdDrawIndirectCount` with a small compute pass that zeroes the draws past
  the GPU-side count. In 26.3 that pass ended and restarted the render pass
  around it, so the attachments were stored and loaded again each time (95 times
  a frame in BeamNG). The patch encodes those passes into a separate Metal
  command buffer that runs just before the render pass. BeamNG: ~28 → ~35 fps
  in the same spot.
- **mesa-wsi-metal-drawable-count**: a swap chain of more than 3 images (BeamNG
  asks for 4) made `CAMetalLayer` throw and kill the game; the layer now gets at
  most 3 drawables. KosmicKrisp is built from Mesa 26.3, as 26.2 kept the
  drawables of swap chains that were recreated, so games ran out of them and
  stalled at a few fps.

## Repository layout

| | |
|---|---|
| `porta` | the CLI |
| `app/` | the SwiftUI app (SwiftPM, builds without Xcode via `scripts/build-app.sh`) |
| `patches/` | patches to Wine and Mesa |
| `scripts/` | builds of the runtimes, the app, and release packaging |
| `tests/` | Windows smoke tests for `porta selftest` (`tests/build.sh`, needs mingw-w64) |
| `.github/workflows/` | CI, and the workflows that build the runtimes and the app for releases |

## Building the runtimes

`porta setup --build` runs these instead of downloading their results. They
need Homebrew packages, listed at the top of each script:

- `scripts/build-wine-mods.sh`: the three patched Wine Staging modules
- `scripts/build-crossover-wine.sh`: Wine from the CrossOver sources
- `scripts/build-kosmickrisp.sh`: KosmicKrisp for x86_64 (native shader tools first, then a cross build)
- `tests/build.sh`: the smoke tests

The [Runtimes workflow](.github/workflows/runtimes.yml) runs the same
scripts on GitHub's macOS runners and publishes the results, with their exact
patched sources, as a `runtimes-N` release. `porta` downloads the release named
in `RUNTIME_RELEASE` and checks each archive against its `SHA256SUMS`.

## D3DMetal and the Game Porting Toolkit

D3DMetal is Apple's, under Apple's license, which doesn't allow
redistributing it. Portamento doesn't ship it: the `gptk` Wine is downloaded
from [Gcenx's Game Porting Toolkit builds](https://github.com/Gcenx/game-porting-toolkit),
and a `d3dmetal` prefix on the `cx` Wine uses the D3DMetal that comes with it.
For a newer one, download the Game Porting Toolkit from
[Apple](https://developer.apple.com/games/game-porting-toolkit/) and import it:

```sh
porta import-gptk ~/Downloads/Evaluation_environment_for_Windows_games_4.0_beta_3.dmg
```

`d3dmetal` prefixes then use the newest one from their next start. D3DMetal's
unix modules (`d3d12.so`, `dxgi.so`, ...) are all the same library,
`libd3dshared.dylib`, and porta links them to one copy of it: as separate
copies, each is loaded with its own state, and D3DMetal crashes on the first
call that crosses from one to another.

D3DMetal also runs DLSS on MetalFX (`nvngx-on-metalfx`). Games load NVIDIA's NGX
as `nvngx.dll`/`_nvngx.dll` from the folder in
`HKLM\Software\NVIDIA Corporation\Global\NGXCore\FullPath`, so porta puts it
there under those names, in `system32`, and turns off NGX's check for NVIDIA's
signature (`EnableSignatureOverride`). `porta game ... dlss on` then sets
`D3DM_ENABLE_METALFX`, which makes D3DMetal show an NVIDIA GPU.

## License

Portamento's own code (`porta`, the app, scripts and tests) is under the [MIT license](LICENSE).
The patches in `patches/` are changes to Wine (LGPL-2.1-or-later) and Mesa (MIT)
and are under those projects' licenses. Built runtimes are under the license
of the project they come from; see each release.

Built on the work of [Wine](https://www.winehq.org), [CodeWeavers](https://www.codeweavers.com/crossover/source),
[Gcenx](https://github.com/Gcenx), [DXMT](https://github.com/3Shain/dxmt),
[DXVK](https://github.com/doitsujin/dxvk), [Mesa](https://mesa3d.org) and
[MoltenVK](https://github.com/KhronosGroup/MoltenVK).
