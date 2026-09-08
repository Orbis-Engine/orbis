#!/bin/bash
# Cooks a folder of KTX2 textures down to a size budget, with mipmaps.
#
# The same idea as an importer's "max size" and "generate mipmaps" settings,
# and for the same two reasons.
#
# **Mipmaps.** A texture without them is minified by point-sampling whatever
# texel the maths lands on, which shimmers when the camera moves and reads
# every full-resolution texel to draw a surface twelve pixels across. The
# Bistro's four hundred and five textures have exactly one level each.
#
# **Size.** These are Basis textures, transcoded to a GPU format every time
# they are loaded — twenty-nine milliseconds for one 2048 square on this
# machine, and four hundred and five of them at once is the two and a half
# seconds a scene takes to finish arriving. That work is per texel, so halving
# the side is four times less of it; a mip chain puts a third back, which
# still leaves three times less.
#
# Cooked once and kept. This is slow — a few seconds a texture — and is meant
# to be run when the assets change, not when the application starts.
#
# Usage: cook_textures.sh <folder> [max dimension, default 1024]
set -uo pipefail
cd "$(dirname "$0")/.."

MOST="${2:-1024}"
BASISU="$PWD/third_party/filament-mac/filament/bin/basisu"

[ -x "$BASISU" ] || { echo "no basisu at $BASISU — run setup.sh first"; exit 1; }
[ -d "${1:?usage: cook_textures.sh <folder> [max dimension]}" ] || {
  echo "no such folder: $1"
  exit 1
}

# Absolute, all of them. The unpacker writes into whatever directory it is
# run from and has no say in where, so this works in a scratch directory —
# and a relative path means something else once you are standing there.
FOLDER=$(cd "$1" && pwd)
COOKED="$(dirname "$FOLDER")/$(basename "$FOLDER").cooked"
mkdir -p "$COOKED"

shopt -s nullglob
sources=("$FOLDER"/*.ktx2)
[ ${#sources[@]} -gt 0 ] || { echo "no .ktx2 in $FOLDER"; exit 1; }

echo "cooking ${#sources[@]} textures to at most ${MOST}px, into $COOKED"
cooked=0
skipped=0
failed=0

for source in "${sources[@]}"; do
  name=$(basename "$source")
  out="$COOKED/$name"

  # Resumable: this takes twenty minutes on the Bistro, and a run that has to
  # start from the beginning again is a run nobody does twice.
  if [ -s "$out" ] && [ "$out" -nt "$source" ]; then
    skipped=$((skipped + 1))
    continue
  fi

  work=$(mktemp -d)
  (
    cd "$work" || exit 1
    # Unpacks to every format it knows, which is slower than asking for one —
    # but the numeric codes for "just RGBA" differ between builds of this
    # tool, and a cook that silently picks a sixteen-bit format because a
    # number moved is worse than a cook that takes longer.
    "$BASISU" -unpack -file "$source" > /dev/null 2>&1
  )

  # The faithful one: full eight-bit colour with its alpha, rather than one of
  # the GPU formats it also writes.
  png=$(ls "$work"/*_rgba_RGBA32_level_0_*.png 2>/dev/null | head -1)
  [ -n "$png" ] || png=$(ls "$work"/*_rgb_RGBA32_level_0_*.png 2>/dev/null | head -1)

  if [ -z "$png" ]; then
    echo "  ! could not unpack $name"
    failed=$((failed + 1))
    rm -r -f "$work"
    continue
  fi

  # Colour maps carry sRGB; everything else is a measurement — a normal, a
  # roughness, an occlusion — and encoding one as though it were colour bends
  # every value it holds. Taken from the name, which is how these are named.
  linear="-linear"
  case "$name" in
    *BaseColor*|*Basecolor*|*baseColor*|*Albedo*|*Emissive*|*Diffuse*) linear="" ;;
  esac

  if "$BASISU" -uastc -mipmap $linear -resample "$MOST" "$MOST" -ktx2 \
      -file "$png" -output_file "$out" > /dev/null 2>&1; then
    cooked=$((cooked + 1))
  else
    echo "  ! could not encode $name"
    failed=$((failed + 1))
  fi
  rm -r -f "$work"

  if [ $(((cooked + skipped) % 25)) -eq 0 ]; then
    echo "  $((cooked + skipped)) of ${#sources[@]}"
  fi
done

echo "cooked $cooked, already there $skipped, failed $failed"
echo "to use them, put $COOKED where $FOLDER is"
[ "$failed" -eq 0 ]
