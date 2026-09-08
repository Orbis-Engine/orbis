# Changelog

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
