# Changelog

## 0.3.0

- Meshes are indexed with thirty-two bits rather than sixteen. `Triangles.indices`
  is a `Uint32List`, and the glb accessor writes `componentType` 5125. **This is
  a breaking change for anything reading `indices` as a `Uint16List`.**

  Sixteen bits is enough for every mesh anybody authors by hand, and then
  something generates one. An unsigned short wraps at 65,536 and says nothing
  about it: the file writes, a loader reads it, the bounds come back right, and
  the mesh draws nothing, because every triangle past the wrap names the wrong
  corners.

  Always thirty-two now, rather than narrowing when a mesh happens to fit — two
  bytes an index is worth less than a second code path only exercised by small
  meshes, and therefore only ever correct for those.

## 0.2.0

- `boundsOfGltf` reads the size out of a `.gltf`, as `boundsOfGlb` already did
  for the container. The two are the same document with the buffers in
  different places and neither is read — the minimum and maximum are in the
  document itself. A `.gltf` beside its textures is how most model libraries
  publish, so leaving it out meant the commonest kind of imported model was
  the one that could not say how big it was, and was framed, picked and
  outlined as a two-metre cube.

## 0.1.0

- First cut of `orbis_mesh`. Pre-alpha: everything is subject to change.
