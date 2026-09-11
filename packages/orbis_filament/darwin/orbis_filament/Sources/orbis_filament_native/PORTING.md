# Porting the renderer off Apple platforms

An audit of what in the renderer belongs to Apple rather than to Filament,
taken at `d6447da` (the `rendering-completion` merge of shadows, batching,
splats, outline and decals), when `OrbisRenderer.mm` was 7,287 lines. Line
numbers are into that version of the file.

Everything not listed here — the scene and its reconciliation, the materials,
lights, sky, weather, render graph and passes, probes, the irradiance field,
decals, splats, the outline and batching — is Filament and gltfio C++ already.
What stopped it building anywhere else was the wrapper around it, not the work
inside it.

## OrbisRenderer.mm

| Construct | Lines | What it was for |
|---|---|---|
| `@interface` / `@implementation` / `@end`, the ivar block, 125 `- (…)` method definitions | 854–857, 867–1317, then 1319 to 7287 | the renderer is an Objective-C class |
| `[self …]` message sends (132 lines) | 1330 to 7284 | the class calling its own methods |
| `NSLog` (16) | 1332, 1335, 1348, 1449, 2011, 2023, 2134, 2139, 2154, 2753, 3136, 6802, 6813, 6816, 6964, 7027 | diagnostics; `tool/ci_draw_frame.sh` waits for the `[orbis] frame` line |
| `NSString`, `NSArray<NSString *>`, `NSData`, `NSURL`, `@"…"`, `stringWithFormat:` (143 lines) | 344 (`Wanted.path`); 2007–2155 (mesh loading: `dataWithContentsOfFile:`, path joins, percent-decoding); 2707, 2764 (splat and population paths); 3071–3096 (material textures); 3439–3563 (cubemaps); 3653 (graph target names); 4632, 4727, 4886 (video, texture and mesh paths); 5191; 5396–5611 (decals); 5899; 6038; 6781–6786 (pass timings); 7247–7280 (notes) | paths in, notes out |
| `NSMutableDictionary` notes | 1170, 1176, 1180–1181, 1205, 4896, 5255, 5585 | what a scene asked for that could not be given |
| `NSLock` | 1255, 1291, 1360–1361; used at 6454–6457, 6485–6488, 6679–6682, 6826–6835, 6903–6906, 7037–7043 | the camera hand-off and the presented index, between the platform thread and the render thread |
| `NSUInteger`, `NSInteger`, `BOOL` / `YES` / `NO`, `nil`, `MAX` (61 lines) | e.g. 864, 879, 1053, 1240–1241, 1292, 1355–1356, 4548, 6110 | Foundation's types and macros |
| AVFoundation and CoreMedia: `AVPlayer`, `AVPlayerItemVideoOutput`, `CMTime`, `CACurrentMediaTime`, `NSNotificationCenter` with a block and `__weak` | 3, 429–446 (`Movie`), 3344–3425 (`open:atPath:`, `restartIfLooping:`, `close:`), 4629–4721 (`applyVideos:…`, `pumpVideos`) | decoding video onto an external texture |
| CoreVideo `CVPixelBufferRef` | 436, 3356–3358, 3420, 4710, 4718, 7036–7044 | decoded video frames; `copyPresentedBuffer` |
| ImageIO and CoreGraphics | 4–5, 5396–5425 (`OrbisReadDecalPicture`) | reading a decal's picture, resampling it to 512², premultiplying |
| `dispatch_apply` | 2105–2107 | reading a model's files in parallel |
| `CFAbsoluteTimeGetCurrent` | 1353, 1450, 2008, 2016, 2029, 2153, 6451, 6531, 6589, 6748, 6772, 6804, 6911, 6927 | load timings, the camera's clock alignment, pass timings, pacing |
| `Engine::Backend::METAL` | 1371 | the only backend the renderer ever asked for |
| `#import` of Foundation, AVFoundation, CoreGraphics, ImageIO | 1, 3–5, 28 | |

Not Apple, but not portable either:

- `open` / `read` / `fstat` in `readWholeFile` (361–394) are POSIX: fine on
  Linux and Android, absent under MSVC.
- `M_PI` (1657, 1661, 1868, 3910) is not defined by MSVC unless asked for.
- `getenv` (1362, 5115, 6993) works everywhere and means nothing on Android or
  a console, where nobody sets the environment.

## The rest of the native target

- `OrbisSurfaceApple.mm` — IOSurface-backed `CVPixelBuffer`s, a
  `CGImageDestination` for `ORBIS_DUMP_FRAME`, `NSTemporaryDirectory`,
  `NSLog`. Already behind the four-method `OrbisSurface`, and stays Apple's:
  every platform presents differently, and that is the one seam that is
  supposed to differ.
- `OrbisTexture.m`, `include/OrbisTexture.h` — Flutter's texture adapter.
- `include/OrbisRenderer.h` — the Objective-C interface the Swift plugin calls.
- `../orbis_filament/OrbisFilamentPlugin.swift` — the method channel and the
  display link. Another platform's plugin replaces this and calls the C ABI.
- `setup.sh` — `MATC_FLAGS="-a metal -p all"`: the compiled materials carry
  Metal shaders and nothing else, so no other backend could load them.
- `Package.swift`, `orbis_filament.podspec` — link Metal, CoreVideo,
  AVFoundation, CoreMedia, AudioToolbox, QuartzCore, IOSurface and OpenGL.

## Materials and feature levels

`lit.mat` declares `featureLevel : 3`: the standard surface binds twelve
samplers (seven maps, the light data, the area shadow, the field atlas and two
for decals), and Filament allows a material nine below the third level. Every
other material is feature level 1. OpenGL ES 3.0 and WebGL 2 are feature level
1, and desktop OpenGL below 4.3 — which includes macOS's 4.1 — is too, so on
those the standard surface does not load at all.
