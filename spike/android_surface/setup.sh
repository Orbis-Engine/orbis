#!/usr/bin/env bash
#
# Stages everything the Android spike needs that is too big, too generated or
# too machine-specific to commit:
#
#   1. filament_surface/android/third_party/filament
#        A symlink to the unpacked Filament 1.76.0 Android release. The release
#        carries include/ and static libs for all four Android ABIs; CMake reads
#        both straight out of it.
#
#   2. filament_surface/android/src/main/cpp/generated/unlit_colour.filamat.h
#        The spike's material, compiled by the *host* matc out of the macOS
#        Filament release and turned into a byte array the .so embeds. matc is
#        an x86_64/arm64 macOS binary; there is no Android build of it, so
#        materials are always compiled on the build machine and shipped as data.
#
# Re-running is cheap and idempotent. Run it after a fresh clone and any time
# unlit_colour.mat changes.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# spike/android_surface -> spike -> worktree root -> .worktrees -> project root
project_root="$(cd "$here/../../../.." && pwd)"

filament_android="$project_root/.cache/filament-1.76.0/android-native/filament"
matc="$project_root/orbis/packages/orbis_filament/darwin/third_party/filament-mac/filament/bin/matc"

third_party="$here/filament_surface/android/third_party"
generated="$here/filament_surface/android/src/main/cpp/generated"
materials="$here/filament_surface/android/src/main/materials"

fail() { echo "setup.sh: $*" >&2; exit 1; }

[ -d "$filament_android/include" ] || fail "no Filament Android release at $filament_android"
[ -d "$filament_android/lib/arm64-v8a" ] || fail "no arm64-v8a libs at $filament_android/lib"
[ -x "$matc" ] || fail "no matc at $matc"

# 1. Point third_party at the release. A symlink, not a copy: the release is
#    ~1.5 GB of static libs across four ABIs and nothing here ever writes to it.
mkdir -p "$third_party"
ln -sfn "$filament_android" "$third_party/filament"
echo "setup.sh: third_party/filament -> $filament_android"

# 2. Compile the material.
#
#    -a opengl -a vulkan  : both backends the spike tries, in one .filamat. The
#                           runtime picks the variant matching the engine's
#                           backend, so one file serves an OpenGL ES run and a
#                           Vulkan run with no rebuild.
#    -p mobile            : mobile shader variants only. Desktop variants would
#                           roughly double the package for shaders no phone runs.
#    -O                   : optimise (default, stated for the record).
mkdir -p "$generated"
"$matc" -a opengl -a vulkan -p mobile -o "$generated/unlit_colour.filamat" \
    "$materials/unlit_colour.mat"
echo "setup.sh: matc -> generated/unlit_colour.filamat ($(wc -c < "$generated/unlit_colour.filamat" | tr -d ' ') bytes)"

# 3. Wrap it as a C header. The alternative is an Android asset read back
#    through AAssetManager, which means threading a jobject AssetManager down
#    to the renderer for one 30 kB blob. Embedding keeps the native side free of
#    any Java dependency beyond the Surface itself, which is what the real
#    plugin will want too.
(
    cd "$generated"
    xxd -i -n kUnlitColourFilamat unlit_colour.filamat > unlit_colour.filamat.h
)
echo "setup.sh: generated/unlit_colour.filamat.h written"

echo "setup.sh: done"
