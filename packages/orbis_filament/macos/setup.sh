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
FILAMENT="$SDK_DIR/filament"

if [ ! -d "$FILAMENT/lib" ]; then
  echo "orbis_filament: fetching Filament $FILAMENT_VERSION"
  mkdir -p "$SDK_DIR"
  curl -fsSL -o "$SDK_DIR/filament.tgz" \
    "https://github.com/google/filament/releases/download/$FILAMENT_VERSION/filament-$FILAMENT_VERSION-mac.tgz"
  tar xzf "$SDK_DIR/filament.tgz" -C "$SDK_DIR"
  rm -f "$SDK_DIR/filament.tgz"
else
  echo "orbis_filament: Filament $FILAMENT_VERSION already present"
fi

# Materials are compiled to a C array rather than shipped as an asset, so the
# renderer has no file to find at runtime and no asset bundle to depend on.
GENERATED="orbis_filament/Sources/orbis_filament_native/generated"
mkdir -p "$GENERATED"
for mat in materials/*.mat; do
  name="$(basename "$mat" .mat)"
  header="$GENERATED/${name}_material.h"
  if [ ! -f "$header" ] || [ "$mat" -nt "$header" ]; then
    echo "orbis_filament: compiling $name.mat"
    "$FILAMENT/bin/matc" -a metal -p desktop -o "/tmp/orbis_$name.filamat" "$mat"
    (cd /tmp && xxd -i "orbis_$name.filamat") \
      | sed "s/orbis_${name}_filamat/k${name}Material/g" > "$header"
    rm -f "/tmp/orbis_$name.filamat"
  fi
done

# One framework out of the SDK's own archives.
#
# Swift Package Manager has no way to say "these twenty static libraries and
# that include directory": what it takes is a binary target, which is an
# xcframework. So the archives are merged into one and packaged with the
# headers beside them — done here, where the network is allowed, because a
# Swift package plugin runs sandboxed and could never fetch this itself.
XCFRAMEWORK="orbis_filament/third_party/Filament.xcframework"
if [ ! -d "$XCFRAMEWORK" ]; then
  echo "orbis_filament: packaging Filament as a framework"

  # The dozen the renderer actually needs, in the order the podspec lists
  # them. The SDK ships thirty.
  LIBS=(
    filament backend bluegl bluevk filabridge filaflat
    utils geometry smol-v ibl abseil zstd
    gltfio_core uberarchive uberzlib dracodec meshoptimizer ktxreader
    stb basis_transcoder mikktspace
  )

  merged="$(mktemp -d)/libOrbisFilament.a"
  archives=()
  for name in "${LIBS[@]}"; do
    archives+=("$FILAMENT/lib/arm64/lib${name}.a")
  done
  # Duplicate members across archives are expected — several of these ship the
  # same third-party object — and are not worth a warning apiece.
  libtool -static -o "$merged" "${archives[@]}" 2> /dev/null

  mkdir -p "$(dirname "$XCFRAMEWORK")"
  xcodebuild -create-xcframework \
    -library "$merged" -headers "$FILAMENT/include" \
    -output "$XCFRAMEWORK" > /dev/null
fi

echo "orbis_filament: setup complete"
