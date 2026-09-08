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

fetch "$SDK_DIR" mac
fetch "$IOS_SDK_DIR" ios

# Materials are compiled to a C array rather than shipped as an asset, so the
# renderer has no file to find at runtime and no asset bundle to depend on.
GENERATED="orbis_filament/Sources/orbis_filament_native/generated"
mkdir -p "$GENERATED"

# What the materials were last compiled with. A header is otherwise considered
# current whenever it is newer than its .mat, which is true right up until the
# thing that changed was the compiler flags rather than the source — and then
# every material silently stays as it was. That is exactly what happened when
# this moved from -p desktop to -p all: the build succeeded, the app launched,
# and Filament refused the material at runtime with "was not built for mobile".
MATC_FLAGS="-a metal -p all"
MATC_STAMP="$GENERATED/.matc"
MATC_WANT="$FILAMENT_VERSION $MATC_FLAGS"
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
WANT="$FILAMENT_VERSION macos+ios+simulator"

if [ "$(cat "$STAMP" 2>/dev/null || true)" != "$WANT" ]; then
  echo "orbis_filament: packaging Filament as a framework"

  # The dozen the renderer actually needs. The SDK ships thirty.
  #
  # `image` is easy to leave out and hard to notice missing: nothing needs it
  # until something reads a KTX, and then it is not a compile error but a
  # link error naming a symbol nobody wrote — image::Ktx1Bundle, referenced by
  # ktxreader, which is in the list and useless without it.
  LIBS=(
    filament backend filabridge filaflat
    utils geometry smol-v ibl image abseil zstd
    gltfio_core uberarchive uberzlib dracodec meshoptimizer ktxreader
    stb basis_transcoder mikktspace
  )
  # Only macOS has these, and only macOS needs them: they are the runtime
  # loaders for OpenGL and Vulkan, and iOS is Metal or nothing.
  DESKTOP_ONLY=(bluegl bluevk)

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
