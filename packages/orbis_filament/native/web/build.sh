#!/bin/bash
# Builds the renderer core for the web: the same portable sources
# native/headless/build.sh compiles, plus this directory's web surface, as
# WebAssembly with Emscripten, linked against a Filament built for wasm.
#
# The point is the same as native/headless/build.sh's: what is left out.
# OrbisPlatformApple.mm, OrbisSurfaceApple.mm and the Objective-C wrapper are
# never compiled — the *.cpp glob already skips them — and now
# OrbisSurfaceHeadless.cpp is skipped too, deliberately: OrbisSurfaceWeb.cpp
# beside this script provides the same two factory functions
# (OrbisCreateHeadlessSurface, OrbisCreateWindowSurface) for what "a window"
# means in a browser, and both files defining them would not link.
#
# Two things this build needed that native/headless/build.sh did not, found
# by testing rather than guessed — see native/web/README.md's "What did not
# work at first":
#   - -fwasm-exceptions on every translation unit AND the final link.
#     Filament's own wasm archives throw utils::Panic without it (Renderer::
#     initWithWidth's try/catch depends on catching that), compiled with no
#     exception flag at all; proven by linking a throw from an unflagged
#     object file against a -fwasm-exceptions catch site before trusting it
#     with the real renderer.
#   - Every generated material header needs an opengl variant: WebGL 2 is
#     Filament's OpenGL backend, and matc's blob carries only the backends
#     it was told to (packages/orbis_filament/darwin/setup.sh,
#     ORBIS_MATC_BACKENDS). This script now compiles them itself, with the
#     matc belonging to the Filament it links — see the materials section
#     below for why that is not merely tidier.
#
#   build.sh                 builds ./build and host/orbis_renderer.{js,wasm}
#
# Needs, both required:
#   EMSDK                    an activated Emscripten SDK (see README.md)
#   ORBIS_FILAMENT_WASM_SRC  a checkout of Orbis-Engine/orbis-filament built
#                            for wasm: ./build.sh -p wasm release there first
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v emcc >/dev/null 2>&1; then
  echo "native/web/build.sh: no emcc on PATH. Activate emsdk first:" >&2
  echo "  source \"\$EMSDK_DIR/emsdk_env.sh\"" >&2
  exit 1
fi
if [ -z "${ORBIS_FILAMENT_WASM_SRC:-}" ]; then
  echo "native/web/build.sh: ORBIS_FILAMENT_WASM_SRC is not set. Point it at" >&2
  echo "  a checkout of Orbis-Engine/orbis-filament built with" >&2
  echo "  ./build.sh -p wasm release (see README.md)." >&2
  exit 1
fi
FIL_SRC="$ORBIS_FILAMENT_WASM_SRC"
FIL_OUT="$FIL_SRC/out/cmake-wasm-release"
if [ ! -d "$FIL_OUT" ]; then
  echo "native/web/build.sh: no $FIL_OUT; build Filament for wasm first." >&2
  exit 1
fi

DARWIN=../../darwin
SRC="$DARWIN/orbis_filament/Sources/orbis_filament_native"
OUT="${ORBIS_BUILD_DIR:-build}"
mkdir -p "$OUT" host

# ---- The materials, compiled by *this* Filament's own matc ----
#
# Done here rather than left to the reader, and that is the whole fix for a
# defect this build shipped with: matc and the engine are one interface. The
# blob carries a variant table and the engine indexes it by variant key, with
# no version between them that would catch a mismatch — see darwin/setup.sh's
# ORBIS_MATC comment for the mechanism. Compiling with the release tarball's
# matc while linking the fork's archives below drew every scene with ambient
# light alone: the sun, and every other directional light, contributed
# nothing, silently, because this fork strips the DIR variant bit the
# tarball's matc had compiled the sun into.
#
# So the materials now come from the same tree the archives come from. A
# build that links this Filament can no longer be handed materials made by
# another one, which is what the README used to ask for by hand.
#
# This runs darwin/setup.sh, so it wants a Mac: that script also packages the
# Apple xcframework. The web build has only ever been run on one, and the
# README's recipe already called it by hand; if this build is ever wanted on
# Linux, that is the seam to split, not this choice of matc.
MATC=""
for candidate in \
    "$FIL_SRC/out/cmake-release/tools/matc/matc" \
    "$FIL_SRC/out/prebuilt-tools-release/tools/matc/matc"; do
  if [ -x "$candidate" ]; then MATC="$candidate"; break; fi
done
if [ -z "$MATC" ]; then
  echo "native/web/build.sh: no host matc inside $FIL_SRC. Its own" >&2
  echo "  ./build.sh -p wasm release builds one on the way through —" >&2
  echo "  look for out/cmake-release/tools/matc/matc." >&2
  exit 1
fi
echo "native/web/build.sh: compiling materials with $MATC"
ORBIS_MATC="$MATC" ORBIS_MATC_BACKENDS=opengl bash "$DARWIN/setup.sh"

# ---- Headers ----
#
# Not one merged include/ tree: unlike the packaged macOS/iOS releases
# darwin/setup.sh fetches, a source build's headers stay where CMake found
# them. This is the union of every -I flag Filament's own wasm build used
# (out/cmake-wasm-release/compile_commands.json, after `./build.sh -p wasm
# release` there), so anything Filament's public headers themselves reach
# for is covered, not only what OrbisRendererCore.cpp names directly.
INCLUDES=(
  -I "$FIL_SRC/filament/include"
  -I "$FIL_SRC/filament/backend/include"
  -I "$FIL_OUT/filament"
  -I "$FIL_OUT/filament/backend"
  -I "$FIL_SRC/libs/utils/include"
  -I "$FIL_SRC/libs/math/include"
  -I "$FIL_SRC/libs/filabridge/include"
  -I "$FIL_SRC/libs/filaflat/include"
  -I "$FIL_SRC/libs/geometry/include"
  -I "$FIL_SRC/libs/ibl/include"
  -I "$FIL_SRC/libs/image/include"
  -I "$FIL_SRC/libs/iblprefilter/include"
  -I "$FIL_SRC/libs/gltfio/include"
  # gltfio/materials/uberarchive.h is generated at build time (the packed
  # ubershader archive) straight under libs/gltfio/materials, not nested
  # inside an include/ directory the way the plain source headers are.
  -I "$FIL_OUT/libs"
  -I "$FIL_SRC/libs/ktxreader/include"
  -I "$FIL_SRC/third_party/robin-map/tnt/../include"
  -I "$FIL_SRC/third_party/abseil"
)

# ---- The core, the ABI, the portable platform layer and the plain C++
# helpers ----
#
# Every *.cpp beside the renderer, as native/headless/build.sh takes it,
# minus OrbisSurfaceHeadless.cpp (see the header comment above). ORBIS_
# PLATFORM_PORTABLE is what selects OrbisPlatform.cpp's answers over
# OrbisPlatformApple.mm's — the same macro, the same effect, on any non-
# Apple build.
objects=()
for source in "$SRC"/*.cpp; do
  name="$(basename "$source" .cpp)"
  if [ "$name" = "OrbisSurfaceHeadless" ]; then continue; fi
  echo "native/web/build.sh: compiling $name"
  em++ -std=c++17 -O2 -DORBIS_PLATFORM_PORTABLE -fwasm-exceptions \
    -Wall -Wno-deprecated-declarations -Wno-unused-private-field \
    "${INCLUDES[@]}" -I "$SRC" -I "$SRC/include" \
    -c "$source" -o "$OUT/$name.o"
  objects+=("$OUT/$name.o")
done

# This directory's own sources: the web surface and the JS-friendly wrapper.
for name in OrbisSurfaceWeb orbis_web_host; do
  echo "native/web/build.sh: compiling $name"
  em++ -std=c++17 -O2 -DORBIS_PLATFORM_PORTABLE -fwasm-exceptions \
    -Wall "${INCLUDES[@]}" -I "$SRC" -I "$SRC/include" \
    -c "$name.cpp" -o "$OUT/$name.o"
  objects+=("$OUT/$name.o")
done

# ---- Filament's own libraries, built for wasm ----
#
# Named the same as darwin/setup.sh's LIBS, minus bluegl/bluevk (the desktop
# OpenGL/Vulkan loaders PlatformWebGL never needs — Emscripten's own GL
# emulation is the loader here) and smol-v (SPIR-V compression for Metal/
# Vulkan shader variants; WebGL 2 takes GLSL source text, no SPIR-V in this
# build at all). Found by name rather than hand-written paths, because a
# from-source build's layout mirrors the CMake source tree exactly, one
# directory per library, rather than one flat lib/<arch>/ the way a packaged
# release is: finding "lib$name.a" is what stays true if that nesting shifts.
LIB_NAMES=(
  filament backend filabridge filaflat utils geometry ibl image
  filament-iblprefilter gltfio_core uberarchive uberzlib dracodec
  meshoptimizer ktxreader stb basis_transcoder mikktspace math zstd
)
archives=()
for lib in "${LIB_NAMES[@]}"; do
  found="$(find "$FIL_OUT" -name "lib$lib.a" -print -quit)"
  if [ -z "$found" ]; then
    echo "native/web/build.sh: no lib$lib.a under $FIL_OUT" >&2
    exit 1
  fi
  archives+=("$found")
done
# Abseil ships as one archive per component in a from-source build (a
# packaged release merges them; this does not), so every libabsl_*.a rather
# than one name.
while IFS= read -r absl; do archives+=("$absl"); done \
  < <(find "$FIL_OUT" -name "libabsl_*.a" | sort)

# ---- The ABI's own functions, exported by name rather than hand-listed ----
#
# Every orbis_renderer_* identifier orbis_renderer.h mentions, deduplicated:
# picks up a call added to the ABI later without this script needing to know
# its name, the same idea as the *.cpp glob above.
abi_funcs="$(grep -oE 'orbis_renderer_[a-zA-Z_]+' "$SRC/include/orbis_renderer.h" | sort -u)"
exported="_malloc,_free,_orbis_web_create_on_canvas"
for fn in $abi_funcs; do exported="$exported,_$fn"; done

# ---- Link ----
#
# --bind and its Embind runtime are Filament's own filament-js's, for calling
# C++ through generated JS classes; this ABI is plain C, so ccall/cwrap onto
# EXPORTED_FUNCTIONS is enough and the Embind weight is not carried. USE_
# WEBGL2/FULL_ES3/MIN_WEBGL_VERSION/MAX_WEBGL_VERSION are copied from
# web/filament-js/CMakeLists.txt's own LOPTS — the flags Filament's own web
# target links with — so this build's GL entry points match what its
# archives were built expecting.
em++ -fwasm-exceptions -O2 \
  "${objects[@]}" "${archives[@]}" \
  -s ALLOW_MEMORY_GROWTH=1 \
  -s USE_WEBGL2=1 -s FULL_ES3 -s MIN_WEBGL_VERSION=2 -s MAX_WEBGL_VERSION=2 \
  -s ENVIRONMENT=web \
  -s MODULARIZE=1 -s EXPORT_NAME=OrbisRendererModule \
  -s EXPORTED_FUNCTIONS="[$(echo "$exported" | sed "s/\([^,]*\)/'\1'/g")]" \
  -s EXPORTED_RUNTIME_METHODS="['ccall','cwrap','getValue','setValue','UTF8ToString','HEAPU8','HEAP32','HEAPU32','HEAPF32']" \
  -o host/orbis_renderer.js

ls -la host/orbis_renderer.js host/orbis_renderer.wasm
echo "native/web/build.sh: built host/orbis_renderer.js and host/orbis_renderer.wasm"
