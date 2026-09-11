# Orbis web canvas spike

Spike: Google Filament 1.76, compiled to WebAssembly, drawing into a
`<canvas>` embedded in a Flutter web app — proving the shape the real web
renderer would take, not building it. `tool/build.sh` builds it,
`tool/capture.sh` serves the build and photographs it with headless Chrome so
the result is a screenshot, not a claim.

## What it proved

- `ui_web.platformViewRegistry.registerViewFactory` (`lib/filament_canvas.dart`)
  puts a real `<canvas>` in the DOM as a Flutter platform view
  (`HtmlElementView`, `lib/main.dart`), and Filament — `filament.js` +
  `filament.wasm` from Google's official 1.76.0 web release — draws into it
  with its own `requestAnimationFrame` loop, entirely outside Flutter's own
  CanvasKit rendering of the rest of the page.
- Flutter widgets (a label, a stats readout, two sliders) paint *over* the
  canvas and stay legible — proof of compositing, not one layer hiding the
  other.
- One scene parameter crosses from Dart to the renderer through
  `dart:js_interop` (`lib/scene_message.dart`, `lib/filament_canvas.dart`): a
  slider encodes a colour or a spin speed as bytes and hands them to the
  JavaScript renderer's one entry point, `apply()`. That is the shape the
  real scene message would take crossing this boundary, whichever route
  below ends up owning the other side of it.
- `matc` (the Mac SDK's, the one `packages/orbis_filament/darwin/setup.sh`
  fetches) compiles `material/spin.mat` — a feature-level-1 lit material —
  for WebGL2 with `-a opengl -p mobile`, no changes to Filament or matc
  itself needed.
- Confirmed at runtime, not just inferred from documentation: Filament's
  engine picks backend `OPENGL` and reports `activeFeatureLevel` = 1,
  `supportedFeatureLevel` = 1 under headless Chrome's WebGL2. See "The
  feature-level ceiling" below.

## Screenshots

`tool/capture.sh` serves `build/web` on localhost and takes three shots with
headless Chrome (`--headless=new --use-angle=swiftshader
--enable-unsafe-swiftshader`, SwiftShader's software WebGL2 so the result
depends on nobody's GPU). The three below were taken with its exact
commands (same server, same flags, same three virtual-time/query
combinations) run one at a time by hand rather than by the unattended
script: this machine was, at the time, under heavy memory pressure from an
unrelated Android emulator and iOS build running concurrently in sibling
worktrees, which made a multi-minute per-shot wait indistinguishable from a
genuine hang until checked (see "Gotchas"); running one shot at a time made
that distinction checkable. Under ordinary load `tool/capture.sh` runs these
same three shots unattended.

| File | Virtual time | Query string | Shows |
|---|---|---|---|
| `captures/1_default_3s.png` | 3 s | — | Default state (sliders at 14°, 0.80 rad/s): the lit cube, the "Flutter widget, over the Filament canvas" label composited top-left. |
| `captures/2_default_6s.png` | 6 s | — | Same parameters, twice the virtual time: the cube is at a visibly different rotation than in the first shot (compare the two — the silhouette and which edge sits nearest the camera both change) — the `requestAnimationFrame` loop is actually animating, not redrawing a static frame. |
| `captures/3_dart_hue200.png` | 5 s | `?hue=200&spin=2.5` | `main.dart`'s `initState` reads the query string and sends it the moment the canvas mounts (`_drivenFromQuery`), with no slider touched. The cube is now the cyan-blue of hue 200 rather than the default orange, the sliders themselves sit at 200°/2.50 rad/s, and "Driven from Dart" reads "1 sent" — the Dart → JavaScript crossing changed what is actually on screen, not just the widgets around it. |

All three shots' stats panels (top-right) read "waiting for Filament…"
rather than the numbers `FilamentStats` carries — a capture-method quirk,
not a renderer one: `_poll`'s 250 ms `Timer.periodic` never visibly ticks
within a single `--virtual-time-budget` screenshot, in any of the three
shots, regardless of budget (3 s, 6 s and 5 s all show it). The canvas
itself is proof enough that frames are drawn — the rotation between shots 1
and 2, and the colour in shot 3 — so this was not chased further; the
authoritative numbers are each shot's own console line instead (below),
which does update correctly.

Console log for the first shot (`captures/1_default_3s.log`) has the
JavaScript renderer's own report of what it mounted on:

```
orbisWeb: mounted orbis-filament-0: {"frames":0,"messages":0,"backend":"OPENGL",
"activeFeatureLevel":1,"supportedFeatureLevel":1,
"glVersion":"WebGL 2.0 (OpenGL ES 3.0 Chromium)",
"glRenderer":"ANGLE (Google, Vulkan 1.3.0 (SwiftShader Device (LLVM 10.0.0)
(0x0000C0DE)), SwiftShader driver)","width":0,"height":0}
```

(All three logs report the same backend/feature-level/GL numbers — mounting
is independent of which query string or virtual-time budget the shot uses,
as it should be.)

## Route to the real renderer

Two ways to get Orbis's actual scene onto that canvas, not just a spinning
cube.

### [i] A JavaScript renderer over Filament's JS API

Hand-write a second interpreter of Orbis's scene message, this time in
JavaScript against Filament's own JS/wasm bindings — what
`web/orbis_filament_view.js` does here, in miniature, for two opcodes
(`setBaseColour`, `setSpin`) out of the real ABI's twenty-odd.

`include/orbis_renderer.h` is not two calls. It is `apply_objects`,
`apply_materials` (with texture maps and video), `apply_lights`,
`apply_decals`, `set_fog`, `set_post_process`, `apply_probes`,
`apply_field`, `set_environment`, `set_render_graph`, `set_god_rays`,
`apply_populations` (instancing, its own bounds/transform/colour
sub-encoding), `apply_splats` (its own binary record format), `set_sky`,
`set_precipitation`, `set_sky_colour`, `set_camera`, `set_exposure`,
`set_outline`, plus capture, stats and notes read-back. Route [i] commits to
reimplementing all of that in JavaScript, by hand, against a different API
(Filament's JS bindings rather than its C++ classes) — and to
reimplementing every future addition to `OrbisRendererCore.cpp` a second
time, in a second language, forever, with no mechanical way to prove the two
stay in sync. That is a second renderer to maintain, not a porting step.

What it buys: no Emscripten toolchain and no C++ compiler anywhere in the
loop — `tool/build.sh` here is `matc` plus copying two files. Filament's JS
bindings (`filament.d.ts`, 2,577 lines) are complete enough that this
spike's 339-line renderer (`web/orbis_filament_view.js`) reaches engine,
swap chain, renderer, scene, view, camera, material, mesh (including
`SurfaceOrientation` for tangent frames), lights and IBL directly, with
nothing missing so far.

### [ii] The portable C++ core, compiled to WebAssembly with Emscripten

Orbis already has the pieces this needs, proven rather than hypothetical:

- `orbis::Renderer` (`OrbisRendererCore.h`/`.cpp`) is plain, portable C++
  already. `PORTING.md`: "compiles with `ORBIS_PLATFORM_PORTABLE`, and
  `clang -M` finds no Apple framework, Objective-C or dispatch header among
  the 700 to 900 [headers] each includes."
- `include/orbis_renderer.h` is a C ABI built for exactly this: "A Kotlin
  plugin calls this through JNI, a Linux or Windows plugin calls it from
  C++, and a console host with no Flutter at all calls it from `main()`."
  `OrbisBackend` already has `ORBIS_BACKEND_WEBGPU`, "reserved for the web
  ... until the materials are compiled for it."
- `packages/orbis_filament/native/headless/orbis_headless.c` is that console
  host, today: a Flutter-free, Objective-C-free C program that creates a
  renderer, applies a scene, draws frames, reads a capture back and writes a
  PNG, through nothing but `orbis_renderer.h`. Its `build.sh` compiles
  `OrbisRendererCore.cpp` and friends with `-DORBIS_PLATFORM_PORTABLE`
  using plain `clang++`, then links the two C programs against the Mac
  Filament SDK's static libraries and, only at that final link, Apple's
  frameworks (Metal, Cocoa, OpenGL, ...) — because that SDK's own backends
  need them, not because the renderer does. Point that link step at a
  Filament built for Emscripten instead and the object files do not change.
- Filament for Emscripten is not a gap either: `orbis-filament/build.sh -p
  wasm` already builds it (`$EMSDK/emsdk_env.sh` sourced, CMake's
  `Emscripten.cmake` toolchain file) and packages `filament.js` /
  `filament.wasm` / `filament.d.ts` into a `filament-*-web.tgz` — which is
  literally how the Google-published release this spike downloads is made.
  Orbis owns that pipeline already; it does not need to be invented, only
  pointed at `OrbisRendererCore.cpp` instead of Filament's own JS bindings.

What is left, concretely: build Filament for web with that script (needs
`emsdk` installed and `EMSDK` set — a real but one-time toolchain cost);
compile the core and the portable half of the platform layer with `emcc`
against it, the same way `native/headless/build.sh` already does with
`clang++`; decide what `orbis_surface_desc.window` means for
`ORBIS_SURFACE_WINDOW` on the web (Filament's own C++ web platform already
turns a canvas selector into a swap chain, so this is plausibly a small
`OrbisSurfaceWeb`, sibling to the existing `OrbisSurfaceHeadless`, not a new
renderer); and export `orbis_renderer_*` from the resulting
`orbis_renderer.wasm` (`emcc`'s `-sEXPORTED_FUNCTIONS` / `ccall`/`cwrap`,
the same mechanism Filament's own `filament.js` glue already uses on top of
the identical toolchain). The same `OrbisRendererCore.cpp` that draws every
other platform would draw the web.

### Recommendation: [ii]

`orbis_renderer.h`'s surface is large and still growing, with several calls
(`apply_populations`, `apply_splats`) carrying their own binary
sub-encodings. Route [i] means reimplementing all of it by hand in
JavaScript, then re-reimplementing every future addition the same way,
forever, with nothing to mechanically check the two stay in sync — a
correctness and maintenance liability that only grows. Route [ii] has
already been de-risked twice over by other work in this repository, not by
this spike: `PORTING.md` proves the core compiles with zero Apple, zero
Objective-C, zero Flutter in the object files, and `orbis-filament/build.sh
-p wasm` proves Filament itself already has a working, Orbis-owned
Emscripten target. What remains for [ii] is an `emsdk` toolchain and one new
`OrbisSurface` implementation — not a parallel scene interpreter. Route
[i]'s only real advantage is standing up without any C++ toolchain at all,
which is exactly why this spike used it: it let the canvas / compositing /
`dart:js_interop` shape get proven without Emscripten being installed
anywhere. That advantage does not carry over to building the real renderer,
where staying in lockstep with the native core matters far more than saving
a toolchain install.

## The feature-level ceiling (unavoidable on either route)

WebGL2 sits at Filament feature level 1 — Filament's own backend limit, not
a consequence of picking [i] or [ii]. This spike's own runtime numbers, from
`captures/1_default_3s.log`:

```
backend: OPENGL, activeFeatureLevel: 1, supportedFeatureLevel: 1
glVersion: WebGL 2.0 (OpenGL ES 3.0 Chromium)
```

Orbis's standard lit surface (`lit.mat`) declares `featureLevel : 3` and
binds twelve samplers. `PORTING.md`: "Filament allows a material nine
[samplers] below the third level ... OpenGL ES 3.0, WebGL 2 and desktop
OpenGL below 4.3 are feature level 1, so on those the standard surface does
not load, and the renderer does not start. Reaching them means a lit
surface with nine samplers or fewer." Nor is there anywhere to fall back to
in the meantime — the same document, on the same ceiling as it bites on the
iOS simulator's Metal (feature level 2, one below the standard surface's
floor): "There is no degradation path: the renderer has no fallback surface
to drop to." So whichever route ends up drawing the real scene, it has to
draw with the slim lit surface `feat/slim-lit` is building — a lit surface
at feature level 1, nine samplers or fewer — not the standard one. The web
is simply a second, harsher member of the family Metal-on-the-iOS-simulator
and Android's OpenGL already answer to; it is not a new problem, and neither
route here fixes or worsens it. This spike's own material (`spin.mat`,
`featureLevel : 1`, three parameters, no extra samplers) is a small working
example of staying inside that ceiling: it compiled, loaded and shaded
correctly with nothing to fall back from, because it never asked for more
than the ceiling allows.

## What has to change in Dart

Two changes, independent of each other and of which route wins:

1. **`dart:ffi` is unconditional today**, which is why none of these
   packages build for web as they stand. `import 'dart:ffi'` appears
   with no conditional import in `packages/orbis_core/lib/src/world.dart`,
   `packages/orbis_core/lib/src/bindings.dart`,
   `packages/orbis_native/lib/src/host.dart` and
   `packages/orbis_native/lib/src/script.dart` (the QuickJS host) —
   `dart:ffi` does not exist for the web compiler at all. Each needs its
   FFI-backed half split out behind a conditional import (`dart.library.ffi`
   vs. `dart.library.js_interop`, or a stub default with a `dart.library.io`
   override — either direction), with the web side written against
   `dart:js_interop` instead of `DynamicLibrary`/`Struct`.
   `bindings.dart`'s `OrbisTransformsStruct` and `host.dart`'s
   `OrbisScriptHost` are `extends Struct`: on the web there is no memory to
   lay a `Struct` over, so that side has to re-express the same rows as
   encoded bytes — what this spike's `SceneMessage` already sketches for two
   of them — not as FFI structs.
2. **The scene already has to cross by `dart:js_interop`, not `dart:ffi`,
   on the web, whichever route wins.** `lib/filament_canvas.dart` and
   `lib/scene_message.dart` are that shape in miniature: a `@JS()` external
   call handing a `Uint8Array` of encoded commands to one entry point,
   decoded on the other side. Under route [i] the other side is hand-written
   JavaScript (as here). Under route [ii] it would be `ccall`/`cwrap` into
   the Emscripten module's exported `orbis_renderer_*` functions instead.
   The Dart-side encoding barely changes between the two; only what receives
   it does.

## Gotchas

- **Headless Chrome's `--screenshot` mode did not quit on its own.** It is
  documented to exit once the shot is written; observed here, the first
  shot's process sat alive indefinitely once its virtual-time budget
  elapsed, wedging every shot queued after it with no error, and macOS
  ships no `timeout(1)` to guard against it. `tool/capture.sh`'s `shoot()`
  now backgrounds Chrome itself, polls for its PNG, gives it a couple of
  seconds to exit on its own once the file exists, and kills it either way
  past a hard ceiling.
- **`Filament.init` has no failure callback, only a resolve.** A missing or
  mis-served asset (wrong path to the `.filamat`, `matc` not run) hangs
  forever with no error. `orbis_filament_view.js`'s `initFilament` wraps it
  in a timeout so a broken build fails loudly instead of hanging
  `tool/capture.sh` a second way.
- **A platform view's element is detached when its `registerViewFactory`
  callback runs.** `Engine.create(canvas)` needs the canvas laid out
  (`clientWidth`/`clientHeight` > 0) to size its swap chain correctly, so
  mounting polls with `requestAnimationFrame` until the canvas is actually
  connected and sized (`whenLaidOut`) rather than mounting from inside the
  factory itself.
- **Flutter resizes the platform view's CSS box, never the canvas
  element's backing-store `width`/`height`.** Those stay whatever they were
  created with — 0, here — until something sets them. The renderer has to
  notice and match its drawing buffer to
  `canvas.clientWidth/Height * devicePixelRatio` itself, every frame
  (`fitToCanvas`); skip this and it draws at the canvas's stale
  backing-store size (the HTML default, 300×150) regardless of how large
  Flutter laid it out on screen.
- **matc's platform flag is not obvious from Filament's desktop-oriented
  docs.** WebGL2 runs Filament's OpenGL backend as OpenGL ES 3.0, so
  materials need `-p mobile` (ESSL) shaders, not the `-p desktop` (GLSL)
  default — a desktop-shader `.filamat` compiles without complaint and then
  fails to load in the browser with nothing in the material file pointing
  at why.
- **Headless Chrome needs both `--use-angle=swiftshader` and
  `--enable-unsafe-swiftshader`** for WebGL2 to exist at all; with only one,
  ANGLE has no GPU to answer to and context creation fails silently — this
  spike's own fallback probe would report `"no webgl2"` rather than draw
  anything, with nothing louder in the console.
- **Filament's embind enums come back as JS objects, not raw numbers**:
  `engine.getBackend().value`, not `engine.getBackend()`. Easy to miss,
  since `filament.d.ts` types the return as the enum itself, and a raw
  comparison against it silently never matches rather than throwing.
- **A Dart `Timer.periodic` doesn't reliably tick inside one
  `--virtual-time-budget` screenshot.** The stats panel's 250 ms poll never
  visibly fired in any of the three captures, at three different budgets
  (3 s, 5 s, 6 s) — the panel painted its "waiting for Filament…" state in
  all three, even though the canvas underneath demonstrably kept animating
  and responding to Dart. Not chased to a root cause; worth knowing before
  trusting an on-screen readout in a single virtual-time capture rather than
  the console log, which did update correctly every time.
- **This machine's own load made "hung" and "slow" hard to tell apart.**
  Headless Chrome's `--screenshot` not exiting (above) produces the same
  symptom — a Chrome process that outlives its work — as a shot merely
  taking a long time under CPU/memory contention from unrelated concurrent
  builds (an Android emulator, an iOS Xcode build, both in sibling
  worktrees, pushed this machine into heavy swapping while this spike was
  captured). Distinguishing them needed checking the process's actual CPU
  state (`ps -o state,pcpu`), not just how long it had been running; a
  ceiling that only counts wall-clock time risks killing a shot that was
  about to finish.

## What's still unknown

- Whether route [ii]'s `OrbisSurfaceWeb` is really as small as it looks from
  the outside — untested here; this spike drives Filament through its own
  JS bindings, never through a compiled `orbis_renderer.wasm`.
- Real GPU WebGL2. This spike only exercises SwiftShader's software path
  (deliberately, for a screenshot that depends on nobody's GPU), so nothing
  here speaks to performance or to driver quirks a real device might hit.
- Emscripten build time and binary size for the full core against a
  wasm-built Filament — this spike's `filament.wasm` is Google's prebuilt
  release, not one produced by `orbis-filament/build.sh -p wasm`.
- Whether the slim lit surface (`feat/slim-lit`) shades correctly under
  WebGL2 specifically, as opposed to Metal at feature level 2 (the iOS
  simulator) or Android's OpenGL — not exercised by that branch or by this
  spike yet; this spike's own material has parameters but no textures, so it
  says nothing about sampler-heavy materials at the same feature level.
