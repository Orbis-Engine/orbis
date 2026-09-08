# Changelog

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
