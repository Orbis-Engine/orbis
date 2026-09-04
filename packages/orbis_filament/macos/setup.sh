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
mkdir -p Classes/generated
for mat in materials/*.mat; do
  name="$(basename "$mat" .mat)"
  header="Classes/generated/${name}_material.h"
  if [ ! -f "$header" ] || [ "$mat" -nt "$header" ]; then
    echo "orbis_filament: compiling $name.mat"
    "$FILAMENT/bin/matc" -a metal -p desktop -o "/tmp/orbis_$name.filamat" "$mat"
    (cd /tmp && xxd -i "orbis_$name.filamat") \
      | sed "s/orbis_${name}_filamat/k${name}Material/g" > "$header"
    rm -f "/tmp/orbis_$name.filamat"
  fi
done

echo "orbis_filament: setup complete"
