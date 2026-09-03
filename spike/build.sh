#!/bin/bash
# Builds and runs the Filament -> CVPixelBuffer spike.
# Expects the Filament SDK at third_party/filament-mac (see spike/README.md).
set -euo pipefail
cd "$(dirname "$0")"
F=../third_party/filament-mac/filament

"$F/bin/matc" -a metal -p desktop -o lit.filamat lit.mat

clang++ -std=c++17 -ObjC++ -fobjc-arc -O2 \
  -I"$F/include" cube_to_pixelbuffer.mm -L"$F/lib/arm64" \
  -lfilament -lbackend -lbluegl -lbluevk -lfilabridge -lfilaflat -lutils \
  -lgeometry -lsmol-v -libl -labseil -lzstd \
  -framework Metal -framework MetalKit -framework CoreVideo -framework CoreGraphics \
  -framework ImageIO -framework Foundation -framework QuartzCore -framework IOSurface \
  -framework CoreFoundation -framework AppKit -framework OpenGL \
  -o spike

./spike
