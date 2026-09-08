#!/bin/bash
# Fetches the Amazon Lumberyard Bistro, for testing lighting against a scene
# somebody else art-directed.
#
# Why this scene: it is CC BY 4.0, a glTF 2.0 conversion of it exists — the
# ORCA original ships FBX and a Falcor scene file, neither of which the
# renderer reads — and at 2.8 million triangles in the exterior it is also the
# heaviest thing available to measure a frame against. One asset, two jobs.
#
# What it does NOT bring is the lighting. The Falcor scene file carried that,
# and the FBX-to-glTF conversion did not: the file's extensionsUsed lists
# KHR_texture_basisu, KHR_materials_specular and KHR_materials_transmission,
# and no KHR_lights_punctual. Every lantern and string light in the reference
# renders is ours to author — which is the point, since what is being tested
# is this engine's lights rather than another engine's.
#
#   Amazon Lumberyard Bistro, Open Research Content Archive (ORCA)
#   https://developer.nvidia.com/orca/amazon-lumberyard-bistro
#   Amazon Lumberyard, CC BY 4.0
#
# Roughly 700MB. Kept out of git and fetched on demand, like the Filament SDK.
#
# Usage: fetch_bistro.sh [exterior|interior|all]   (default: exterior)
set -euo pipefail
cd "$(dirname "$0")/.."

WANT="${1:-exterior}"
REPO="https://github.com/qian-o/GLTF-Assets"
REF="main"
INTO="assets/bistro"

case "$WANT" in
  exterior) SCENES=(BistroExterior) ;;
  interior) SCENES=(BistroInterior BistroInterior_Wine) ;;
  all) SCENES=(BistroExterior BistroInterior BistroInterior_Wine) ;;
  *) echo "usage: fetch_bistro.sh [exterior|interior|all]"; exit 1 ;;
esac

mkdir -p "$INTO/Textures"

# The .bin files are Git LFS, and only those. A plain download of one gives a
# 130-byte pointer where a 180MB vertex buffer should be, and the glTF then
# fails with a complaint about its buffer rather than about the download — so
# the pointer is read deliberately and resolved through the LFS batch API.
#
# The API rather than the git-lfs client, because that client is not installed
# everywhere and is not on a CI runner by default. This needs only curl.
resolve_lfs() {
  local pointer="$1" oid size
  oid=$(sed -n 's/^oid sha256://p' "$pointer")
  size=$(sed -n 's/^size //p' "$pointer")
  [ -n "$oid" ] && [ -n "$size" ] || return 1
  curl -fsS -X POST "$REPO.git/info/lfs/objects/batch" \
    -H "Accept: application/vnd.git-lfs+json" \
    -H "Content-Type: application/vnd.git-lfs+json" \
    -d "{\"operation\":\"download\",\"transfers\":[\"basic\"],\"objects\":[{\"oid\":\"$oid\",\"size\":$size}]}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["objects"][0]["actions"]["download"]["href"])'
}

# get <path within Bistro/> — skips what is already whole.
get() {
  # Two statements, not one. `local a="$1" b="$dir/$a"` looks like it should
  # work and does not: bash declares every name in a `local` before assigning
  # any of them, so the second reads an `a` that is declared and empty — and
  # under set -u that is a fatal "unbound variable" rather than a wrong path.
  local name="$1"
  local out="$INTO/$name"
  # -a because these are binaries and grep otherwise reports a match on
  # "binary file" instead of answering the question.
  if [ -s "$out" ] && ! head -c 40 "$out" | grep -aq 'git-lfs.github.com'; then
    return
  fi
  mkdir -p "$(dirname "$out")"
  curl -fsSL -o "$out" "$REPO/raw/$REF/Bistro/$name"

  if head -c 40 "$out" | grep -aq 'git-lfs.github.com'; then
    local href
    href=$(resolve_lfs "$out") || { echo "could not resolve LFS for $name"; exit 1; }
    echo "  $name (large, via LFS)"
    curl -fsSL -o "$out" "$href"
  fi
}

echo "orbis: fetching the Bistro ($WANT)"
get LICENSE.txt
get README.md
get san_giuseppe_bridge_4k.hdr

for scene in "${SCENES[@]}"; do
  echo "  $scene"
  get "$scene.gltf"
  get "$scene.bin"
done

# The textures each scene actually names, rather than all 622 of them. The
# exterior and the interior share a good many, and neither uses the lot.
echo "  textures"
for scene in "${SCENES[@]}"; do
  python3 - "$INTO/$scene.gltf" <<'PYTHON' | while read -r texture; do
import json, sys
with open(sys.argv[1]) as f:
    doc = json.load(f)
for image in doc.get('images', []):
    uri = image.get('uri')
    if uri and not uri.startswith('data:'):
        print(uri)
PYTHON
    get "$texture"
  done
done

# The lights, out of the geometry that emits.
#
# The scene has no KHR_lights_punctual — the Falcor scene file carried the
# lighting and the FBX-to-glTF conversion did not bring it. But it does have
# ten emissive materials, and they are exactly the fixtures: the street lamps,
# the awning spotlights, the two shop signs, and the festoon bulbs in six
# colours. Where those meshes are is where the lights go.
#
# Taken from the asset rather than typed in, so it stays right. Getting the
# transform wrong is easy and silent: the root node turns the scene from Z-up
# to Y-up and scales it by 0.016, and ignoring either puts the street lamps at
# heights between minus sixty and plus fifty metres instead of between four
# and seven.
for scene in "${SCENES[@]}"; do
  python3 - "$INTO/$scene.gltf" "$INTO/$scene.lights.json" <<'PYTHON'
import json, sys

doc = json.load(open(sys.argv[1]))
acc, meshes, nodes = doc['accessors'], doc['meshes'], doc['nodes']
root = nodes[doc['scenes'][doc.get('scene', 0)]['nodes'][0]]
scale = root.get('scale', [1, 1, 1])[0]
turn = root.get('rotation', [0, 0, 0, 1])

# Which material means which fixture, by name rather than by index, because an
# index is a property of one conversion and a name is a property of the scene.
def kind_of(name):
    name = (name or '').lower()
    if 'stringlights' in name:
        for colour in ('orange', 'red', 'white', 'pink', 'blue', 'green'):
            if colour in name:
                return colour
    if 'streetlight' in name: return 'street'
    if 'spotlight' in name: return 'spot'
    if 'shopsign' in name: return 'sign'
    return None

kinds = {}
for i, m in enumerate(doc.get('materials', [])):
    k = kind_of(m.get('name'))
    if k and (any(v > 0 for v in m.get('emissiveFactor', [0, 0, 0]))
              or m.get('emissiveTexture')):
        kinds[i] = k

def spin(q, v):
    x, y, z, w = q
    cx, cy, cz = y*v[2]-z*v[1], z*v[0]-x*v[2], x*v[1]-y*v[0]
    dx, dy, dz = y*cz-z*cy, z*cx-x*cz, x*cy-y*cx
    return [v[0]+2*(w*cx+dx), v[1]+2*(w*cy+dy), v[2]+2*(w*cz+dz)]

found = []
for n in nodes:
    mesh = n.get('mesh')
    if mesh is None:
        continue
    for prim in meshes[mesh].get('primitives', []):
        k = kinds.get(prim.get('material'))
        if not k:
            continue
        a = acc[prim['attributes']['POSITION']]
        if 'min' not in a:
            continue
        c = [(a['min'][j] + a['max'][j]) / 2 for j in range(3)]
        s = n.get('scale', [1, 1, 1])
        c = [c[j] * s[j] for j in range(3)]
        if 'rotation' in n:
            c = spin(n['rotation'], c)
        t = n.get('translation', [0, 0, 0])
        c = spin(turn, [c[j] + t[j] for j in range(3)])
        found.append({'kind': k, 'at': [round(c[j] * scale, 3) for j in range(3)]})

json.dump(found, open(sys.argv[2], 'w'), indent=1)
print(f"  {len(found)} light positions -> {sys.argv[2].split('/')[-1]}")
PYTHON
done

echo
echo "orbis: the Bistro is in $INTO"
echo "       Amazon Lumberyard Bistro, ORCA — CC BY 4.0. See $INTO/LICENSE.txt."
