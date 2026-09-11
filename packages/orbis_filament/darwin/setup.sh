#!/bin/bash
# Fetches the Filament SDK and compiles this package's materials.
#
# Runs from the podspec's prepare_command, so `flutter run` needs no manual
# step, and is idempotent so it costs nothing after the first time. Both
# outputs are build artefacts and stay out of git.
set -euo pipefail
cd "$(dirname "$0")"

FILAMENT_VERSION="v1.76.0"
SDK_DIR="third_party/filament-mac"
IOS_SDK_DIR="third_party/filament-ios"
FILAMENT="$SDK_DIR/filament"
IOS_FILAMENT="$IOS_SDK_DIR/filament"

# fetch <directory> <sdk name>
#
# Two SDKs, because they carry different things. The mac one has the host
# tools — matc compiles the materials and only runs here — as well as the
# macOS libraries. The iOS one has only libraries, and ships them as
# xcframeworks rather than as plain archives.
fetch() {
  local into="$1" flavour="$2"
  if [ -d "$into/filament/lib" ]; then
    echo "orbis_filament: Filament $FILAMENT_VERSION ($flavour) already present"
    return
  fi
  echo "orbis_filament: fetching Filament $FILAMENT_VERSION ($flavour)"
  mkdir -p "$into"
  curl -fsSL -o "$into/filament.tgz" \
    "https://github.com/google/filament/releases/download/$FILAMENT_VERSION/filament-$FILAMENT_VERSION-$flavour.tgz"
  tar xzf "$into/filament.tgz" -C "$into"
  rm -f "$into/filament.tgz"
}

# A Filament built here, rather than the release Google publishes.
#
# ORBIS_FILAMENT_SRC points at a checkout of Orbis-Engine/orbis-filament that
# has been built (`./build.sh -p desktop -i release`). Everything downstream —
# headers, archives, matc — comes from `out/release/filament` instead of the
# tarball, and nothing else in this script or the package changes.
#
# Unset by default, deliberately. A source build is twenty minutes and several
# gigabytes, and almost nothing wanted here needs one: a new post-process pass
# or a reflection probe is written in Orbis's own render graph against the same
# public API. What genuinely needs it is a *backend* — a console platform, a
# driver Filament does not ship — because that lives inside Filament and
# nowhere else. So the fork is wired up and the fast path stays the default
# until something actually requires the slow one.
#
# SDK_ID is what the two stamps further down record as the SDK they were made
# from. A release is named by its version. A source build carries the same
# version number however often it is rebuilt, so it is named by what was
# built — matc and every archive, by size and time. Without that, switching to
# a source build, or rebuilding one with a change, kept the framework and the
# materials made from the previous SDK, and nothing said so.
SDK_ID="$FILAMENT_VERSION"
if [ -n "${ORBIS_FILAMENT_SRC:-}" ]; then
  BUILT="$ORBIS_FILAMENT_SRC/out/release/filament"
  if [ ! -d "$BUILT/lib" ]; then
    echo "orbis_filament: ORBIS_FILAMENT_SRC is set but $BUILT/lib is missing."
    echo "  Build it:  cd $ORBIS_FILAMENT_SRC && ./build.sh -p desktop -i release"
    exit 1
  fi
  echo "orbis_filament: using the Filament built at $BUILT"
  mkdir -p "$SDK_DIR"
  rm -rf "${SDK_DIR:?}/filament"
  ln -s "$BUILT" "$SDK_DIR/filament"
  SDK_ID="$FILAMENT_VERSION source $(cd "$BUILT" &&
    stat -f '%N %z %m' bin/matc lib/arm64/*.a | shasum | cut -c1-12)"
  # iOS still comes from the release. A desktop build carries no iOS slices,
  # and pretending otherwise fails at link time rather than here.
  fetch "$IOS_SDK_DIR" ios
else
  # A source build leaves the mac SDK as a link to itself. Back on the
  # release, that link would pass for a fetched SDK, and the source build's
  # archives would be packaged under the release's name.
  if [ -L "$SDK_DIR/filament" ]; then rm "$SDK_DIR/filament"; fi
  fetch "$SDK_DIR" mac
  fetch "$IOS_SDK_DIR" ios
fi

# Materials are compiled to a C array rather than shipped as an asset, so the
# renderer has no file to find at runtime and no asset bundle to depend on.
GENERATED="orbis_filament/Sources/orbis_filament_native/generated"
mkdir -p "$GENERATED"

# SMAA's two lookup tables, fetched rather than committed.
#
# They are a hundred and eighty kilobytes of precomputed data — the area each
# edge shape covers, and the search table that walks along one — and the
# reference implementation already ships them as C arrays with their licence
# at the top. Downloading them keeps a megabyte of hex out of the history and
# keeps the notice attached to the data it belongs to, which vendoring a
# stripped copy would not. Same idea as the Filament SDK above.
#
# MIT, Jorge Jimenez et al. See LICENSES/SMAA.txt.
SMAA_FROM="https://raw.githubusercontent.com/iryoku/smaa/master/Textures"
for tex in AreaTex SearchTex; do
  if [ ! -s "$GENERATED/$tex.h" ]; then
    echo "orbis_filament: fetching SMAA $tex"
    mkdir -p "$GENERATED"
    curl -fsSL -o "$GENERATED/$tex.h" "$SMAA_FROM/$tex.h"
  fi
done


# The linearly transformed cosine tables, fetched rather than committed.
#
# A rectangle of light has no closed-form specular answer. LTC gets one by
# fitting, per roughness and viewing angle, the linear transform that turns a
# clamped cosine lobe into the GGX lobe — so the rectangle is integrated
# against a shape that *does* have a closed form, and the shading of a real
# softbox costs a polygon integral rather than a march.
#
# Two 64x64 RGBA tables: the inverse of that transform, and the pair of terms
# that put the BRDF's shadowing and Fresnel back. Taken from the authors' own
# fit, in the packing their shader reads, so there is no layout to guess at —
# the same reason SMAA's tables are fetched above rather than reconstructed.
#
# Heitz, Dupuy, Hill and Neubelt, "Real-Time Polygonal-Light Shading with
# Linearly Transformed Cosines", ACM TOG (Proc. SIGGRAPH 2016) 35(4).
# See LICENSES/LTC.txt.
LTC_FROM="https://raw.githubusercontent.com/selfshadow/ltc_code/master/fit/results/ltc.js"
LTC_HEADER="$GENERATED/LtcTables.h"
if [ ! -s "$LTC_HEADER" ]; then
  echo "orbis_filament: fetching the LTC tables"
  curl -fsSL -o /tmp/orbis_ltc.js "$LTC_FROM"
  # The file is JavaScript only in its punctuation: two arrays of plain
  # comma-separated floats. Everything between the bracket and the close is
  # already valid as a C initialiser, so the conversion is a slice rather
  # than a parse.
  {
    echo "// Generated by setup.sh from $LTC_FROM"
    echo "// Heitz, Dupuy, Hill and Neubelt (SIGGRAPH 2016)."
    echo "// See LICENSES/LTC.txt. Do not edit."
    # slice <javascript array name> <C array name>
    slice() {
      echo "static const float $2[] = {"
      awk -v want="$1" '
        index($0, "var " want " = [") { on = 1; sub(/.*\[/, ""); }
        !on { next }
        { line = $0 }
        index(line, "];") { sub(/\];.*/, "", line); print line; exit }
        { print line }
      ' /tmp/orbis_ltc.js
      echo "};"
    }
    slice g_ltc_1 kLtcMatrix
    slice g_ltc_2 kLtcFresnel
  } > "$LTC_HEADER"
  rm -f /tmp/orbis_ltc.js
fi


# What the materials were last compiled with. A header is otherwise considered
# current whenever it is newer than its .mat, which is true right up until the
# thing that changed was the compiler flags rather than the source — and then
# every material silently stays as it was. That is exactly what happened when
# this moved from -p desktop to -p all: the build succeeded, the app launched,
# and Filament refused the material at runtime with "was not built for mobile".
#
# Which backends the materials carry shaders for: ORBIS_MATC_BACKENDS, a list
# of metal, vulkan, opengl, or all. Metal alone by default, because it is the
# only one an Apple build can use and every backend added is another copy of
# every shader in the binary. A build for anywhere else names its own —
# "vulkan opengl" for Android or Linux, where OpenGL is the fallback — and
# "all" is every backend matc knows. The list goes into the stamp below with
# the rest of the flags, so changing it recompiles everything.
ORBIS_MATC_BACKENDS="${ORBIS_MATC_BACKENDS:-metal}"
MATC_API=""
for api in ${ORBIS_MATC_BACKENDS//,/ }; do
  case "$api" in
    metal|vulkan|opengl|all) MATC_API="$MATC_API -a $api" ;;
    *)
      echo "orbis_filament: ORBIS_MATC_BACKENDS names '$api', which is not"
      echo "  one of metal, vulkan, opengl or all."
      exit 1
      ;;
  esac
done
# The default comes out as exactly the flags this used before there was a
# choice, so an existing checkout's stamp still matches and nothing rebuilds.
MATC_FLAGS="${MATC_API# } -p all"
MATC_STAMP="$GENERATED/.matc"
MATC_WANT="$SDK_ID $MATC_FLAGS"
STALE=""
if [ "$(cat "$MATC_STAMP" 2>/dev/null || true)" != "$MATC_WANT" ]; then
  STALE=1
fi
# Surfaces are compiled once per blend mode, because blending is fixed
# function state baked into the material and not something an instance can
# override. Everything else about a material is a uniform, so this is the only
# axis that multiplies.
BLENDS="opaque transparent fade masked add"
# Compiled once each; everything else is a uniform. The shadow catcher is
# deliberately not here: its blending is fixed by what it is.
VARIANTS="lit unlit video"

# compile <source .mat> <generated name> [blend]
compile() {
  local source="$1" name="$2" blend="${3:-}"
  local header="$GENERATED/${name}_material.h"
  if [ -z "$STALE" ] && [ -f "$header" ] && [ ! "$source" -nt "$header" ]; then
    return
  fi
  echo "orbis_filament: compiling $name"
  local input="$source"
  if [ -n "$blend" ]; then
    input="/tmp/orbis_src_$name.mat"
    sed "s/^\( *blending *: *\)[a-z]*,/\1$blend,/" "$source" > "$input"
  fi
  # -p all, not -p desktop: the same compiled material is linked into the
  # macOS build and the iOS one, and a desktop-only shader family gives an iOS
  # device nothing it can run. The cost is a larger blob, paid once at build
  # time; the alternative is two sets of headers and an #if choosing between
  # them in the renderer.
  # shellcheck disable=SC2086 — the flags are ours and are meant to split.
  "$FILAMENT/bin/matc" $MATC_FLAGS -o "/tmp/orbis_$name.filamat" "$input"
  (cd /tmp && xxd -i "orbis_$name.filamat") \
    | sed "s/orbis_${name}_filamat/k${name}Material/g" > "$header"
  rm -f "/tmp/orbis_$name.filamat" "/tmp/orbis_src_$name.mat"
}

for mat in materials/*.mat; do
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

# One framework out of the SDKs' own archives.
#
# Swift Package Manager has no way to say "these twenty static libraries and
# that include directory": what it takes is a binary target, which is an
# xcframework. So the archives are merged into one per platform and packaged
# with the headers beside them — done here, where the network is allowed,
# because a Swift package plugin runs sandboxed and could never fetch this
# itself.
#
# Three slices: macOS, an iOS device, and the iOS simulator. The simulator one
# is not a nicety — it is the only slice that can be built and run without a
# signing identity, so it is what makes an iOS change checkable at all.
XCFRAMEWORK="orbis_filament/third_party/Filament.xcframework"
STAMP="orbis_filament/third_party/.filament-version"

LIBS=(
    filament backend filabridge filaflat
    utils geometry smol-v ibl image abseil zstd
    # Prefilters a captured cubemap into the mip chain a reflection samples.
    # On the GPU and in-engine, which is what makes a probe something a scene
    # can capture while it runs rather than something baked by a tool.
    filament-iblprefilter
    gltfio_core uberarchive uberzlib dracodec meshoptimizer ktxreader
    stb basis_transcoder mikktspace
)

# Only macOS has these, and only macOS needs them: they are the runtime
# loaders for OpenGL and Vulkan, and iOS is Metal or nothing.
DESKTOP_ONLY=(bluegl bluevk)

# What the framework was last packaged from — the version *and the list*.
#
# The list is in here for the same reason the material stamp carries its
# compiler flags: a framework is otherwise considered current because it
# exists, which holds right up until the thing that changed was which
# libraries went into it. Then the package is silently the old one and the
# failure arrives as a linker error naming a symbol that is present in the
# SDK and absent from the framework.
WANT="$SDK_ID macos+ios+simulator ${LIBS[*]} ${DESKTOP_ONLY[*]}"

if [ "$(cat "$STAMP" 2>/dev/null || true)" != "$WANT" ]; then
  echo "orbis_filament: packaging Filament as a framework"

  # The dozen the renderer actually needs. The SDK ships thirty.
  #
  # `image` is easy to leave out and hard to notice missing: nothing needs it
  # until something reads a KTX, and then it is not a compile error but a
  # link error naming a symbol nobody wrote — image::Ktx1Bundle, referenced by
  # ktxreader, which is in the list and useless without it.
  # Only macOS has these, and only macOS needs them: they are the runtime
  # loaders for OpenGL and Vulkan, and iOS is Metal or nothing.

  work="$(mktemp -d)"

  # merge <output> <archive>...
  #
  # An array rather than a string of paths, because libtool given a
  # space-separated string in one argument opens nothing, warns to stderr
  # about a file whose name is every path joined together, and exits 0 with
  # an empty archive. The failure then arrives much later as a link error.
  merge() {
    local out="$1"; shift
    libtool -static -o "$out" "$@" 2> /dev/null
  }

  # --- macOS: plain archives, one directory ---
  mac_archives=()
  for name in "${LIBS[@]}" "${DESKTOP_ONLY[@]}"; do
    mac_archives+=("$FILAMENT/lib/arm64/lib${name}.a")
  done
  merge "$work/macos.a" "${mac_archives[@]}"

  # --- iOS: each library is itself an xcframework, so the slice has to be
  # picked out of each one by identifier ---
  ios_slice() {
    local identifier="$1" out="$2"
    local archives=() path
    for name in "${LIBS[@]}"; do
      path="$IOS_FILAMENT/lib/lib${name}.xcframework/$identifier/lib${name}.a"
      if [ ! -f "$path" ]; then
        echo "orbis_filament: no $identifier slice for $name"
        exit 1
      fi
      archives+=("$path")
    done
    merge "$out" "${archives[@]}"
  }
  ios_slice ios-arm64 "$work/ios.a"
  ios_slice ios-arm64_x86_64-simulator "$work/ios-simulator.a"

  # Moved aside rather than deleted: xcodebuild refuses to write over an
  # existing framework, and the temporary directory is the OS's to clean up.
  mkdir -p "$(dirname "$XCFRAMEWORK")"
  if [ -e "$XCFRAMEWORK" ]; then
    # An `&&` chain here would end the script the first time the framework is
    # absent, which is every fresh clone: the test fails, the chain returns
    # non-zero, and set -e takes that as the script failing.
    mv "$XCFRAMEWORK" "$work/superseded.xcframework"
  fi

  xcodebuild -create-xcframework \
    -library "$work/macos.a" -headers "$FILAMENT/include" \
    -library "$work/ios.a" -headers "$IOS_FILAMENT/include" \
    -library "$work/ios-simulator.a" -headers "$IOS_FILAMENT/include" \
    -output "$XCFRAMEWORK" > /dev/null

  # Written last, so an interrupted run rebuilds rather than being trusted.
  echo "$WANT" > "$STAMP"
fi

echo "orbis_filament: setup complete"
