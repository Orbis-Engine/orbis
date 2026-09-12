#!/usr/bin/env bash
#
# Stages everything the Linux plugin needs that is too big, too generated or
# too machine-specific to commit -- the Linux-shaped counterpart to
# ../android/setup.sh and ../darwin/setup.sh, which this deliberately mirrors
# wherever the three platforms want the same thing done.
#
#   1. third_party/filament
#        Filament 1.76.0's unpacked Linux release for this machine's
#        architecture: headers once, static libraries under lib/<arch>.
#        Google publishes two, and which one is wanted is decided by
#        `uname -m` rather than by a flag -- "linux" is x86_64 and
#        "arm-linux" is aarch64, and a build that links the wrong one fails
#        at the very last step with a page of architecture mismatches.
#
#   2. ../darwin/orbis_filament/Sources/orbis_filament_native/generated/*.h
#        The renderer's materials, compiled for the `opengl` and `vulkan`
#        backends, and the SMAA/LTC lookup tables the renderer also expects
#        there. Written into the *same* generated/ directory darwin's and
#        android's setup.sh write theirs into, and that is deliberate, not a
#        shortcut: OrbisRendererCore.cpp is one file compiled for every
#        platform, its `#include "generated/foo.h"` lines are unconditional,
#        and C++'s quote-include rule always resolves a relative include
#        against the *including file's own directory* first -- before any -I
#        flag a platform's build could add. So there is exactly one directory
#        any platform's materials can live in for that file to find them.
#
#        This is safe because each setup.sh stamps what it built the
#        materials with (SDK version, matc flags, and which platform asked)
#        in generated/.matc, and recompiles everything whenever that stamp
#        does not match -- which is exactly "another platform's setup.sh ran
#        more recently". The cost is a recompile of a few seconds the first
#        time you switch platforms; the materials are never stale. The trap
#        to know about: after building here, ../darwin/setup.sh must be run
#        again before building for macOS, and it will be, automatically, by
#        the podspec's prepare_command.
#
#        `-p desktop`, not android's `-p mobile`: a Linux machine has a
#        desktop-class GPU (or llvmpipe/lavapipe pretending to be one), and
#        the desktop shader variants are what its drivers want. `matc` is a
#        host tool -- it runs here, not on the target -- so on a Linux host
#        this is the matc out of the release fetched above, and on a macOS
#        host it is the one ../darwin/setup.sh already fetched. Which
#        backends a material carries shaders for is a matc flag, not a
#        property of the machine running it, so either binary produces the
#        same bytes.
#
# Re-running is cheap and idempotent. Run it after a fresh clone and any time
# a .mat file changes. The Flutter build runs it on its own -- see
# CMakeLists.txt -- for the same reason darwin's prepare_command does: so it
# is automatic rather than a step somebody has to remember.
set -euo pipefail
cd "$(dirname "$0")"

FILAMENT_VERSION="v1.76.0"

# packages/orbis_filament/linux -> packages/orbis_filament -> packages ->
# worktree root -> .worktrees -> the project root .cache/ sits beside. The
# same walk ../android/setup.sh does, for the same reason.
here="$(pwd)"
worktree_root="$(cd "$here/../../.." && pwd)"
project_root="$(cd "$worktree_root/../.." 2>/dev/null && pwd || echo "$worktree_root")"

SDK_DIR="third_party"
FILAMENT="$SDK_DIR/filament"
DARWIN_NATIVE="../darwin/orbis_filament/Sources/orbis_filament_native"
GENERATED="$DARWIN_NATIVE/generated"

fail() { echo "orbis_filament/linux/setup.sh: $*" >&2; exit 1; }

# Which release, and which slice of it. Google names the aarch64 Linux
# release "arm-linux" and unpacks it to lib/aarch64; the x86_64 one is plain
# "linux" and unpacks to lib/x86_64. ORBIS_FILAMENT_ARCH overrides the
# machine's own answer, for a cross-build or a container whose architecture
# is not the one you expect.
ARCH="${ORBIS_FILAMENT_ARCH:-$(uname -m)}"
case "$ARCH" in
  aarch64|arm64) FLAVOUR="arm-linux"; LIB_ARCH="aarch64" ;;
  x86_64|amd64)  FLAVOUR="linux";     LIB_ARCH="x86_64"  ;;
  *) fail "no Filament Linux release for architecture '$ARCH'; it publishes" \
       "x86_64 (linux) and aarch64 (arm-linux) only." ;;
esac

# Unpacked once into the project's cache and symlinked from every worktree,
# where that cache exists (true on the development machine); fetched into
# third_party/ otherwise, which is what a container or a CI runner gets.
FILAMENT_LINUX_DIR="${ORBIS_FILAMENT_LINUX_DIR:-$project_root/.cache/filament-1.76.0/$FLAVOUR/filament}"

mkdir -p "$SDK_DIR"
if [ -d "$FILAMENT_LINUX_DIR/include" ]; then
  ln -sfn "$FILAMENT_LINUX_DIR" "$FILAMENT"
  echo "orbis_filament/linux: third_party/filament -> $FILAMENT_LINUX_DIR"
elif [ -d "$FILAMENT/include" ]; then
  echo "orbis_filament/linux: Filament $FILAMENT_VERSION ($FLAVOUR) already present"
else
  echo "orbis_filament/linux: fetching Filament $FILAMENT_VERSION ($FLAVOUR)"
  mkdir -p "$SDK_DIR/fetched"
  curl -fsSL -o "$SDK_DIR/fetched/filament.tgz" \
    "https://github.com/google/filament/releases/download/$FILAMENT_VERSION/filament-$FILAMENT_VERSION-$FLAVOUR.tgz"
  tar xzf "$SDK_DIR/fetched/filament.tgz" -C "$SDK_DIR/fetched"
  rm -f "$SDK_DIR/fetched/filament.tgz"
  rm -f "$FILAMENT"
  ln -sfn "fetched/filament" "$FILAMENT"
fi
[ -d "$FILAMENT/lib/$LIB_ARCH" ] \
  || fail "no $LIB_ARCH libraries at $FILAMENT/lib (it has: $(ls "$FILAMENT/lib" 2>/dev/null))"

# matc, the host tool. On Linux it is the one in the release just staged. On
# macOS -- somebody preparing a Linux build's materials from the development
# machine -- it is the one ../darwin/setup.sh fetched, since the release
# above carries a Linux binary this host cannot run.
case "$(uname -s)" in
  Linux)
    MATC="$FILAMENT/bin/matc"
    [ -x "$MATC" ] || fail "no matc at $MATC"
    ;;
  Darwin)
    MATC="../darwin/third_party/filament-mac/filament/bin/matc"
    [ -x "$MATC" ] || fail "no matc at $MATC (run ../darwin/setup.sh first --" \
      "it is a host tool, and a Linux release's own matc will not run here)"
    ;;
  *)
    fail "no matc for host $(uname -s); add a case for it above"
    ;;
esac

# 2. The SMAA and LTC tables. Not backend-specific -- precomputed constant
#    data, the same bytes on every platform -- so they are safe to share
#    unconditionally, unlike the materials below. Skipped if another
#    platform's setup.sh already fetched them.
mkdir -p "$GENERATED"
SMAA_FROM="https://raw.githubusercontent.com/iryoku/smaa/master/Textures"
for tex in AreaTex SearchTex; do
  if [ ! -s "$GENERATED/$tex.h" ]; then
    echo "orbis_filament/linux: fetching SMAA $tex"
    curl -fsSL -o "$GENERATED/$tex.h" "$SMAA_FROM/$tex.h"
  fi
done
LTC_HEADER="$GENERATED/LtcTables.h"
if [ ! -s "$LTC_HEADER" ]; then
  echo "orbis_filament/linux: fetching the LTC tables"
  LTC_FROM="https://raw.githubusercontent.com/selfshadow/ltc_code/master/fit/results/ltc.js"
  curl -fsSL -o /tmp/orbis_ltc_linux.js "$LTC_FROM"
  {
    echo "// Generated by setup.sh from $LTC_FROM"
    echo "// Heitz, Dupuy, Hill and Neubelt (SIGGRAPH 2016)."
    echo "// See LICENSES/LTC.txt. Do not edit."
    slice() {
      echo "static const float $2[] = {"
      awk -v want="$1" '
        index($0, "var " want " = [") { on = 1; sub(/.*\[/, ""); }
        !on { next }
        { line = $0 }
        index(line, "];") { sub(/\];.*/, "", line); print line; exit }
        { print line }
      ' /tmp/orbis_ltc_linux.js
      echo "};"
    }
    slice g_ltc_1 kLtcMatrix
    slice g_ltc_2 kLtcFresnel
  } > "$LTC_HEADER"
  rm -f /tmp/orbis_ltc_linux.js
fi

# 3. The materials themselves. Vulkan first because that is what
#    orbis::backendCandidates asks for first off Apple, and OpenGL because
#    that is what it falls back to -- a material carrying only one of the two
#    is refused at runtime by whichever backend actually started, which looks
#    exactly like the renderer failing to start for no reason.
ORBIS_MATC_BACKENDS="${ORBIS_MATC_BACKENDS:-vulkan opengl}"
MATC_API=""
for api in ${ORBIS_MATC_BACKENDS//,/ }; do
  case "$api" in
    metal|vulkan|opengl|all) MATC_API="$MATC_API -a $api" ;;
    *)
      fail "ORBIS_MATC_BACKENDS names '$api', which is not one of metal," \
        "vulkan, opengl or all."
      ;;
  esac
done
MATC_PROFILE="${ORBIS_MATC_PROFILE:-desktop}"
MATC_FLAGS="${MATC_API# } -p $MATC_PROFILE"
MATC_STAMP="$GENERATED/.matc"
MATC_WANT="$FILAMENT_VERSION linux $MATC_FLAGS"
STALE=""
if [ "$(cat "$MATC_STAMP" 2>/dev/null || true)" != "$MATC_WANT" ]; then
  STALE=1
fi

BLENDS="opaque transparent fade masked add"
# lit_slim is the nine-sampler surface orbis::Renderer chooses instead of lit
# below Filament's third feature level (see PORTING.md) -- its own five
# packages, not a variant of lit's, mirroring the other two setup.sh exactly.
# A desktop GL below 4.3 is one such machine, so this is not dead weight here.
VARIANTS="lit lit_slim unlit video"

compile() {
  local source="$1" name="$2" blend="${3:-}"
  local header="$GENERATED/${name}_material.h"
  if [ -z "$STALE" ] && [ -f "$header" ] && [ ! "$source" -nt "$header" ]; then
    return
  fi
  echo "orbis_filament/linux: compiling $name"
  local input="$source"
  if [ -n "$blend" ]; then
    input="/tmp/orbis_linux_src_$name.mat"
    sed "s/^\( *blending *: *\)[a-z]*,/\1$blend,/" "$source" > "$input"
  fi
  # shellcheck disable=SC2086 -- the flags are ours and are meant to split.
  "$MATC" $MATC_FLAGS -o "/tmp/orbis_linux_$name.filamat" "$input"
  # The same two declarations `xxd -i` writes and the other two setup.sh
  # rename to, because the renderer names both: the array, and the `_len`
  # beside it that every Material::Builder call passes as the package size.
  # Written with od rather than xxd only because a minimal Linux image has
  # coreutils and need not have xxd -- the output is what matters, and it is
  # the same.
  {
    echo "unsigned char k${name}Material[] = {"
    od -An -v -tx1 "/tmp/orbis_linux_$name.filamat" \
      | sed -e 's/[0-9a-f][0-9a-f]/0x&,/g' -e 's/^ */  /'
    echo "};"
    echo "unsigned int k${name}Material_len = $(wc -c < "/tmp/orbis_linux_$name.filamat" | tr -d ' ');"
  } > "$header"
  rm -f "/tmp/orbis_linux_$name.filamat" "/tmp/orbis_linux_src_$name.mat"
}

for mat in ../darwin/materials/*.mat; do
  name="$(basename "$mat" .mat)"
  case " $VARIANTS " in
    *" $name "*)
      for blend in $BLENDS; do
        compile "$mat" "${name}_${blend}" "$blend"
      done
      ;;
    *)
      compile "$mat" "$name"
      ;;
  esac
done

echo "$MATC_WANT" > "$MATC_STAMP"
echo "orbis_filament/linux: setup complete"
