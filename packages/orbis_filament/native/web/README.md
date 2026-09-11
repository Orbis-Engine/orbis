# Orbis renderer core — web

Stage one of taking Orbis's real renderer to the web: the portable C++ core
(`orbis::Renderer`, the C ABI, the portable platform layer) compiled to
WebAssembly with Emscripten, linked against a Filament built for the web,
drawing a frame into a `<canvas>` through nothing but `orbis_renderer.h` —
the same ABI `packages/orbis_filament/native/headless/` drives offscreen on
macOS. No Flutter anywhere in this directory.

This is the web counterpart of `native/headless/`, and reuses its shape
deliberately: the same portable `*.cpp` glob, the same "compile the core,
link Filament's own archives, done" structure, the same proof-by-screenshot
standard. What differs is only what a browser needs that a console host does
not — a WebGL 2 context and a canvas to draw into — and that turned out to
be more than expected (see "What did not work at first" below).

## Building it

### 1. Emscripten

```sh
git clone https://github.com/emscripten-core/emsdk "$ORBIS_CACHE/emsdk"
cd "$ORBIS_CACHE/emsdk"
./emsdk install 5.0.4
./emsdk activate 5.0.4
source ./emsdk_env.sh   # every shell that builds this
```

**5.0.4**, not "latest": `orbis-filament`'s own `build/common/versions` pins
`GITHUB_EMSDK_VERSION=5.0.4`, which is what its CI installs and what
`build.sh -p wasm` is proven against. `build/common/get-emscripten.sh` asks
that pinned emsdk tool for whatever it calls "latest" itself, which is a
moving target across a fresh emsdk checkout; installing 5.0.4 directly names
the same version without that drift.

### 2. Filament, built for wasm

In a worktree of the fork (never the main `orbis-filament` checkout):

```sh
git -C orbis-filament worktree add -b build/web \
  "$ROOT/.worktrees/filament-web" orbis-main
cd "$ROOT/.worktrees/filament-web"
source "$ORBIS_CACHE/emsdk/emsdk_env.sh"
export EMSDK="$ORBIS_CACHE/emsdk"
./build.sh -p wasm release
```

Took **12 minutes 55 seconds** on this machine (a build tools pass for
desktop first — `matc` and friends, needed by the build itself, not by this
package — then the actual wasm cross-compile: 903 ninja steps, mostly
Filament's own dependencies: abseil, draco, basisu, spirv-tools, zstd).
`out/cmake-wasm-release/` came to **53 MiB**; the ~120 `.a` archives this
package's `build.sh` actually links come to **14 MiB** of that.

One target failed and does not matter here: `web/filament-js/filament.js`
(Filament's own JS-bindings sample) would not link —
`em++: error: '--extern-post-js': file not found: '/Users/.../Orbis'` — a
pre-existing bug in `web/filament-js/CMakeLists.txt`, upstream of this work:
it builds `--extern-post-js` as one space-joined CMake string rather than a
list, and this checkout's path (`.../Personal/Orbis Project/...`) has a
space in it, so the linker sees the path split in two. Everything before
that link step — every static library this package needs, `libfilament.a`
through `libbasis_transcoder.a` — had already built successfully; this
build never uses `filament.js` (it has its own JS host, `host/main.js`, over
the C ABI instead), so the failure was left as found rather than patched.
One archive, `libfilament-iblprefilter.a`, had compiled its objects but not
yet been archived when ninja stopped on that unrelated failure; built
directly afterwards with `ninja libfilament-iblprefilter.a` in
`out/cmake-wasm-release`.

### 3. The core, for the web

```sh
cd "$ROOT/.worktrees/orbis-web-core"   # made by .worktrees/new_worktree.sh web-core
ORBIS_MATC_BACKENDS=opengl bash packages/orbis_filament/darwin/setup.sh
source "$ORBIS_CACHE/emsdk/emsdk_env.sh"
export EMSDK="$ORBIS_CACHE/emsdk"
export ORBIS_FILAMENT_WASM_SRC="$ROOT/.worktrees/filament-web"
bash packages/orbis_filament/native/web/build.sh
```

The first line matters: the renderer's compiled materials
(`generated/*_material.h`) carry shaders only for the backends
`ORBIS_MATC_BACKENDS` named, and the default is `metal` alone. WebGL 2 is
Filament's OpenGL backend, so this build needs `opengl` compiled in — `-p
all` (setup.sh's own default) already includes the ESSL/mobile shader
variant WebGL 2 needs, the same flag every other platform's materials use,
so nothing else about material compilation changes for the web.

### 4. A frame in the browser

```sh
cd packages/orbis_filament/native/web/host
python3 -m http.server 8899 --bind 127.0.0.1 &
# open http://127.0.0.1:8899/, or screenshot it headlessly:
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new \
  --use-angle=swiftshader --enable-unsafe-swiftshader \
  --user-data-dir="$(mktemp -d)" --virtual-time-budget=4000 \
  --screenshot=frame.png http://127.0.0.1:8899/
kill %1   # stop the server
```

Both `--use-angle=swiftshader` and `--enable-unsafe-swiftshader` are needed
together for WebGL 2 to exist at all in headless Chrome; a fresh
`--user-data-dir` keeps it clear of any Chrome already running; and Chrome's
`--screenshot` mode is not reliable about exiting on its own once its
virtual-time budget elapses, so an unattended script needs a watchdog around
it (`tool/capture.sh` in the merged web spike, `spike/web_canvas/`, has a
worked example — poll for the PNG, give it a couple of seconds to exit,
kill it past a hard ceiling).

## Sizes

| Artefact | Size |
|---|---|
| `host/orbis_renderer.wasm` | 14.7 MiB (unstripped; `-O2`, not `-O3`; every backend `matc` was told to compile, not opengl alone — see "What's left" below) |
| `host/orbis_renderer.js` | 117 KiB (Emscripten's glue: memory setup, `ccall`/`cwrap`, the GL emulation shim — no Embind, since this ABI is plain C) |
| `generated/` (compiled materials, this worktree) | 74 MiB on disk, both `metal` and `opengl` backends — recompiled `opengl`-only for a real build |
| Filament wasm archives actually linked | 14 MiB of `.a`, out of 53 MiB the full wasm build tree comes to |
| `native/web/build/` (this package's own `.o` files) | 13 MiB, 13 objects |
| emsdk 5.0.4 install | 1.9 GiB (toolchain + Node + Python it brings its own copies of) |

None of the above is committed: `build/`, `host/orbis_renderer.{js,wasm}`
and `captures/` are gitignored, same as `native/headless/build/`.

## What the browser drew

`captures/orbis_web_frame.png` — headless Chrome, the recipe above, a fresh
run against this build. Shows the same scene
`native/headless/orbis_headless.c` draws — a pale ground plane and five
cubes in the same five colours and relative sizes (the large green one is
the 0.9-scale block, the small purple one the 0.25-scale) — composited under
an on-page status panel built from the same ABI calls a Dart or Kotlin host
would use (`orbis_renderer_backend`, `orbis_renderer_notes`,
`orbis_renderer_note`), not a side channel into Filament:

```
backend: OpenGL (orbis_renderer_backend)
surface: ORBIS_SURFACE_WINDOW onto canvas selector "#canvas" (OrbisSurfaceWeb.cpp)
notes: 1
  [surface] This device supports Filament feature level 1, below the
  standard lit surface's third, so the slim surface is used instead. Base
  colour, normal, metallic/roughness, occlusion and emissive maps, ground
  blending and decals all draw as usual; rectangular area lights are not
  shadowed and the irradiance field does not light this scene.
```

The console (`captures/orbis_web_frame.log`) has Filament's and the
engine's own report of what it is running on, matching PORTING.md's
prediction exactly — this was proven, not assumed:

```
[WebKit], [WebKit WebGL], [OpenGL ES 3.0 (WebGL 2.0 (OpenGL ES 3.0 Chromium))], ...
Feature level: 1
Backend feature level: 1
FEngine feature level: 1
[orbis] engine ready in 0 ms, slim surface (feature level 1)
```

**Feature level 1, the slim surface, confirmed three ways that all agree**:
Filament's own two log lines, `orbis::Renderer`'s own startup log, and the
ABI's own `notes()` mechanism a host is meant to read this through — the
same "surface"/"areaShadows"/"field" note key `PORTING.md` documents for
Metal at feature level 2 on the iOS simulator, now also seen for real on
WebGL 2. Nothing this scene asked for was refused outright: no missing
texture, no unplayable video, no note beyond the expected surface one.

A bonus check, not load-bearing for the screenshot above but worth
recording: `orbis_renderer_request_capture` / `orbis_renderer_read_capture`
— the PNG-writing path `orbis_headless.c` uses — **also works** on this
`ORBIS_SURFACE_WINDOW` canvas chain (`read_capture: 2073600 bytes came back`
— exactly 960×540 RGBA8). `ORBIS_SURFACE_HEADLESS` cannot: see
`OrbisSurfaceWeb.cpp`, which documents why (Filament's `PlatformWebGL` never
implemented a windowless swap chain — "TODO: implement headless SwapChain"
in the fork's own source) and lets that surface allocate cleanly and then
fail, the ABI's ordinary "would not start" path, rather than crashing.

## What did not work at first

Two things `native/headless/build.sh`'s recipe did not need, both found by
testing rather than by reading documentation:

**No WebGL context existed until one was created explicitly.**
`Engine::create`'s first real GL call — `glGetString`, querying the version
— crashed in Emscripten's own `library_webgl.js` with `Cannot read
properties of undefined (reading 'getParameter')`. Confirmed directly
against the live page with `evaluate_script` (Chrome DevTools MCP) before
guessing at a fix: `Module.GLctx` was `undefined` at that point. Neither
Filament's `PlatformWebGL.cpp` (its `createSwapChain` just casts whatever
pointer it is given straight to `SwapChain*`, never touching WebGL) nor
Emscripten itself creates a context merely because `-sUSE_WEBGL2=1` was
linked and `Module.canvas` was set — Filament's own `filament.js` gets away
with this because its generated Embind glue creates the context through the
`html5.h` API before `Engine::create` ever runs, and this build has no
equivalent JS glue. Fixed in `orbis_web_host.cpp`:
`emscripten_webgl_create_context` + `emscripten_webgl_make_context_current`
on the given canvas selector, before the call through to the unchanged
`orbis_renderer_create`. Web-only bootstrapping, so it lives in this
web-only wrapper, not in the shared core.

**A thrown `utils::Panic` needs `-fwasm-exceptions` on the whole link, even
though Filament's own wasm archives are compiled with no exception flag at
all.** `Renderer::initWithWidth`'s `try`/`catch` around `startWithWidth()`
depends on catching exactly that. Proved with a two-file repro before
trusting it with the real renderer: a `throw` in an object file built with
zero exception flags, linked against a `catch` site and a final link both
built with `-fwasm-exceptions` — caught correctly. Without the flag anywhere
in the build, the same throw is an unhandled promise rejection and the
process is gone. `build.sh` passes `-fwasm-exceptions` to every translation
unit it compiles and to the final link.

A smaller, one-off gotcha while wiring up the build itself: a from-source
Filament build has no single merged `include/` tree the way the packaged
macOS/iOS SDK release does, so two headers needed their own `-I` beyond what
`darwin/setup.sh`'s SDK-based convention expects —
`out/cmake-wasm-release/filament` (generated headers alongside
`filament/include`) and `out/cmake-wasm-release/libs`
(`gltfio/materials/uberarchive.h`, generated at build time under
`libs/gltfio/materials/`, not nested inside an `include/` directory).
`build.sh`'s `INCLUDES` array has both, with a comment at each explaining
why it is not where the plain source headers are.

## What compiled unchanged, and what did not

Every plain C++ file `native/headless/build.sh` compiles — the core
(`OrbisRendererCore.cpp`, 258 KB, ~5,800 lines), the C ABI
(`OrbisRendererC.cpp`), `OrbisPlatform.cpp`, `OrbisBackend.cpp`,
`OrbisDecals.cpp`, `OrbisMotionBlur.cpp`, `OrbisOutline.cpp`,
`OrbisShadows.cpp`, `OrbisSplatSet.cpp`, `OrbisSplats.cpp`,
`ScreenEffects.cpp` — compiled for `emcc` **with no source change**, same as
`PORTING.md` found for the portable build generally. `OrbisBackend.cpp`
already had an `__EMSCRIPTEN__` branch choosing `ORBIS_BACKEND_OPENGL` (it
was written for this before this package existed), so backend selection
needed nothing new either. `OrbisPlatform.cpp`'s `parallelFor` uses
`std::thread`, untested for Emscripten until now: confirmed by testing that
it compiles and links with no `-pthread` at all, and that
`hardware_concurrency()` reports 1 under Emscripten without it — so the
function's own `workers <= 1` fallback takes the plain sequential loop, and
no `std::thread` is ever actually constructed at runtime.

**Not compiled**: `OrbisSurfaceHeadless.cpp`. Its `OrbisCreateHeadlessSurface`
and `OrbisCreateWindowSurface` are exactly the two functions
`OrbisSurfaceWeb.cpp` (this directory) provides instead — both defining
the same two names would not link. Everything Apple-specific
(`OrbisPlatformApple.mm`, `OrbisSurfaceApple.mm`, the Objective-C wrapper)
was already excluded by the `*.cpp` glob, as on every portable build.

**No hunk was needed in any shared source file.** The two new files this
work added — `OrbisSurfaceWeb.cpp`, `orbis_web_host.cpp` — live in this
directory, not beside the renderer, and nothing under
`Sources/orbis_filament_native/` was edited.

## The web surface

`OrbisSurfaceWeb.cpp` implements `OrbisCreateHeadlessSurface` and
`OrbisCreateWindowSurface`, worked out from Filament's own web pieces rather
than guessed:

- `filament/backend/src/opengl/platforms/PlatformWebGL.cpp` (the fork):
  `createSwapChain(void *nativeWindow, uint64_t)` is
  `static_cast<SwapChain*>(nativeWindow)` and nothing else — the pointer is
  never dereferenced, only carried as an opaque identity. Its sized overload
  — the one a headless surface needs — is unimplemented and always returns
  null.
- `web/filament-js/jsbindings.cpp`'s `_createSwapChainForCanvas`:
  `engine->createSwapChain((void*)persistentCanvasId->c_str())` — the
  canvas's CSS selector, handed across as that pointer, kept alive for the
  swap chain's life (`persistentCanvasId` is deliberately leaked there for
  exactly that reason).

So `OrbisSurfaceWeb.cpp`'s `WebCanvasSurface` does the same: `"window"` in
`orbis_surface_desc` is a canvas selector string (`orbis_web_host.cpp`'s
`orbis_web_create_on_canvas` builds one from a plain `const char *`, so a
JavaScript host never has to). `ORBIS_SURFACE_HEADLESS` allocates the
surface object cleanly and then fails at `allocate()` with a null chain —
there being nowhere else for it to go on this backend — which is the ABI's
ordinary "the renderer would not start" path, not a crash.

## What remains for stage two

A Flutter web implementation of the `orbis_filament` plugin:

1. **`dart:ffi` is unconditional today.** `packages/orbis_core/lib/src/
   world.dart`, `bindings.dart`, `packages/orbis_native/lib/src/host.dart`
   and `script.dart` all `import 'dart:ffi'` with no conditional import —
   `dart:ffi` does not exist for the web compiler. Each needs its FFI-backed
   half split out behind `dart.library.ffi` vs. `dart.library.js_interop`
   (or a `dart.library.io` default with a web override). `bindings.dart`'s
   `OrbisTransformsStruct` and `host.dart`'s `OrbisScriptHost` `extends
   Struct`: there is no memory to lay a `Struct` over on the web, so the web
   side re-expresses the same rows as encoded bytes, the way
   `host/main.js`'s `allocF32`/`allocI32`/`allocI64` do here in JavaScript
   — a Dart equivalent is `dart:js_interop`'s typed-array views over the
   module's `HEAPU8`.
2. **An `HtmlElementView` over a real `<canvas>`**, registered with
   `ui_web.platformViewRegistry.registerViewFactory` — the merged web spike
   (`spike/web_canvas/lib/filament_canvas.dart`) already proved this shape
   and its two gotchas: a platform view's element is detached when its
   factory callback runs (poll with `requestAnimationFrame` until it is
   actually laid out before creating anything on it), and Flutter resizes
   the view's CSS box but never the canvas element's backing-store
   `width`/`height` — something has to match those to
   `canvas.clientWidth/Height * devicePixelRatio` every frame.
3. **The scene crossing by `dart:js_interop`, not `dart:ffi`**, into this
   module's exported `orbis_renderer_*` functions via `ccall`/`cwrap` —
   `host/main.js`'s `publishScene` is that shape already, minus the Dart
   side. `orbis_web_create_on_canvas` (`orbis_web_host.cpp`) is there
   specifically so the Dart side never has to build an `orbis_surface_desc`
   by hand either.
4. **Loading `orbis_renderer.js`/`.wasm` from Flutter web's build output.**
   Untested here: whether they belong under `web/` (copied verbatim into
   `build/web/` the way the spike copies `filament.js`/`.wasm`) or need
   something more — bundler interaction, CORS/MIME on whatever serves
   `build/web` in production, and multi-instance behaviour if a page ever
   wants more than one renderer (this build assumes one `Module.canvas` per
   loaded module instance; untested whether loading the module twice for
   two canvases works or needs a second `<script>` load).
5. **Trimming `orbis_renderer.wasm`.** 14.7 MiB unstripped, materials
   compiled for both `metal` and `opengl` in this worktree's local cache (a
   real web build only needs `opengl`, which alone should noticeably
   shrink it — `PORTING.md`: 3.32 MiB embedded for OpenGL alone against
   4.70 for Metal, for comparison, though that is `-a all -p all` across
   every material this package has, not this specific link's subset).
   `-O3`, `wasm-opt`, and Closure Compiler on `orbis_renderer.js` (currently
   plain `-O2`, no `--closure`) are all unexplored.

## Stage two, as built

The five items above, answered. The plugin is `lib/src/web/` in this
package; the gallery runs it at `examples/gallery` with
`tool/capture_web.sh` for a screenshot.

1. **`dart:ffi` splits — done where they actually blocked, and narrower
   than expected.** `orbis_filament/lib` turned out to import neither
   `dart:ffi` nor `dart:io` and to depend on no other Orbis package, and
   `orbis_core`/`orbis_native` are not reachable from the gallery at all
   (`orbis_examples` depends on `orbis_filament`, `orbis_camera`,
   `orbis_weather`, `orbis_noise`; the gallery's `pubspec.lock` has no
   `orbis_core` entry). So those two packages were left alone: splitting
   them is still worth doing for their own sake, but nothing on the way to
   a drawing web app needs it. What did block, and is done: `Int64List`
   (`lib/src/key_list.dart`), the seven examples that read a file
   (`orbis_examples/lib/src/platform/io.dart`) and the gallery's
   environment reading (`examples/gallery/lib/orbis_env.dart`).
2. **`HtmlElementView` over a real `<canvas>` — done**, with both gotchas
   the spike predicted: `OrbisWebViewport._whenLaidOut` polls with
   `requestAnimationFrame` until the element is attached and measured
   before creating anything, and `_fitBackingStore` matches the canvas's
   `width`/`height` to `clientWidth/Height * devicePixelRatio` every frame.
   The viewport is found through the view's creation params, because a
   platform view's own id is minted by Flutter and never reaches a plugin.
3. **The scene crossing by `dart:js_interop` — done.**
   `orbis_scene_web.dart` makes all twenty-two scene calls in the order
   `Viewport.write(scene:)` and `OrbisScene.applyTo` use; `OrbisHeap`
   copies each array into the module's heap, int64 keys as little-endian
   low/high pairs. No web-specific entry point was added to the core: the
   only non-`orbis_renderer.h` call is stage one's own
   `orbis_web_create_on_canvas`.
4. **Loading from Flutter web's build output — done, and it is just
   `web/`.** `orbis_renderer.js` and `.wasm` copied beside `index.html` are
   copied verbatim into `build/web`, with a plain synchronous `<script>`
   tag so the global exists before any Dart runs. Both are gitignored,
   like every other build artefact here. No bundler interaction, no MIME
   or CORS trouble from `python3 -m http.server`. **Untested:** more than
   one renderer on a page. The plugin loads one module instance per
   canvas, which is what `Module.canvas` requires, but two at once has
   never been run.
5. **Trimming — partly, and not by tuning.** 7.79 MiB (8,164,872 bytes)
   against stage one's 14.7, purely because these materials carry only the
   `opengl` backend rather than `metal` and `opengl` both. `-O3`,
   `wasm-opt` and Closure are still unexplored.

### The one thing that does not look right

Lit surfaces draw black. Geometry, camera, sky, and the whole message
arrive correctly — every one of the twenty-two calls returns `ORBIS_OK`,
and the values were read back at the boundary and checked against the
scene that produced them (the floor's colour arrives as its exact
linearised `0xFF3B424C`, its flags as receive|visible, the sun as 82000 lux
in the right direction, exposure as 16 / 1/125 / 100). Skipping the render
graph, pipeline, post, environment, field or sky changes nothing about it,
and raising a light to 200000 lumens changes nothing either.

So this is not the Dart side mis-marshalling anything, and it is not this
plugin at all: it reproduces in stage one's own JavaScript host, which has
no Flutter and no Dart anywhere in it.

**Direct lights contribute nothing on this build. Only ambient does.**
Measured by serving `host/main.js` unchanged but for its ambient, against
this same `orbis_renderer.wasm`:

| `host/main.js` ambient | centre pixel |
|---|---|
| 24000, as committed | (210, 213, 171) |
| 0 | (0, 0, 0) |

That scene's sun is 100000 lux and did not move between the two runs, so if
analytic lighting reached a surface at all the second row could not be
black. The frame this directory's README calls proof of stage one is lit
entirely by its ambient — which is why it looked right and the gallery does
not: 24000 against bright albedos, where the Surface example has 9000
against a 0.05 floor, about a thirtieth of correct exposure.

The gap is therefore in the renderer or in the slim surface at feature
level 1, upstream of everything here; nothing in this directory or in
`lib/src/web/` can close it. What it wants next is the same scene on
Android's OpenGL ES — the other feature-level-1 host, and the one place the
same question can be asked without a browser in the way.

## What this proves, in one line

The same `OrbisRendererCore.cpp` that draws on macOS and the iOS simulator
drew a frame in a browser tab through its own C ABI, unmodified, at the
feature level `PORTING.md` predicted, reporting that through the same
mechanism every other host reads it through — with the whole gap between
"the core is portable" and "a browser draws it" turning out to be two small,
web-specific, testable fixes (a WebGL context, an exception-handling flag),
not a rewrite.
