#!/bin/bash
# The same two C programs as build.sh, built for Linux instead of macOS.
#
# Why a second script rather than a branch inside the first: the two differ in
# every line that matters — a different SDK layout (lib/<arch> rather than
# lib/arm64), no Apple frameworks, and X11 and the C++ runtime on the link
# line instead — and a build script that is half #ifdef is a build script
# nobody can read. What is deliberately identical is the set of sources:
# ORBIS_PLATFORM_PORTABLE, every *.cpp beside the renderer, no Objective-C.
# That is the point of the portable core, and this is what proves it.
#
# What this is for. An Apple GPU is tile-based: it works out which surface
# wins a tile before shading any of it, so overdraw costs almost nothing and
# a depth prepass has nothing left to save. An immediate-mode GPU shades
# every layer it is handed, in the order it is handed them. Mesa's lavapipe
# (Vulkan) and llvmpipe (GL) are immediate-mode rasterisers on the CPU, so a
# Linux container running them is a machine where overdraw costs real,
# measurable time — which is the machine a prepass has to be measured on.
#
#   ORBIS_FILAMENT_SDK   a Linux Filament release (the directory holding
#                        include/ and lib/), required
#   ORBIS_FILAMENT_ARCH  which slice of lib/ to link (default: uname -m)
#   ORBIS_BUILD_DIR      where the objects and programs go (default: build)
#
# The materials must have been compiled for the backends this will run —
# ORBIS_MATC_BACKENDS="vulkan opengl" ./darwin/setup.sh — or Filament starts,
# refuses every material as built for another backend, and draws nothing.
set -euo pipefail
cd "$(dirname "$0")"

DARWIN=../../darwin
SRC="$DARWIN/orbis_filament/Sources/orbis_filament_native"
SDK="${ORBIS_FILAMENT_SDK:?ORBIS_FILAMENT_SDK must point at a Linux Filament release}"
ARCH="${ORBIS_FILAMENT_ARCH:-$(uname -m)}"
OUT="${ORBIS_BUILD_DIR:-build}"
mkdir -p "$OUT"

if [ ! -d "$SDK/lib/$ARCH" ]; then
  echo "no $ARCH slice in $SDK/lib; it has: $(ls "$SDK/lib" 2>/dev/null)"
  exit 1
fi

# Every plain C++ file beside the renderer, exactly as build.sh takes them.
# libc++, not libstdc++. Filament's Linux release is built against LLVM's
# standard library, so its archives refer to symbols in namespace std::__1 —
# std::__1::__next_prime and the rest of the hash-table machinery. Linked
# against GNU's libstdc++ instead, every one of those is undefined, and the
# error names template instantiations a page long rather than the one-word
# cause. Both halves have to agree, so this is a compile flag as well as a
# link one.
STDLIB=(-stdlib=libc++)

objects=()
for source in "$SRC"/*.cpp; do
  name="$(basename "$source" .cpp)"
  clang++ -std=c++17 -O2 -DORBIS_PLATFORM_PORTABLE "${STDLIB[@]}" \
    -Wall -Wno-deprecated-declarations -Wno-unused-private-field \
    -I "$SDK/include" -I "$SRC" -I "$SRC/include" \
    -c "$source" -o "$OUT/$name.o"
  objects+=("$OUT/$name.o")
done

# The same list build.sh links, minus the Apple-only pieces. bluegl and bluevk
# are the runtime loaders for GL and Vulkan and are what make a software ICD
# usable without linking against a driver at build time.
LIBS=(filament backend filabridge filaflat utils geometry smol-v ibl image
      abseil zstd filament-iblprefilter gltfio_core uberarchive uberzlib
      dracodec meshoptimizer ktxreader stb basis_transcoder mikktspace
      bluegl bluevk)
archives=()
for lib in "${LIBS[@]}"; do archives+=("$SDK/lib/$ARCH/lib$lib.a"); done

for program in orbis_renderer_test orbis_headless; do
  # C99 and pedantic, so anything C++ in the header is an error here too.
  clang -std=c99 -Wall -Wextra -Werror -pedantic -I "$SRC/include" \
    -c "$program.c" -o "$OUT/$program.o"
  # --start-group: Filament's archives refer to each other both ways round,
  # and ld on Linux reads an archive once unless told otherwise. Without this
  # the link fails on symbols that are plainly present in the libraries.
  clang++ "$OUT/$program.o" "${objects[@]}" "${STDLIB[@]}" \
    -Wl,--start-group "${archives[@]}" -Wl,--end-group \
    -lpthread -ldl -lm -o "$OUT/$program"
done
echo "built $OUT/orbis_renderer_test and $OUT/orbis_headless"

if [ "${1:-}" = "test" ]; then
  "$OUT/orbis_renderer_test"
fi
