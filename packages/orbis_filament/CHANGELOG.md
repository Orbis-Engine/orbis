# Changelog

## 0.23.0

- **The placeholder cube's bounding box now contains the cube.** Filament's
  `Box` is a centre and a half-extent. The declaration read
  `{{-1,-1,-1},{1,1,1}}`, which is a {min,max} pair written into it, and
  describes a cube centred on (-1,-1,-1) that stops at the origin. The
  geometry spans -1..+1 about the origin, so the box never contained the thing
  it stood for, and the error grew with the object's scale: a floor slab at
  scale 30 declared a box thirty metres from the floor. A caster's world box is
  the only input to the directional shadow camera's fit — `ShadowMap` takes the
  near plane from the casters and the far plane and x-y focus from the
  receivers — so every scene drawing the placeholder cube fitted its shadow map
  to the wrong volume. Reference frames across the gallery move as a result,
  with the clock pinned and the noise floor measured at exactly zero: 2.75% of
  pixels in Batching unbatched, 0.54% in Shadows, 0.49% in A thousand objects
  and 0.23% in Meshes. Panel shadows moves on 69% of its pixels but by a single
  level on almost every one of them, with the frame's mean unchanged to three
  decimal places — that is the dither re-rolling under a shift smaller than one
  quantisation step, not something to see. Nothing is culled differently in any
  of them — every pixel that moves is a shading or shadow change, not an object
  appearing or disappearing — though the box was a culling hazard too, since
  Filament culls from the same box it fits shadows from.

- **What instance batching still costs, measured against a correct baseline.**
  Three thousand crates batched, against the same crates drawn one by one,
  differ by 2.27% of pixels at the default sixty-four members to a chunk, 2.22%
  at eight, and 0.0055% at one — a hundred and six pixels in a 1600x1200 frame,
  every one of them differing by exactly one level, which is the last of the
  float rounding in recovering a chunk's half-extent from the union of its
  members'. Before the box was fixed
  the same three measurements were 2.97%, 2.96% and 2.75%: what survived
  shrinking the group was the unbatched side's wrong box, which is why
  shrinking never disposed of it. What remains is the grouping itself, and it
  behaves as a union of boxes should — a chunk's box is looser along the light
  axis than any member's, so the shadow camera fits a deeper volume and the
  map's texels land differently. It saturates at once: eight members to a chunk
  is already as loose as sixty-four, so no chunk size buys the difference back
  while still batching anything. Batching stays off by default here, but the
  trade is now a named one rather than an open question.

## 0.22.0

- **A rectangular light's shadow now actually falls.** The depth map it drew
  was compared in the wrong units — Filament renders reversed-Z with the far
  plane at infinity, and the projection a camera hands out is neither — and
  the lookup read the map the wrong way up on Metal and Vulkan; either alone
  gave a scene that rendered identically with the panel casting and not. The
  lookup is now percentage-closer soft shadows, so the penumbra comes from the
  panel's real size and the gap it bridges: 12 pixels wide under a one-metre
  panel and 36 under a four-metre one. Filament's own shadow settings are
  exposed alongside it — cascade splits placed by hand, PCSS penumbra scales,
  contact-shadow trace length and steps, and the variance-map options — all
  defaulting to Filament's own values, so no existing scene changes. Shadow
  caching is not reachable through Filament's API and is not attempted.

- **Environment volumes.** `OrbisScene.volumes` takes `OrbisEnvironmentVolume`s
  — a turned box or a sphere, with a blend distance, a priority and a weight —
  whose `OrbisEnvironmentOverrides` change the fog, exposure, sky ambient and
  colour, image-based light intensity and rotation, bloom and colour grade
  within a region, fading smoothly across the blend distance. An override left
  null leaves that setting alone. They are resolved against the camera by a
  pure Dart resolver (`OrbisScene.resolved()`) when the scene is sent, so the
  renderer and the scene message are unchanged: lux blends in log space,
  exposure in stops, rotation the short way round, colours in linear light.

- **Projected decals.** `OrbisScene.decals` takes up to 32 `OrbisDecal`s, each
  a box that throws a picture or a tint onto every lit surface inside it. They
  are painted into base colour, and optionally roughness and metalness, before
  the surface is lit, so they take shadows and highlights like what is under
  them. Each has an angle fade that keeps it off surfaces edge-on to its
  projector, a layer mask and a sort order; a decal past the budget, or a
  picture that cannot be read, is reported rather than dropped.

- **Gaussian splats.** `OrbisSplats` draws a 3D Gaussian splat capture from the
  reference trainer's binary `.ply` or a compact `.splat`, or a cloud made in
  Dart with `OrbisSplats.pack`. Each splat is projected with the EWA
  approximation and drawn as a 3σ ellipse, blended back to front over the solid
  scene and hidden by anything solid in front of it. The sort runs on its own
  thread when the view turns — about 8 ms for a million splats in an optimised
  build. Only a capture's degree-0 colour is used; higher spherical-harmonic
  bands are reported and ignored.

- **Selection outlines.** `OrbisScene.outline` takes an `OrbisOutline`: a set of
  object keys, an active one drawn brighter, colours, a width in pixels, and how
  to draw the parts other objects hide (`OrbisOccluded.shown`, `faint`,
  `dashed` or `hidden`). It follows the silhouette and is drawn over the
  finished frame after tone mapping and anti-aliasing, so its colour is exact
  and it cannot shimmer under temporal anti-aliasing. It costs nothing while
  nothing is outlined.

- **Instance batching, off by default.** With `OrbisScene.batching` on,
  objects sharing a mesh, a material and their shadow and layer flags are
  drawn as instanced renderables Orbis builds itself — up to sixty-four
  members each, sorted by position, every member's transform in the instance
  buffer — while each object keeps its own key, so picking and selection are
  unchanged and moving one rewrites only its slot. It no longer uses
  Filament's engine-wide automatic instancing, so it works on stock Filament,
  where that switch blacks out whole frames. Three thousand crates batched
  take about a fifth of the CPU time and three fifths of the GPU time of the
  same crates drawn one by one: 0.79 ms of CPU down to 0.15, 6.2 ms of GPU
  down to 3.8, and three thousand and three renderables down to fifty-one.
  It is off by default because a batched group that casts shadows still moves
  pixels. With the clock pinned, two runs of the same frame are bit-identical,
  and batched against unbatched 2.97% of pixels differ — 2.6 levels in 255 on
  average, 68 at the worst — all of it along the edges of shadows. With the
  shadow pass off the two frames are identical, which is what places it there.

  Most of that turned out to be a fault on the *unbatched* side rather than in
  the batching, and is fixed in 0.23.0: the placeholder cube declared a
  bounding box that did not contain it, so an unbatched crate's shadows were
  fitted from the wrong volume and the batched path — which works a chunk's box
  out from its members' transforms — was the one that was right. That is why
  shrinking a group to one member never disposed of the difference, and why
  this entry's reasoning from that test was wrong. 0.23.0 carries the
  measurements against a corrected baseline. The frame's stats report how many
  objects were batched and into how many groups. A depth prepass was measured
  and not built: on Apple's tile-based GPUs there is no overdraw cost for it to
  remove.

- **God rays and screen distortion.** `OrbisScene.godRays` adds shafts of light
  from the scene's own directional light, by Mitchell's screen-space light
  scattering. Open sky is read from the depth buffer, so a sunlit wall blocks
  light rather than sending it; the shafts fade as the sun leaves the frame,
  vanish when it is behind the camera, and thin under cloud.
  `OrbisScene.distortions` takes shockwaves, heat haze and a lens warp, summed
  in one depth-aware pass with an optional chromatic split — measured, a
  shockwave moves the floor by the 21.6 pixels its strength predicts. Both are
  render-graph effects, `OrbisEffect.godRays` and `OrbisEffect.distortion`; a
  scene with no graph of its own has the passes put in for it, and neither
  costs anything while off.

- **Motion blur, from a velocity buffer.** `OrbisMotionBlur().graph()` draws
  the world into a target that keeps its depth and blurs it onto the screen
  with the reconstruction filter of McGuire et al. (2012): the largest motion
  in each tile, then a depth-aware gather, so a moving thing smears over what
  is behind it and a still thing in front stays sharp. The camera's motion is
  rebuilt from depth, and objects whose transform changed are drawn again to
  record their own, so a spinning fan blurs while the wall behind it does not.
  The renderer remembers both between frames, so a host that only resends its
  scene gets it for free. The streak is photographic — speed times the
  camera's shutter, measured on the clocks things actually moved on — and
  lands within about six per cent of that: 1/1000 s barely blurs, 1/30 s
  smears, and `maxPixels` caps a whipped camera. Off unless a graph asks for
  it; a frame in which nothing moved costs a copy.

- The plugin read a render graph of twelve or more passes out of step: it
  divided the pass list by twelve floats where a pass is thirteen.

- **The black frames that made batching experimental are a fault in Filament,
  and it is traced.** `RenderPass::instanceify()` tested custom commands for
  equivalence alongside draws, and a custom command carries no primitive
  info — only its key is written — so it holds whatever the command arena last
  contained. Where that stale copy matched the draw beside it, the custom
  command was folded into that draw's instanced run and never executed. The
  one this reaches is the colour-grading subpass, sorted last of all: without
  it the tone-mapped attachment keeps its clear value and the whole frame, sky
  included, comes back black — which is why it looked scene-dependent and
  unrelated to what was actually merged. An eleven-line fix with a regression
  test sits on Orbis's Filament fork, and against a Filament built with it
  every scene that used to fail is bit-identical batched and unbatched, with
  the saving unchanged (3000 crates: 6.08 ms down to 3.56 ms). It is in no
  Filament release, so `batching` still defaults to off; the documentation now
  says what the fault is and what would have to be true to change that.

- **What a device below the standard surface's feature level really does**, now
  said where three comments said otherwise. The lit surface declares Filament
  feature level 3, because `matc` allows nine samplers below that and the
  surface binds twelve. A device that cannot manage it does not quietly go
  without: it refuses the material and the renderer aborts on the first lit
  object, before any scene is chosen. Filament's Metal backend grants the third
  level only to `MTLGPUFamilyApple6` and newer — A13, so iPhone 11 onwards —
  and to every Apple silicon Mac; the iOS simulator's virtual GPU reports
  `MTLGPUFamilyApple2`, so it sits below the bar and nothing draws there.
  Lowering the declaration is not the fix: at level 2 the build fails with
  "using more than 9 samplers" despite that level's sixteen texture units. The
  gallery now has an iOS simulator runner and CI builds and runs it, with a
  known feature-level refusal reported loudly rather than passed off as a pass.

- **A slim lit surface for devices below the third feature level.** Chosen
  automatically when the device cannot manage the standard surface — the iOS
  simulator, iPhones before the A13, OpenGL ES 3.0, WebGL 2 — where the
  renderer used to abort on its first lit object. It binds nine samplers
  instead of twelve: every map, ground blending and textured decals are kept
  (the decal rows now share the light data texture), and rectangular
  area-light shadows and the irradiance field are given up, each reported
  through the scene notes when a scene asks for it. The standard surface is
  unchanged and still chosen wherever it was. On the iOS simulator this is the
  difference between no frame at all and a frame drawn.

- **Android.** The plugin has an Android implementation: Kotlin and JNI over
  the same C ABI and the same `orbis_filament` channel protocol as the Swift
  plugin, so the Dart API is unchanged, presenting into a Flutter
  `SurfaceProducer` texture. Vulkan is the default and reaches feature level 3
  on the emulator, where every worked example tried draws correctly; OpenGL ES
  starts too, at feature level 1 with the slim surface. Video is Apple-only and
  says so. Two calls join the C ABI, `orbis_renderer_attach_surface` and
  `_detach_surface`, for a surface that comes and goes with the app; no
  existing call changed. Scenes are applied on the main thread for now, so a
  very large one stutters, and it has not yet been run on a device.

- **The renderer core runs in a browser.** `native/web` compiles the same
  portable C++ and C ABI to WebAssembly with Emscripten — no shared source
  changed — against a Filament built for the web, and a small host page draws
  the headless program's scene into a `<canvas>` through the ABI alone. WebGL 2
  is feature level 1, so the slim surface is chosen and the renderer's notes
  say so. Not yet wired into the Flutter plugin.

- `OrbisScene.copyWith` keeps `probes` and `field`, which it used to drop
  silently.

- **The renderer is portable C++.** Everything it does is now `orbis::Renderer`
  (`OrbisRendererCore.h`/`.cpp`), with no Objective-C and no Apple header in
  it; the Objective-C `OrbisRenderer` is a thin wrapper, so the Swift plugin is
  unchanged and macOS draws what it drew — fifteen of the examples
  bit-for-bit, the rest within the difference between two runs of the same
  code. Logging, the clock, files, decal pictures, video and a parallel loop
  come from a small platform layer: the same Apple frameworks as before on
  Apple, and the standard library, stb_image and Filament's resampler
  elsewhere, where video is not yet supported and the notes say so. The
  backend is chosen per platform — Metal on Apple, Vulkan then OpenGL on
  Android, Linux and Windows, OpenGL on the web — and `ORBIS_BACKEND`
  overrides it; a backend with no driver is skipped rather than crashing.
  `include/orbis_renderer.h` is a C ABI for hosts with neither Objective-C nor
  Flutter, every array length checked, and `native/headless` drives it with no
  Flutter at all, drawing offscreen to a PNG. `setup.sh`'s
  `ORBIS_MATC_BACKENDS` compiles the materials for other backends; every
  material compiles for all of them. The standard lit surface binds twelve
  samplers and so needs Filament's feature level 3, which OpenGL ES 3.0,
  WebGL 2 and OpenGL below 4.3 do not reach — those need a slimmer surface
  before the renderer can start on them.

## 0.21.0

- **Specular anti-aliasing, and occlusion that stops darkening twice.**
  Roughness is a statement about detail too small to see, and a normal map
  carries exactly that detail — so once it falls below a pixel the shading
  frame changes faster than the frame can sample it, which reads as glitter
  crawling over every normal-mapped surface. The distribution is now widened
  by the normal's own sub-pixel variance, which turns those bumps back into
  the roughness they always were.

  Alongside it, `multiBounceAmbientOcclusion` and a simple specular occlusion.
  Applying an occlusion term once treats every blocked photon as absorbed,
  which is why heavily occluded surfaces went muddy and lost their colour; and
  the specular half was not occluded at all, so a mirror at the bottom of a
  crevice reflected the whole environment.

- **The irradiance field reaches metals.** Its contribution was multiplied by
  one minus metalness, which is right for diffuse and meant a metal took
  nothing at all: a chrome ball in a room lit entirely by bounced light was lit
  by nothing. It now samples along the reflection, faded in by roughness,
  because a probe keeps six texels of octahedron — a believable blurred
  reflection and nothing sharper. Polished surfaces keep asking the environment
  map and the probes, which have real mip chains.

- **Clear coat, anisotropy and sheen.** `OrbisMaterial.clearCoat`,
  `anisotropy` and `sheenColour`: varnish over a rough body, a highlight
  smeared along the grain, and the retroreflection that makes cloth read as
  cloth. None is reachable by any amount of roughness. Every one is nought by
  default and inert when it is, so no existing material changes.

- **Wind, as a vertex stage.** `OrbisWind` on a material says how much that
  surface answers the wind, and the surface bends in three frequency bands — a
  trunk leaning into a gust, the elastic recoil past centre, and a flutter that
  does not stop when the gust does. Phase comes from where the instance stands,
  so ten thousand copies of one mesh sway out of step without carrying a byte
  more per vertex.

  On the material rather than on the scene: a scene-level wind moves everything
  by the same amount, and the wall would sway with the hedge.

- **The engine asks for every sampler the device has.** The standard surface
  sat on nine, which was Filament's limit by feature level rather than the
  hardware's. The engine now asks for the highest level the device reports and
  clamps to it.

- **Rectangular lights can be asked to cast a shadow, and the asking is not yet
  answered.** The plumbing is in — a depth map drawn from where the panel
  stands, and a filtered lookup in the surface that widens with the panel's own
  size — but it does not yet occlude anything: rendered with and without, the
  two pictures differ only by dithering. Setting `castShadows` on an area light
  is presently inert rather than wrong.

- The material row is thirty-seven floats, from twenty-six.

## 0.20.0

- **Reflection probes.** `OrbisProbe` is the scene photographing itself from a
  point inside, and being lit by that instead of by the environment. An
  environment is a photograph of somewhere else, and indoors that is the wrong
  photograph: a chrome box in a red and blue room reflected the sky, because
  the sky was the only environment the scene had.

  Six renders of the scene through a ninety-degree camera into the faces of a
  cubemap, then Filament's own GPU prefilter to convolve the sharp capture
  into the blurred chain a rough surface samples. Filament works the diffuse
  out of the roughest level of that chain, so a captured probe lights matte
  surfaces too without anybody baking spherical harmonics for it — which is
  the difference between a probe a scene can take of itself while it runs and
  one a tool has to prepare beforehand.

  Measured on a chrome box turned a half-right angle between a red wall and a
  blue one: with a probe its left face is **7.0x as red as it is blue** and its
  right face **42.6x as blue as it is red**. Without one, both faces are
  black — a metal has no diffuse, so a metal with no environment reflects
  nothing at all. The reflected directions were checked against the mirror
  equation rather than by eye.

- Captured when a probe is first seen and then only when its `version`
  changes. Six renders of the whole scene is not a per-frame cost, and nothing
  but the host can know that the room has changed.

- `layers` on a probe, and it is the setting most worth using: a probe
  captured from inside a mirror photographs the mirror, and the mirror then
  reflects a smaller copy of itself. Putting the reflective things on their
  own layer and leaving it out of the capture is the whole of the fix.

- Whichever probe contains the camera lights the scene, nearest middle winning
  where two overlap, so a doorway joins wherever their centres say. None
  containing it leaves the environment exactly as it was, which is why adding
  probes to an existing scene changes nothing until one of them reaches the
  camera.

- `intensity` on a probe is **one**, not the thirty thousand lux an
  environment states. The two are not the same kind of number: a baked
  environment is stored relative to some reference and its intensity turns it
  into lux, while a probe is the scene's own light rendered with the exposure
  held at one, so it arrives already in the units the rest of the frame is in.
## 0.19.0

- **Rectangular area lights.** `OrbisLightKind.area` is a panel that emits
  from one face: a window, a softbox, a strip in a ceiling. It takes the
  `width` and `height` of the rectangle and a `tangent` saying which way the
  width runs, because a face alone leaves a panel free to spin in its own
  plane and a strip light on its side is a different light.

  Filament has no area light, so this one is shaded by the surface material
  itself and handed back through `postLightingColor`. The maths is linearly
  transformed cosines (Heitz, Dupuy, Hill and Neubelt, SIGGRAPH 2016): a
  fitted matrix per roughness and viewing angle bends the clamped cosine lobe
  into the GGX lobe, so integrating the rectangle against the *cosine* — which
  has a closed form — answers for the rectangle against GGX, which does not.
  One polygon integral per light, no marching and no sampling. The two fitted
  tables are fetched by `setup.sh` in the authors' own packing, the way SMAA's
  are; see `LICENSES/LTC.txt`.

  Checked against physics rather than against a screenshot. Shrunk to four
  centimetres a panel has to converge on a point light of the same flux, and
  be **exactly four times** as bright — a one-sided panel puts its lumens into
  pi steradians and a point puts them into 4pi. Measured on a common mask,
  the ratio is **3.94**. Held at one flux and grown from 4 cm to 6 m, the
  total light in frame stays put (93.6, 93.4, 86.6) while the lit area
  spreads — the same light over more of the scene, which is what an area
  light is for.

  Two things worth knowing rather than discovering. It casts no shadow: it is
  outside Filament's lighting, so nothing shadows it. And it lights the
  standard surface only — a glTF file keeps its own materials, and those are
  Filament's, not this one's.

- Sixteen of them per view, past which the ones over the budget are reported
  and light nothing. They are not free the way a punctual light is: a
  rectangle is a polygon integral paid by every lit fragment, with no culling
  in front of it.
## 0.18.0

- **`OrbisField`: light kept in the world rather than on the screen.** A
  lattice of probes standing in the scene, each holding what light reaches it
  from every direction, built up over many frames and read by every surface
  near it. Where a screen-space bounce answers *how much light is here, worked
  out now*, a field answers *how much light is at that point in the room* —
  and still has the answer when what lit it has left the frame.

  Probes are filled by marching the depth buffer outward from each probe and
  taking what it finds, then folding that into what the probe already held.
  The reference implementations scatter instead — they reconstruct each screen
  texel and add it to the probes enclosing it, which needs an instanced draw
  with one instance per texel and cage corner. Marching is the same trace the
  bounce pass already does and needs no geometry at all.

  Read in the surface shader rather than composited over the finished picture,
  because indirect light is light: it has to be reflected by each surface's
  own colour, and a pass over the frame does not have one. Eight probes at the
  corners of the cell are mixed by distance, by whether the surface faces
  them, and by whether they can see it — the last from a distance the probe
  stores alongside its colour, which is what stops a field lighting the inside
  of a wall with the sunshine outside it.

  Measured in a room with one red wall and one blue one, across five runs: the
  field lifts the shadowed surfaces by **+9.8 to +19.0** of 255, and the half
  of the room by the red wall comes out **+8.6 to +17.9 warmer** than the half
  by the blue one. The direction is the test — a field that merely brightened
  would move both halves together. The spread is how far the accumulation has
  got by the frame that is measured.

- **`OrbisEffect.copy`**, the plainest pass there is and the one that makes the
  others possible: a target, put on the screen. Anything that reads what the
  scene drew needs the scene drawn into a target, and then needs something to
  put that target on the screen; without this the only way to present one was
  to run an effect that also changed it.

### Two ways this can go wrong, both now guarded

A field reads the picture the scene drew, and that picture already contains
what the field contributed to it. The light goes round, multiplying by the
surfaces' albedo each lap, and an infinite series of that converges only while
the product stays below one. Undamped it does not — and it does not fail by
getting brighter, it fails by **drifting in hue**, because the channel with the
highest gain wins the race. This room turned green, a colour nowhere in it.
The injection damps the sub-unit part of the light to nought point six, and
the renderer holds the strength below where that stops being enough.

Both numbers are measured rather than picked, over six hundred frames in a
room with a red wall and a blue one. The light that arrives matches what was
asked for to within three per cent up to a strength of **four**, is ten per
cent over at five, and **fifty-seven** per cent over at six — where the room
had visibly turned. The cap is at three: the last fully linear point with a
whole step of margin under the knee. Asking for more is **reported** through
the scene's notes rather than silently substituted, because a host that asks
for six and quietly gets three has a scene that does not match its reference
and no way to find out why.

The damping and the cap are one constant divided by another, in one place, so
that changing the damping moves the cap with it. They are two halves of the
same statement and drifting apart would put the loop back over one.

The atlas textures are also **cleared when they are built**. A texture Filament
allocates holds whatever the driver last had there, and surfaces read it before
the first pass has written it. That was the *other* source of the green, and it
survived turning the temporal blend off — which is what told the two apart.

## 0.17.0

- **`OrbisEffect.bounce`: one bounce of light, taken from the picture already
  drawn.** Direct lighting stops at the first surface it meets, so a white box
  between a red wall and a blue one comes out white on both sides when a real
  room would paint one side pink. This puts the second bounce back.

  Each pixel fans a set of directions across its hemisphere and marches the
  depth buffer along each, keeping a 32-bit mask of which sectors something
  blocks. A sector that has *just* been blocked is a surface the pixel can
  see, so its colour is credited as light arriving from that direction.
  Counting sectors is what makes the falloff right with no distance term in
  it: something twice as far subtends half the angle and so covers a quarter
  of the sectors, which is the inverse square arrived at by geometry. After
  Therrien et al., "Screen Space Indirect Lighting with Visibility Bitmasks"
  (2023).

  Measured in a corner of a red wall and a blue one: **14.7% of the frame
  changes**, and on the pixels that change most the bounce adds **2.2 times
  as much red as blue**, concentrated on the floor beside the red wall. That
  ratio is the whole test — a pass that merely brightened would add the three
  channels equally.

- **Depth is now sampleable.** A target's depth texture was a depth attachment
  and nothing else, so no pass could read the shape of the scene, only its
  colour. That one flag is what occlusion, bounced light and contact shadows
  all begin from.

- A graph that bounces light off a target keeping no depth is now **reported**
  rather than silently skipped. The renderer declines such a pass, and a frame
  drawn with the effect quietly absent is indistinguishable from the effect
  not working.

- **`OrbisScene.copyWith`.** A scene is stated whole every frame, which made
  taking one somebody else built and changing one thing about it a matter of
  copying a dozen fields by hand and quietly dropping whichever was added
  last.

### What the bounce costs, and what it cannot do

Measured at 800x600 against the same graph running a pass that only copies:
**1.9 ms for two directions, 3.7 ms for four, 6.7 ms for eight** — near enough
a millisecond a direction, scaling with pixel count. Four is the default.
Running the pass into a half-size target is the obvious saving and is not
built yet.

It knows only about surfaces on screen, so turning away from a red wall takes
its bounce with it. And it works on the finished picture rather than inside
the shading, so it scales the light already there rather than being reflected
by each surface's own colour: it can tint a lit surface and can never light an
unlit one.

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
