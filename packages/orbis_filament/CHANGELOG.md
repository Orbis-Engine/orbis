# Changelog

## 0.16.0

- **SMAA works.** `OrbisEffect.smaaWeights` and `OrbisEffect.smaaBlend` finish
  the chain `smaaEdges` began: edges into a target, coverage weights into
  another, and a blend that reads the picture and the weights and writes the
  screen.

  Measured like for like — the same chain with anti-aliasing off, against the
  same chain with SMAA — hard stairsteps fall by **67%** (564 to 186) while
  only **5.8%** of pixels are touched at all. That is the signature worth
  checking for: it changes edges and leaves everything else exactly as it was.

  `setup.sh` fetches SMAA's two lookup tables rather than committing a
  megabyte of hex. MIT, Jorge Jimenez et al.; notice at `LICENSES/SMAA.txt`.

## 0.15.0

- `OrbisEffect.smaaEdges`, the first of SMAA's three passes: it writes a
  picture of the image's edges, red where a pixel differs from the one on its
  left and green from the one above.

  SMAA works on the finished image like FXAA, but rather than guessing at an
  edge and blurring along it, it works out the *shape* an edge belongs to and
  blends by how much of the pixel that shape covers. No history, so unlike
  temporal it cannot smear; no guess, so unlike FXAA it does not soften what it
  should leave alone.

  Includes the local contrast adaptation, which is the part that stops a plain
  threshold marking every busy region: a pixel beside a much stronger edge
  belongs to that edge's neighbourhood rather than being an edge itself.

  **SMAA is not usable yet — this is one pass of three.** The remaining two are
  blending-weight calculation, which needs the reference implementation's two
  lookup textures, and neighbourhood blending. Adapted from the MIT-licensed
  reference; see `LICENSES/SMAA.txt`.

- An effect chooses its own material and parameters, rather than the renderer
  knowing only about sharpening.

## 0.14.1

- An effect chain no longer loses tone mapping. The pass that writes the
  *frame* now carries the display side of the scene's post-processing — the
  tone mapper and grade, which live together in Filament's `ColorGrading`, plus
  dithering. A pass writing an intermediate target still stays linear, because
  the next effect has to sharpen light rather than a picture of light.

  Measured: with the effect at nought, where the shader is a pass-through, a
  sharpened frame now matches the same scene drawn straight to the screen to
  **0.61/255 mean absolute difference**. It used to come out visibly cooler and
  darker, because linear light was reaching the display unconverted.

  Bloom, depth of field and anti-aliasing are deliberately *not* carried over.
  They read the scene's own depth and history, and an effect view has neither —
  it is one triangle holding a photograph of the scene.

## 0.14.0

- `OrbisPassKind.effect` runs a material over every pixel of what another pass
  drew, rather than a camera over the world. It reads a target, writes a target
  or the frame, and draws one oversized triangle covering the lot — a triangle
  rather than two, because two meeting across the middle make the hardware
  shade that seam twice.

  This is the rails every screen-space effect runs on. SMAA is three of these
  passes and two lookup textures; screen-space GI is more of the same. Which
  effect a pass runs is `OrbisPass.effect`, one of a set the renderer knows,
  because an effect needs a compiled shader and compiling one at runtime is a
  much larger door than this.

- `OrbisEffect.sharpen`, the first of them: a contrast-adaptive sharpen that
  puts back the edge temporal anti-aliasing takes off. Adaptive matters — a
  plain unsharp mask rings every high-contrast edge, so a bright sky against a
  dark roof grows a halo. Weighting by how much room a pixel has between its
  neighbours' darkest and brightest gives flat regions almost nothing.

  **Known limitation:** an effect chain skips tone mapping. The scene pass
  writes linear light into a texture and the effect writes that to the screen
  with post-processing off, so a sharpened frame is cooler and darker than a
  direct one. Opt-in, so nothing regresses — but it wants solving before an
  effect chain becomes the ordinary path.

## 0.13.1

- `setup.sh` can build against a Filament we own. `ORBIS_FILAMENT_SRC` points
  at a built checkout of `Orbis-Engine/orbis-filament` — a fork of
  `google/filament`, Apache 2.0, kept as a fork so its origin stays visible and
  upstream stays mergeable — and the headers, archives and `matc` come from
  there instead of the published tarball.

  Unset by default. Almost nothing wanted here needs a source build: a
  post-process pass, a reflection probe or an area light's shading are written
  in Orbis's own render graph against the same public API, which is how the
  planar reflection was written. What needs the fork is a *backend* — a console
  platform, a driver Filament does not ship — because that lives inside
  Filament and nowhere else.

## 0.13.0

- `OrbisObject.morphWeights` dials in a mesh's shapes. A morph target is a
  second set of positions for the same vertices — a face with its mouth open,
  a wing folded — and the weight says how far between the two the mesh sits.
  The shapes come out of the glTF; this says how much of each.

  Packed end to end with a count per object rather than a fixed width, because
  a face rig has dozens of shapes and a crate has none. Written on every
  publish without comparing first: a weight is the one number here that is
  *expected* to differ every frame, so a memcmp to find that out is work with a
  known answer. More weights than a primitive was built with are trimmed rather
  than passed on — Filament treats that as a precondition, which takes the
  process with it rather than returning an error.

- **Draco and meshopt glTF import already worked**, and now there is a
  reference saying so. Both decoders are linked into the archive Orbis ships
  (`filament::gltfio::DracoMesh`, `meshopt_decodeVertexBuffer`) and reach the
  loader through `gltfio`'s own `ResourceLoader`. Confirmed by rendering the
  same mesh three ways — plain, `gltfpack -cc`, and Draco — with no load error
  and the geometry intact from a file a fortieth the size. No change was
  needed; it was listed as unknown, and unknown is not the same as missing.

## 0.12.0

- A population's distance is measured **flat, and from the cell a member
  stands in** rather than from the member. Sixteen blocks square, which is the
  grain a block game has always culled at.

  Both halves matter. Measured as a straight line, a member's fate depends on
  how high it stands: a canopy fifteen blocks up is further off than the ground
  under it, so it crosses the range first and the tree goes while the hill
  stays. Measured per member, the boundary cuts through anything wider than a
  block: a canopy reaches two blocks past its trunk, so the trunk falls outside
  the range while a leaf falls inside, and a lid of leaves is left hanging over
  nothing. By cell and flat, everything standing in the same square shares one
  verdict, so a world can only lose whole sections and a tree always leaves
  with the ground it grew on.

- `OrbisFade.none` joins `sink` and `shrink`: the member does not change shape
  at all and `range` simply stops whole draws. For a continuous surface there
  is no shape one member can take on its way out that does not tear it, so the
  boundary is left to fog.

- Population draws are given an `InstanceBuffer` of identities. Asking Filament
  for copies *without* one leaves every per-copy uniform slot but the first
  undefined — they hold whatever the renderable drawn before them left there.

- The instanced material takes the camera position as a parameter rather than
  recovering it from the world position it is handed, which depended on those
  same per-copy uniforms.

## 0.11.0

- A population says how its members go when they pass its `range`.
  `OrbisFade.sink` is what happened before and stays the default;
  `OrbisFade.shrink` draws a member in towards its own centre instead.

  Sinking holds a member's bottom edge and draws the rest down to it, which
  puts anything *planted* into the ground it stands on — grass, rocks, a
  roadside. It is wrong for anything *stacked*, because a member's own bottom
  is only the ground if that is where it was standing. A voxel world sank its
  distant cubes to their own bottoms and left them exactly where they were:
  each one a flat plate hanging in mid-air, and every tree a green slab over a
  trunk collapsed too thin to see. That is the "random blocks in the sky" a
  block world showed as soon as the camera moved far enough for the fade to
  reach anything.

  Carried in a spare bit of the population flags, so nothing on the wire
  changed size.

## 0.10.0

- Geometry no object names any more is dropped, rather than kept until the app
  closes. A mesh is read once per path and held, which is right while something
  is drawn from it and a leak the moment nothing is.

  It never showed on a scene of authored assets, where the set of paths is
  fixed for the life of the app. It shows the first time geometry is
  *generated*: a mesh built at runtime has to arrive under a name the renderer
  has not seen to be read at all, so a host that rebuilds one chunk of a block
  world every time somebody digs left every version it had ever built sitting
  on the GPU. Measured on a world of twenty-five chunks: forty-eight assets
  dropped over a few seconds of digging, every one of which would otherwise
  have stayed for the session.

  Swept after the objects rather than inside `recycle`, because a path leaving
  one object and arriving at another within the same publish is a rename and
  not a deletion.

## 0.9.0

- A scene is told what is wrong with *it*, not with every scene loaded since
  the renderer started. A file that could not be read is still remembered —
  re-reading it every frame to find out it is still missing would be four
  hundred failed opens a second — but remembering is not reporting, and
  "the file could not be read" was appearing over a street that had loaded
  perfectly because a different example had failed a minute earlier.
- A frame already on its way to the engine's thread turns back when its
  viewport is disposed, rather than drawing into a texture that has been
  unregistered. Ordering used to be implicit because all of this happened on
  one thread; it is not implicit any more.

## 0.8.0

- The engine has a thread of its own, and the application no longer stops
  while a model loads. Everything Filament does — every frame, every scene,
  every model read from disk — used to happen on the main thread, so half a
  second of reading and uploading was half a second with no cursor, no menus
  and no repaint. That is what "the scene takes a moment to load" was. A
  `Thread` rather than a queue, because Filament adopts the thread that
  creates the engine and a serial queue promises only that its blocks do not
  overlap, not that they run on the same thread.
- `setScene` answers when the scene is in rather than when it is asked for.
  Dart still waits; the thread the call arrived on does not.
- A model's files are read all at once and handed to the loader, rather than
  opened by it one at a time as it reaches them. The Bistro exterior's
  blocking load goes from 1853 ms to about 540 ms. Two separate things:
  handing them over at all turns four hundred seeks braided into decoding
  into one pass, and reading them concurrently rather than in turn takes that
  pass from 340 ms to about 150 ms — a disk can serve many files at once and
  a loop asks it for one. Read rather than memory-mapped: a mapping looks
  frugal, but every page then arrives as a fault when the decoder touches it,
  which measured 2226 ms — worse than doing nothing at all.
- A model says what its load cost, in the three parts it is made of: reading
  the file, parsing it, and handing its files over. "It takes a few seconds"
  is not something anybody can act on — those are different costs with
  different fixes, and the first version of this report had the boundaries in
  the wrong places and blamed the parse for two seconds that were not its.
  The parse is 20 ms.

## 0.7.1

- An object drawn without a material no longer leaves two samplers unbound.
  The defaults were set from a second, hand-written list of the maps a lit
  surface has, and the blend maps were added to the other one — so a material
  that never went through the map loop, which is what an object with no
  material or an unreadable mesh gets, declared two samplers nobody bound.
  Filament reports that on every draw, which came to a few hundred lines a
  second in the editor. There is one list now, so the two cannot disagree.

## 0.7.0

- A model's files are handed to the loader rather than left for it to open.
  Opening them itself is deprecated and says so once per resource — four
  hundred lines for one scene, which buries whatever the log was for. They
  are memory-mapped rather than read: the alternative holds every resource at
  once, because all of them must be handed over before the load begins, and
  for the largest scene here that is three hundred and fifty megabytes of
  memory the system cannot reclaim. A mapping is backed by the file, so the
  cost is the pages the decoder is touching.
- A file whose name is percent-encoded in the glTF is now found. The URI was
  used as a path unchanged, so a texture called `brick wall.png` was looked
  for under `brick%20wall.png` and reported missing — which is the one kind
  of wrong that sounds authoritative.

## 0.6.0

- A material can carry a second surface and choose between them per pixel,
  which is what ground needs: a field that becomes a path, or cobbles going
  under grass, is not one material, and the alternatives are a seam where two
  meshes meet or a texture painted for that one patch of world. Three modes,
  on `OrbisMaterial.blendMode` — `linear` fades everywhere, `masked` follows a
  mask, and `maskedDepth` reads the same mask as a height, so the low ground
  fills first and a stone stays stone until it is buried. `blendAmount`,
  `blendSharpness`, `blendBaseColourMap`, `blendMaskMap` and a `blendTiling`
  of its own, so the second surface can sit at a different scale from the
  first.
- The second surface takes the first one's relief with it. Where it covers,
  the base normal map is damped by the same amount, so grass grown over
  cobbles does not show the cobbles bumping through it.

## 0.5.0

- A model whose files are missing says so. The resource loader reports
  success whether or not a texture opened, so a scene could lose all four
  hundred of its images and still load "fine", drawing untextured with
  nothing anywhere explaining why. The files a model names are now checked
  before the load and the count comes back through `onSceneNotes`.

## 0.4.0

- A shadow distance of zero no longer blacks out the scene. The cascade
  splits fell back to a hundred metres when it was unset while `shadowFar`
  stayed at zero, so the two described different distances and every surface
  sampled as shadowed — a sun at 100,000 lux lit nothing. Both now use the
  same fallback.
- Anisotropic filtering on the renderer's own textures. Ground seen at a
  glancing angle is most of what a camera at head height sees, and a mipmap
  chain alone either crawls or turns to mud a few metres out.

## 0.3.0

- Textures load asynchronously. `loadResources` decoded every image before it
  returned, so a scene with four hundred of them stopped the application dead
  for seconds on geometry that was ready almost at once. The frame loop now
  nudges Filament along instead, and a scene appears immediately with its
  textures arriving over the following frames.

## 0.2.3

- A `.gltf` finds its textures again. The resource loader was given the
  directory holding the file where Filament wants the file itself — it takes
  the last component off to get the directory, so a scene at
  `assets/bistro/Bistro.gltf` looked in `assets/Textures` and found none of
  its four hundred images. Every `.gltf` with external textures was affected;
  `.glb` was not, because it carries its own.

## 0.2.2

- `cpuMilliseconds` reports what a frame costs to *drive*, beside the
  existing `gpuMilliseconds` for what it costs to draw. Read from timings
  Filament already keeps, so it is free to collect.
- Fixes the frame-cost report, which divided elapsed time by a hard-coded
  sixty — halving the figure whenever the dump was asked for at frame
  thirty — and averaged in engine startup and first-frame shader
  compilation.

## 0.2.1

- Presentation sits behind an `OrbisSurface` interface rather than being
  written into the renderer. No behaviour change on either Apple platform;
  it is what a third platform needs in order to exist.

## 0.2.0

- Renders on iOS. Both Apple platforms share one implementation under
  `darwin/`: the same Filament, the same Metal backend, the same
  CVPixelBuffer handed to Flutter's texture registry.
- `setup.sh` fetches the iOS SDK as well and packages a three-slice
  xcframework — macOS, iOS device, iOS simulator.
- Materials are compiled with `-p all` rather than `-p desktop`, so one
  compiled material serves both platforms.

## 0.1.0

- First cut of `orbis_filament`. Pre-alpha: everything is subject to change.
