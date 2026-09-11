#!/bin/bash
# Builds the renderer as plain C++ with no Objective-C in it, and two C
# programs on top of it: the C ABI's test and a headless host.
#
# The point is what is left out. The core, the C ABI, the portable half of
# the platform layer and the plain C++ helpers are compiled with
# ORBIS_PLATFORM_PORTABLE — the set of files a Linux, Android or Windows
# build takes. OrbisPlatformApple.mm, OrbisSurfaceApple.mm and the
# Objective-C wrapper are not compiled at all, and the two programs include
# one header, orbis_renderer.h. The frameworks on the link line are
# Filament's: its Metal and OpenGL backends are what need them on a Mac.
#
#   build.sh            builds both into ./build
#   build.sh test       and runs the ABI's test
set -euo pipefail
cd "$(dirname "$0")"

DARWIN=../../darwin
SRC="$DARWIN/orbis_filament/Sources/orbis_filament_native"
SDK="${ORBIS_FILAMENT_SDK:-$DARWIN/third_party/filament-mac/filament}"
OUT="${ORBIS_BUILD_DIR:-build}"
mkdir -p "$OUT"

# Every plain C++ file beside the renderer, whatever it is called: a helper
# added later (a new post effect, say) is picked up rather than forgotten.
objects=()
for source in "$SRC"/*.cpp; do
  name="$(basename "$source" .cpp)"
  clang++ -std=c++17 -O2 -DORBIS_PLATFORM_PORTABLE \
    -Wall -Wno-deprecated-declarations -Wno-unused-private-field \
    -I "$SDK/include" -I "$SRC" -I "$SRC/include" \
    -c "$source" -o "$OUT/$name.o"
  objects+=("$OUT/$name.o")
done

LIBS=(filament backend filabridge filaflat utils geometry smol-v ibl image
      abseil zstd filament-iblprefilter gltfio_core uberarchive uberzlib
      dracodec meshoptimizer ktxreader stb basis_transcoder mikktspace
      bluegl bluevk)
archives=()
for lib in "${LIBS[@]}"; do archives+=("$SDK/lib/arm64/lib$lib.a"); done
FRAMEWORKS=(-framework Cocoa -framework Metal -framework QuartzCore
            -framework CoreVideo -framework IOSurface -framework OpenGL)

for program in orbis_renderer_test orbis_headless; do
  # C99 and pedantic, so anything C++ in the header is an error here.
  clang -std=c99 -Wall -Wextra -Werror -pedantic -I "$SRC/include" \
    -c "$program.c" -o "$OUT/$program.o"
  clang++ "$OUT/$program.o" "${objects[@]}" "${archives[@]}" \
    "${FRAMEWORKS[@]}" -o "$OUT/$program"
done
echo "built $OUT/orbis_renderer_test and $OUT/orbis_headless"

if [ "${1:-}" = "test" ]; then
  "$OUT/orbis_renderer_test"
fi
