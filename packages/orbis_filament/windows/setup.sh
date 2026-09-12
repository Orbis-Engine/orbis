#!/usr/bin/env bash
#
# Stages everything the Windows plugin needs that is too big, too generated or
# too machine-specific to commit -- the Windows-shaped counterpart to
# ../android/setup.sh, ../darwin/setup.sh and ../linux/setup.sh, which this
# deliberately mirrors wherever the platforms want the same thing done.
#
#   1. third_party/filament
#        Filament 1.76.0's unpacked Windows release: headers once, static
#        libraries under lib/x86_64/<runtime>, and the host tools under bin/.
#        Google publishes x86_64 only, so there is no architecture to choose
#        the way the Linux script must.
#
#        The one real difference from every other platform's release: this
#        tarball unpacks *flat* -- bin/, include/, lib/ at its root -- where
#        the Linux and Android ones unpack under a filament/ directory of
#        their own. So this extracts it into a directory made here rather
#        than alongside, and third_party/filament means the same thing
#        afterwards as it does in the other scripts.
#
#        Four runtime flavours ship: md and mdd are the dynamic CRT, release
#        and debug; mt and mtd the static one. CMakeLists.txt picks between
#        md and mdd by build configuration, because MSVC's linker refuses to
#        mix them. Nothing here has to choose.
#
#   2. ../darwin/orbis_filament/Sources/orbis_filament_native/generated/*.h
#        The renderer's materials, compiled for the `opengl` and `vulkan`
#        backends, and the SMAA/LTC lookup tables the renderer also expects
#        there. Written into the *same* generated/ directory darwin's,
#        android's and linux's setup.sh write theirs into, and that is
#        deliberate, not a shortcut: OrbisRendererCore.cpp is one file
#        compiled for every platform, its `#include "generated/foo.h"` lines
#        are unconditional, and C++'s quote-include rule always resolves a
#        relative include against the *including file's own directory*
#        first -- before any -I flag a platform's build could add. So there
#        is exactly one directory any platform's materials can live in for
#        that file to find them.
#
#        This is safe because each setup.sh stamps what it built the
#        materials with (SDK version, matc flags, and which platform asked)
#        in generated/.matc, and recompiles everything whenever that stamp
#        does not match -- which is exactly "another platform's setup.sh ran
#        more recently". The cost is a recompile of a few seconds the first
#        time you switch platforms; the materials are never stale.
#
#        `-p desktop`, like Linux and unlike android's `-p mobile`: a Windows
#        machine has a desktop-class GPU and the desktop shader variants are
#        what its drivers want.
#
# Re-running is cheap and idempotent. Run it after a fresh clone and any time
# a .mat file changes. The Flutter build runs it on its own -- see
# CMakeLists.txt -- for the same reason darwin's prepare_command does: so it
# is automatic rather than a step somebody has to remember.
set -euo pipefail
cd "$(dirname "$0")"

FILAMENT_VERSION="v1.76.0"

# packages/orbis_filament/windows -> packages/orbis_filament -> packages ->
# worktree root -> .worktrees -> the project root .cache/ sits beside. The
# same walk the other three scripts do, for the same reason.
here="$(pwd)"
worktree_root="$(cd "$here/../../.." && pwd)"
project_root="$(cd "$worktree_root/../.." 2>/dev/null && pwd || echo "$worktree_root")"

SDK_DIR="third_party"
FILAMENT="$SDK_DIR/filament"
DARWIN_NATIVE="../darwin/orbis_filament/Sources/orbis_filament_native"
GENERATED="$DARWIN_NATIVE/generated"

fail() { echo "orbis_filament/windows/setup.sh: $*" >&2; exit 1; }

# Which host is running this, which decides both how the release can be
# staged and which matc can compile the materials.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) HOST="windows" ;;
  Darwin)               HOST="darwin"  ;;
  Linux)                HOST="linux"   ;;
  *) fail "unknown host $(uname -s); add a case for it above" ;;
esac

# 1. The Windows release.
#
# Symlinked from the project's own cache where that exists and the host can
# make a symlink -- true on the development machine. Not attempted on Windows
# itself: `ln -s` under Git for Windows copies, or fails, depending on
# settings and privileges, and a half-copied 700 MB SDK is a worse failure
# than simply fetching it. So a Windows host always fetches into third_party.
FILAMENT_WINDOWS_DIR="${ORBIS_FILAMENT_WINDOWS_DIR:-$project_root/.cache/filament-1.76.0/windows/filament}"

mkdir -p "$SDK_DIR"
if [ -d "$FILAMENT/include" ]; then
  echo "orbis_filament/windows: Filament $FILAMENT_VERSION already present"
elif [ "$HOST" != "windows" ] && [ -d "$FILAMENT_WINDOWS_DIR/include" ]; then
  ln -sfn "$FILAMENT_WINDOWS_DIR" "$FILAMENT"
  echo "orbis_filament/windows: third_party/filament -> $FILAMENT_WINDOWS_DIR"
else
  echo "orbis_filament/windows: fetching Filament $FILAMENT_VERSION (windows)"
  rm -rf "$SDK_DIR/fetched"
  mkdir -p "$SDK_DIR/fetched"
  curl -fsSL -o "$SDK_DIR/fetched/filament.tgz" \
    "https://github.com/google/filament/releases/download/$FILAMENT_VERSION/filament-$FILAMENT_VERSION-windows.tgz"
  # Into a directory of its own, because this tarball has no top-level
  # filament/ the way the Linux and Android ones do -- see the header.
  mkdir -p "$SDK_DIR/fetched/filament"
  tar xzf "$SDK_DIR/fetched/filament.tgz" -C "$SDK_DIR/fetched/filament"
  rm -f "$SDK_DIR/fetched/filament.tgz"
  rm -rf "$FILAMENT"
  mv "$SDK_DIR/fetched/filament" "$FILAMENT"
  rmdir "$SDK_DIR/fetched" 2>/dev/null || true
fi
[ -d "$FILAMENT/lib/x86_64/md" ] \
  || fail "no x86_64 libraries at $FILAMENT/lib (it has: $(ls "$FILAMENT/lib" 2>/dev/null))"

# matc, the host tool. It runs here, not on the target, so which binary is
# right depends on the host and not on anything Windows-specific. Which
# backends a material carries shaders for is a matc flag rather than a
# property of the machine running it, so every host produces the same bytes.
case "$HOST" in
  windows)
    MATC="$FILAMENT/bin/matc.exe"
    [ -x "$MATC" ] || fail "no matc at $MATC"
    ;;
  darwin)
    # Somebody preparing a Windows build's materials from the development
    # machine: the release staged above carries a Windows binary this host
    # cannot run, so darwin's own matc compiles them.
    MATC="../darwin/third_party/filament-mac/filament/bin/matc"
    [ -x "$MATC" ] || fail "no matc at $MATC (run ../darwin/setup.sh first --" \
      "it is a host tool, and a Windows release's own matc will not run here)"
    ;;
  linux)
    # The same fetch-a-release-for-its-matc-alone that ../android/setup.sh
    # does on this host, and for the same reason: there is no darwin
    # checkout here to borrow one from.
    MATC_DIR="${ORBIS_FILAMENT_MATC_DIR:-$project_root/.cache/filament-1.76.0/linux}"
    if [ ! -x "$MATC_DIR/filament/bin/matc" ]; then
      echo "orbis_filament/windows: fetching Filament $FILAMENT_VERSION (linux, for its matc)"
      mkdir -p "$SDK_DIR/linux-matc"
      curl -fsSL -o "$SDK_DIR/linux-matc/filament.tgz" \
        "https://github.com/google/filament/releases/download/$FILAMENT_VERSION/filament-$FILAMENT_VERSION-linux.tgz"
      tar xzf "$SDK_DIR/linux-matc/filament.tgz" -C "$SDK_DIR/linux-matc"
      rm -f "$SDK_DIR/linux-matc/filament.tgz"
      MATC_DIR="$SDK_DIR/linux-matc"
    fi
    MATC="$MATC_DIR/filament/bin/matc"
    [ -x "$MATC" ] || fail "no matc at $MATC even after fetching"
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
    echo "orbis_filament/windows: fetching SMAA $tex"
    curl -fsSL -o "$GENERATED/$tex.h" "$SMAA_FROM/$tex.h"
  fi
done
LTC_HEADER="$GENERATED/LtcTables.h"
if [ ! -s "$LTC_HEADER" ]; then
  echo "orbis_filament/windows: fetching the LTC tables"
  LTC_FROM="https://raw.githubusercontent.com/selfshadow/ltc_code/master/fit/results/ltc.js"
  curl -fsSL -o /tmp/orbis_ltc_windows.js "$LTC_FROM"
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
      ' /tmp/orbis_ltc_windows.js
      echo "};"
    }
    slice g_ltc_1 kLtcMatrix
    slice g_ltc_2 kLtcFresnel
  } > "$LTC_HEADER"
  rm -f /tmp/orbis_ltc_windows.js
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
MATC_WANT="$FILAMENT_VERSION windows $MATC_FLAGS"
STALE=""
if [ "$(cat "$MATC_STAMP" 2>/dev/null || true)" != "$MATC_WANT" ]; then
  STALE=1
fi

BLENDS="opaque transparent fade masked add"
# lit_slim is the nine-sampler surface orbis::Renderer chooses instead of lit
# below Filament's third feature level (see PORTING.md) -- its own five
# packages, not a variant of lit's, mirroring the other three setup.sh
# exactly. A desktop GL below 4.3 is one such machine, so this is not dead
# weight here.
VARIANTS="lit lit_slim unlit video"

compile() {
  local source="$1" name="$2" blend="${3:-}"
  local header="$GENERATED/${name}_material.h"
  if [ -z "$STALE" ] && [ -f "$header" ] && [ ! "$source" -nt "$header" ]; then
    return
  fi
  echo "orbis_filament/windows: compiling $name"
  local input="$source"
  if [ -n "$blend" ]; then
    input="/tmp/orbis_windows_src_$name.mat"
    sed "s/^\( *blending *: *\)[a-z]*,/\1$blend,/" "$source" > "$input"
  fi
  # shellcheck disable=SC2086 -- the flags are ours and are meant to split.
  "$MATC" $MATC_FLAGS -o "/tmp/orbis_windows_$name.filamat" "$input"
  # The same two declarations `xxd -i` writes and the other setup.sh rename
  # to, because the renderer names both: the array, and the `_len` beside it
  # that every Material::Builder call passes as the package size. Written
  # with od rather than xxd because Git for Windows ships coreutils and need
  # not ship xxd -- the output is what matters, and it is the same.
  {
    echo "unsigned char k${name}Material[] = {"
    od -An -v -tx1 "/tmp/orbis_windows_$name.filamat" \
      | sed -e 's/[0-9a-f][0-9a-f]/0x&,/g' -e 's/^ */  /'
    echo "};"
    echo "unsigned int k${name}Material_len = $(wc -c < "/tmp/orbis_windows_$name.filamat" | tr -d ' ');"
  } > "$header"
  rm -f "/tmp/orbis_windows_$name.filamat" "/tmp/orbis_windows_src_$name.mat"
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
echo "orbis_filament/windows: setup complete"
