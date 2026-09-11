# Porting the renderer off Apple platforms

The renderer is plain C++ now. `orbis::Renderer` in `OrbisRendererCore.h` and
`OrbisRendererCore.cpp` is everything it does, with no Objective-C and no
Apple header. The Objective-C class in `OrbisRenderer.mm` is a thin wrapper:
the Swift plugin calls it through `include/OrbisRenderer.h`, which has not
changed, and it forwards every call. Any other host calls the C ABI in
`include/orbis_renderer.h`.

## Where everything is

| Was | Is |
|---|---|
| The structs and constants at the top of `OrbisRenderer.mm` | The top of `OrbisRendererCore.h`, in the same order, in `namespace orbis` |
| The ivar block of `@implementation OrbisRenderer` | The private members at the end of `class Renderer`, same names, same comments |
| Each `- (T)foo:(A)a bar:(B)b` method | `T Renderer::foo(A a, B b)` in `OrbisRendererCore.cpp`, in the same order, comments kept |
| `[self foo:x bar:y]` | `foo(x, y)` |
| `NSLog(@"…%@…", s)` | `orbis::log("…%s…", s.c_str())` (`OrbisPlatform.h`) |
| `NSString *`, `NSArray<NSString *> *` | `std::string`, `std::vector<std::string>` |
| The notes dictionaries | `orbis::Notes`, a `std::map` |
| `NSData dataWithContentsOfFile:` | `orbis::readFile` |
| `CFAbsoluteTimeGetCurrent()` | `orbis::now()` (still CoreFoundation's clock on Apple) |
| `dispatch_apply` | `orbis::parallelFor` (still dispatch on Apple) |
| `NSLock` | `std::mutex` |
| `OrbisReadDecalPicture` (ImageIO) | `orbis::readPicture`: ImageIO in `OrbisPlatformApple.mm`, stb_image and Filament's resampler in `OrbisPlatform.cpp` |
| `AVPlayer` and friends in `Movie`, `open:`, `close:`, `pumpVideos` | `orbis::VideoDecoder`: AVFoundation in `OrbisPlatformApple.mm`; none elsewhere yet, which the notes say |
| `builder.backend(Engine::Backend::METAL)` | `orbis::backendCandidates` (`OrbisBackend.cpp`) |
| `initWithWidth:` / `copyPresentedBuffer` / `notes` / `passTimings` | `Renderer::initWithWidth` / `copyPresentedBuffer` / `notes` / `passTimings`, which the wrapper turns back into Foundation types |

## Porting a change made to the old `OrbisRenderer.mm`

By hand, a hunk goes into the function of the same name in
`OrbisRendererCore.cpp`, at the same place — the comments around it are the
same, so search for them. `[self …]` becomes a call and Foundation types
become the ones in the table above. A new ivar becomes a member in
`OrbisRendererCore.h`; a new `#include` goes at the top of the header, except
a compiled material's `generated/…_material.h`, which goes in the anonymous
namespace at the top of `OrbisRendererCore.cpp` so its arrays stay private to
the renderer; a new
method in `include/OrbisRenderer.h` becomes a public member of
`orbis::Renderer` plus a one-line forwarder in `OrbisRenderer.mm`.

Mechanically, for a branch cut before the move:
`packages/orbis_filament/native/port_from_mm/port.sh` regenerates the core
from the branch's own `OrbisRenderer.mm` by the same conversion that made it.
God rays, distortion and motion blur came across that way. The script's
header says what it cannot do by itself.

## What is still Apple's, and why

- `OrbisRenderer.mm` and `include/OrbisRenderer.h` — the Swift plugin speaks
  Objective-C.
- `OrbisSurfaceApple.mm` — IOSurface-backed `CVPixelBuffer`s are how Flutter
  on Apple adopts a frame without a copy. Every platform presents
  differently; `OrbisSurface` is the seam, and `OrbisSurfaceHeadless.cpp`
  adds a window surface and an offscreen one for everywhere.
- `OrbisPlatformApple.mm` — the Apple answers to the platform layer, kept
  so an Apple build does what it did.
- `OrbisTexture.m`, `OrbisFilamentPlugin.swift` — Flutter's Apple plugin.
- Video — only AVFoundation is written. MediaCodec, GStreamer or Media
  Foundation are each their own piece of work.

## What was proven, and what was not

Proven on this Mac:

- Every plain C++ file — the core, the C ABI, the platform layer's portable
  half and the helpers — compiles with `ORBIS_PLATFORM_PORTABLE`, and
  `clang -M` finds no Apple framework, Objective-C or dispatch header among
  the 700 to 900 each includes.
- The aarch64 Linux release's headers are identical to the macOS ones apart
  from `gltfio/materials/uberarchive.h`, so compiling against the macOS
  headers is representative.
- `native/headless` links the portable build into two C programs that
  include only `orbis_renderer.h`: the C ABI's test, which passes, and a
  headless host that draws a scene offscreen and writes a PNG.

Not proven:

- A Linux, Android or Windows build. Docker's daemon did not answer, so the
  core has not been compiled against a Linux sysroot or linked against the
  Linux release.
- Any backend but Metal drawing a frame. This Mac has no Vulkan driver, and
  its OpenGL is 4.1, feature level 1, below the standard surface; a headless
  OpenGL swap chain there also needs a main-thread run loop.
- Video, and `ORBIS_SURFACE_WINDOW`, anywhere but Apple.

## Materials and feature levels

`setup.sh` compiles for Metal by default; `ORBIS_MATC_BACKENDS` names others
(`vulkan opengl`, or `all`). Every material compiles with `-a all -p all`.
Embedded, the thirty-seven packages are 4.70 MiB for Metal, 3.32 MiB for
OpenGL alone, 13.27 MiB for Vulkan and OpenGL, and 18.21 MiB for all.

`lit.mat` declares `featureLevel : 3`: the standard surface binds twelve
samplers (seven maps, the light data, the area shadow, the field atlas and
two for decals), and Filament allows a material nine below the third level.
Every other material is feature level 1. OpenGL ES 3.0, WebGL 2 and desktop
OpenGL below 4.3 are feature level 1, so on those the standard surface does
not load, and the renderer does not start. Reaching them means a lit surface
with nine samplers or fewer.

## The audit this started from

Taken at `d6447da`, when `OrbisRenderer.mm` was 7,287 lines; line numbers
are into that version.

| Construct | Lines | What it was for |
|---|---|---|
| `@interface` / `@implementation` / `@end`, the ivar block, 125 method definitions | 854–857, 867–1317, then 1319 to 7287 | the class itself |
| `[self …]` message sends (132 lines) | 1330 to 7284 | the class calling its own methods |
| `NSLog` (16) | 1332, 1335, 1348, 1449, 2011, 2023, 2134, 2139, 2154, 2753, 3136, 6802, 6813, 6816, 6964, 7027 | diagnostics; `tool/ci_draw_frame.sh` waits for `[orbis] frame` |
| `NSString`, `NSArray<NSString *>`, `NSData`, `NSURL`, `@"…"`, `stringWithFormat:` (143 lines) | 344; 2007–2155 (mesh loading); 2707, 2764; 3071–3096 (textures); 3439–3563 (cubemaps); 3653; 4632, 4727, 4886; 5191; 5396–5611 (decals); 5899; 6038; 6781–6786; 7247–7280 (notes) | paths in, notes out |
| `NSMutableDictionary` notes | 1170, 1176, 1180–1181, 1205, 4896, 5255, 5585 | what a scene asked for that could not be given |
| `NSLock` | 1255, 1291, 1360–1361, 6454–6457, 6485–6488, 6679–6682, 6826–6835, 6903–6906, 7037–7043 | the camera hand-off and the presented index, between threads |
| `NSUInteger`, `NSInteger`, `BOOL` / `YES` / `NO`, `nil`, `MAX` (61 lines) | e.g. 864, 879, 1053, 1240–1241, 1292, 1355–1356, 4548, 6110 | Foundation's types and macros |
| AVFoundation, CoreMedia, `CACurrentMediaTime`, `NSNotificationCenter` with a block and `__weak` | 3, 429–446, 3344–3425, 4629–4721 | video onto an external texture |
| CoreVideo `CVPixelBufferRef` | 436, 3356–3358, 3420, 4710, 4718, 7036–7044 | video frames; `copyPresentedBuffer` |
| ImageIO and CoreGraphics | 4–5, 5396–5425 | decal pictures |
| `dispatch_apply` | 2105–2107 | reading a model's files in parallel |
| `CFAbsoluteTimeGetCurrent` | 1353, 1450, 2008, 2016, 2029, 2153, 6451, 6531, 6589, 6748, 6772, 6804, 6911, 6927 | load timings, camera clock alignment, pass timings, pacing |
| `Engine::Backend::METAL` | 1371 | the only backend it ever asked for |
| `#import` of Foundation, AVFoundation, CoreGraphics, ImageIO | 1, 3–5, 28 | |

Not Apple but not portable either: POSIX `open`/`read`/`fstat` in
`readWholeFile` (361–394), absent under MSVC and now behind
`orbis::readWholeFile`; `M_PI` (1657, 1661, 1868, 3910), defined by the core
if the platform does not; `getenv` (1362, 5115, 6993), harmless where nobody
sets the environment.
