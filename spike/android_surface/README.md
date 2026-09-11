# Android spike: Filament in a Flutter texture

Status: builds, installs, and renders on the emulator under both backends.
Read the commits (`git log --oneline`) before trusting any one claim in
isolation — this was built and verified incrementally, and each commit says
what was true at that point.

## What this proves

Filament 1.76 can draw into an Android `Surface` that Flutter's texture
registry owns, with nothing copied through the CPU, and the result composites
correctly alongside ordinary Flutter widgets. That was the actual risk in
bringing Orbis to Android — the Apple path proved Filament-into-Flutter works
at all (`spike/cube_to_pixelbuffer.mm`, CPU-side `CVPixelBuffer`), but Android
has no equivalent handoff. This spike proves the Android-shaped one instead:
a producer/consumer `Surface` Flutter hands out and Filament writes into
directly.

## The presentation path, step by step

1. Dart calls `FilamentSurface.start(backend: ..., width: ..., height: ...)`,
   a method channel call to `"filament_surface"` handled by
   `FilamentSurfacePlugin.onMethodCall`.
2. The plugin creates a `FilamentSurfaceSession` and calls `start()` on it.
   That calls `TextureRegistry.createSurfaceProducer()` — this registers a
   texture with the Flutter engine and returns a
   `TextureRegistry.SurfaceProducer` whose `id()` is what Dart's
   `Texture(textureId:)` widget names.
3. `producer.surface` is an `android.view.Surface`: the producer end of a
   buffer queue whose consumer is the Flutter compositor.
4. JNI passes that `Surface` (as a `jobject`) to
   `ANativeWindow_fromSurface(env, surface)` (`spike_renderer.cpp`), giving
   native code an `ANativeWindow*`.
5. `engine->createSwapChain(window)` builds an `EGLSurface` (OpenGL ES) or a
   `VkSurfaceKHR` (Vulkan) on it — the same call either backend accepts,
   because Filament's `createSwapChain(void* nativeWindow, uint64_t flags)`
   doesn't care which.
6. Every frame: `Choreographer.doFrame(frameTimeNanos)` →
   `SpikeRenderer.nativeRender(handle, frameTimeNanos)` →
   `renderer->beginFrame(swapChain, frameTimeNanos)` /
   `renderer->render(view)` / `renderer->endFrame()`. `endFrame()` queues a
   buffer; `producer.scheduleFrame()` (called right after a successful
   `nativeRender`) tells Flutter there's something new to composite.

No pixel is read back and no copy is made anywhere in this path. That's the
point, and it's why this is a different mechanism from Apple's
`CVPixelBuffer` path rather than a port of it — see the OrbisSurface verdict
below for how that difference does and doesn't matter to the portable core.

### Lifecycle: what was verified, what wasn't

`FilamentSurfaceSession` implements
`TextureRegistry.SurfaceProducer.Callback` (`onSurfaceAvailable` /
`onSurfaceCleanup`, Flutter 3.47's current names; the deprecated
`onSurfaceCreated`/`onSurfaceDestroyed` spellings are also implemented and
forward to the same handlers, in case the running engine calls the older
pair). On `onSurfaceCleanup` it calls `SpikeRenderer.nativeDetachSurface`,
which:

```cpp
mEngine->destroy(mSwapChain);
mSwapChain = nullptr;
mEngine->flushAndWait();      // <-- blocks until the driver has actually let go
ANativeWindow_release(mWindow);
```

The `flushAndWait()` matters and was not obvious going in: `Engine::destroy()`
only *queues* the destruction onto Filament's driver thread. Releasing the
`ANativeWindow` before that drains is a use-after-free — an
`eglDestroySurface` crash, or a swap chain that's silently dead on the next
attach — because Flutter destroys the `Surface` as soon as the callback
returns, and a driver still holding it at that point is exactly the crash.
On `onSurfaceAvailable`, `attach()` re-runs the same
`ANativeWindow_fromSurface` → `createSwapChain` sequence against whatever
`Surface` the producer is now handing out, and the Choreographer loop (which
stops itself while there's no surface) restarts. Engine, scene, materials,
buffers — everything but the swap chain and the window — survive the whole
cycle untouched, which is the thing that has to be true for backgrounding not
to cost the whole scene.

What was actually exercised, honestly:

- **The code path itself**: it compiles against Flutter 3.47's real
  `TextureRegistry.SurfaceProducer.Callback` interface, so the method
  signatures and the four-callback shape are correct for this Flutter
  version, not guessed at.
- **Real backgrounding (HOME key)**: tested twice, both times bringing the
  app back to the foreground afterward. Neither `onSurfaceAvailable` nor
  `onSurfaceCleanup` fired — `surfaceAvailableCount`/`surfaceCleanupCount`
  stayed at 0, and `adb shell dumpsys activity activities` showed the task
  simply "brought to the front" rather than the activity being recreated.
  On this Flutter 3.47 / Android 16 combination, the `SurfaceProducer`'s
  buffer queue survives simple backgrounding — it is not torn down just
  because the app loses the foreground. That's worth knowing going in: the
  callback path needs a stronger trigger than "the user pressed home" to
  exercise, at least on this setup.
- **The forced path was not exercised**, and this is a real gap, not a
  glossed-over one. `FilamentSurfaceSession.recreateSurface()` — wired to
  the in-app "Recreate surface" button — calls
  `TextureRegistry.SurfaceProducer.getForcedNewSurface()`, which is
  Flutter's own documented "throw this one away and make me another," i.e.
  exactly the scenario `onSurfaceCleanup`/`onSurfaceAvailable` exist for.
  Across many attempts, on three different emulator configurations, with
  coordinates re-derived directly from fresh screenshots each time,
  `adb shell input tap`/`swipe` on that button (and the neighboring "Back"
  button) never registered — `forcedReattachCount` stayed at 0 and the app
  stayed on the renderer screen every time. The same kind of synthetic tap
  *did* work reliably on the picker screen, before any render loop was
  running, and a hardware `KEYCODE_BACK` reached the app and exited it (to
  the launcher) even while Filament was actively rendering — so this isn't
  a general input freeze, and it wasn't simply performance: the last several
  attempts were on a config with the worst frame interval down under 1s
  (from over 2.6s earlier), and the result didn't change. Root cause not
  isolated in the time available. **Recommendation for whoever picks this
  up**: test that button on a real device, or drive it through Flutter's
  `integration_test`/Patrol (which calls into the widget tree directly)
  rather than OS-level synthetic touch injection, before concluding anything
  about whether the forced-reattach path itself works.

## What the Kotlin/JNI plugin forwards from the Dart method channel

The channel (`"filament_surface"`) is deliberately thin — see the class
comment on `FilamentSurfacePlugin`. No per-frame traffic crosses it; the
render loop is entirely native (see "Choreographer, not Flutter's frame
callbacks" below). What crosses is control and polled diagnostics:

| Method | Args | Forwards to |
|---|---|---|
| `start` | `backend` ("opengl"/"vulkan"), `width`, `height`, `requestFeatureLevel3` | `FilamentSurfaceSession.start()` → `SpikeRenderer.nativeCreate` |
| `stop` | — | `session.stop()` → `nativeDestroy` |
| `resize` | `width`, `height` | `session.resize()` → `nativeResize`, and a swap-chain rebuild if the producer handed out a new `Surface` |
| `recreateSurface` | — | `session.recreateSurface()` → forced detach/reattach (see above) |
| `describe` | — | backend, feature levels, size, surface-lifecycle counters |
| `stats` | — | rendered/skipped frame counts, mean/worst interval, fps |

A real plugin's channel would look the same shape — thin control surface,
native render loop — but `start`'s job changes from "build one hardcoded
cube" to "create an `orbis_renderer` and publish a scene": the JNI layer
would call `orbis_renderer_create` with an `ORBIS_SURFACE_WINDOW` descriptor
instead of `SpikeRenderer::create`, and the per-scene calls
(`orbis_renderer_apply_objects`, `_apply_materials`, `_set_camera`, ...) would
arrive over additional channel methods this spike has no reason to have. The
presentation-lifecycle calls (attach/detach a surface across backgrounding)
are the one piece with no equivalent yet on the `orbis_renderer.h` side — see
the verdict below.

### Choreographer, not Flutter's frame callbacks

`FilamentSurfaceSession` drives rendering from
`Choreographer.postFrameCallback`, not `SchedulerBinding.addPostFrameCallback`
on the Dart side. Three reasons, in order of how much they'd bite:

- `beginFrame()` wants a real vsync timestamp; Choreographer hands one
  straight to `doFrame`, and Flutter's frame callback gives a `Duration`
  since engine start — a different clock entirely.
- The texture is an independent producer/consumer pair. Flutter composites
  whatever the buffer queue last accepted, so the render loop doesn't need
  to be in lockstep with Flutter's build/paint, and coupling them would let
  a slow Dart frame stall the renderer for no reason.
- Driving from Dart means a platform-channel round trip every frame — at
  60 Hz, a message every 16 ms carrying nothing, to start work the native
  side could start itself.

## Gradle/CMake settings that mattered

- **ABI filter**: `arm64-v8a` only
  (`filament_surface/android/build.gradle.kts`). Matches this emulator and
  every device worth profiling; the release ships `armeabi-v7a`, `x86` and
  `x86_64` too, and `CMakeLists.txt` already picks the lib directory by
  `${ANDROID_ABI}`, so adding them back is one line.
- **NDK version**: pinned to `28.2.13676358`, not inherited. Filament's
  Android release is built with a recent NDK, and this is also Flutter
  3.47's own default — confirmed by building cleanly against it with no
  second NDK fetched and no version-mismatch symptom anywhere in this
  session.
- **Static link order**: Filament ships as static archives with circular
  dependencies between them (`filament` needs `backend`, `backend` needs
  `utils` and `filabridge`, `bluevk` is pulled in from inside `backend`).
  `-Wl,--start-group … -Wl,--end-group` around the whole list makes `ld`
  rescan until it settles, so the list itself can stay in a readable order
  rather than a load-bearing one.
- **`-Wl,--no-undefined`**: turns a missing symbol into a build failure
  instead of a `dlopen` crash on the device that names one symbol and not
  the library it came from. This is not a hypothetical benefit — it is
  exactly what happened this session: Filament 1.76's `MaterialParser`/
  `ZstdHelper` decompress the `.filamat` package with `zstd` unconditionally,
  and the first build failed at link time on `ZSTD_getFrameContentSize`/
  `ZSTD_isError`/`ZSTD_decompress` because `libzstd.a` (present in the
  release) wasn't in the link list yet. Caught at build time, fixed by
  adding it; would otherwise have been a runtime crash with a confusing
  symbol name and no obvious library to blame.
- **STL choice**: `ANDROID_STL=c++_static`, not `c++_shared`. Correct here
  because there is exactly one native library in this `.apk` — nothing to
  share `libc++_shared.so` with, and static avoids shipping it plus the
  whole class of bug where two libraries disagree about which `libc++` they
  linked. This stops being automatically correct the moment a *second*
  native `.so` joins it (e.g. `orbis_native` built separately from this
  Filament-linking one) and they pass C++ types — `std::string`, an
  exception — across the boundary between them: two static `libc++` copies
  in one process is undefined behaviour for that. If the real plugin keeps
  Orbis's core and Filament in one combined `.so` (as this spike does with
  everything it links), `c++_static` stays fine regardless of how much
  Orbis code that `.so` grows to hold.
- **Two flags judged and removed**: `-ffunction-sections -fdata-sections`
  plus `-Wl,--gc-sections` were in the CMakeLists this spike inherited,
  justified there as taking the `.so` from ~90 MB to ~9 MB. Judgment: risk
  for little gain, and removed. The gain is real but irrelevant — a spike
  proving a pipeline works is never shipped or measured for size. The risk
  is not hypothetical scaremongering either: dead-code stripping across a
  `--start-group`/`--end-group` set of huge prebuilt archives, linked for
  Android for the first time in this codebase, is exactly the kind of change
  that can silently drop a section reached only indirectly (a vtable, a JNI
  export, `bluevk`'s `dlsym`'d Vulkan function table) and surface later as a
  crash with no visible connection back to the flag that caused it. Every
  other flag in the file earns its keep against what *this spike* is
  actually for; these two didn't, so they came out. (Separately, and not the
  same finding: the Gradle `packaging.jniLibs.keepDebugSymbols` block had an
  inverted effect from its own comment — it listed `liborbis_spike.so` as a
  library to leave *unstripped*, which is what `keepDebugSymbols` means,
  while the comment claimed it was *shrinking* the library. Fixed by
  deleting the block; AGP already strips by default, which is what the
  comment actually wanted.)

## Backends tried

Both built, installed, and rendered — a rotating six-colour cube, teal
skybox visible around it, a Flutter-drawn label composited crisply over the
top, verified across paired screenshots roughly a second apart showing
different cube faces (proving rotation, not a static frame).

### OpenGL ES

```
Filament: [Android Emulator OpenGL ES Translator (ANGLE (..., SwiftShader Device ...))],
          [OpenGL ES 3.1 (OpenGL ES 3.1.0 (ANGLE ...))], [OpenGL ES GLSL ES 3.10]
Filament: Feature level: 1
OrbisSpike: engine up: backend=OpenGL activeFeatureLevel=1 supportedFeatureLevel=1
```

Worked cleanly, no black frames, no errors. Frame timing was the weakest
part of the run and is a property of this emulator's software GL path, not
of the presentation code: worst single-frame interval ranged 500 ms–2.6 s
across different runs (almost always the *first* frame after attach — shader
compilation and pipeline setup on a software rasterizer — with steady state
settling to a real, if middling, ~20 fps once warmed up).

### Vulkan

```
Filament: Vulkan device driver: SwiftShader driver
Filament: Selected physical device 'SwiftShader Device (LLVM 10.0.0)' ... api 1.3
Filament: Backend feature level: 3
OrbisSpike: engine up: backend=Vulkan activeFeatureLevel=1 supportedFeatureLevel=3
```

Also worked cleanly. Noticeably *better* than OpenGL ES on this emulator once
running: fps=48.6, worst frame 183 ms, vs. OpenGL's fps~20–23 and worst-frame
500 ms–2.6 s across the runs measured. `bluevk`'s runtime `dlopen` of
`libvulkan.so` succeeded without incident (`libvulkan.so` is present on this
system image).

## Feature level — the central question, answered plainly

Orbis's standard lit surface needs feature level 3 (twelve samplers: seven
maps, light data, the area shadow, the field atlas, two for decals — per
`PORTING.md`). Below that, per `PORTING.md`, the renderer does not start.
What this emulator actually does, verified rather than assumed, backend by
backend:

| Backend | `supportedFeatureLevel` | `activeFeatureLevel` (no request) | `activeFeatureLevel` (FL3 requested) |
|---|---|---|---|
| OpenGL ES | 1 | 1 | **1** — request silently not honoured, engine still builds |
| Vulkan | 3 | 1 | **3** — engine actually builds and runs at level 3 |

**Plain statement**: on this emulator, OpenGL ES cannot reach the feature
level the standard lit surface needs — full stop, it is a hard ceiling, not
a driver quirk to work around. Vulkan can: `Engine::getSupportedFeatureLevel()`
said 3, and — this is the part worth stressing, because a reported ceiling
is not proof — asking `Engine::Builder::featureLevel(FEATURE_LEVEL_3)` for
it outright and calling `build()` actually produced an engine running at
level 3, not a null engine or a silent downgrade. Confirmed with a second,
purpose-built check (`requestFeatureLevel3`, added to this spike specifically
to answer this): the cube rendered correctly at feature level 3 under
Vulkan, with the skybox and the label composited exactly as at level 1. So
on Android, backend choice is not a minor performance knob for Orbis — it is
the difference between the real renderer starting at all and refusing to.
`orbis::backendCandidates` (`OrbisBackend.cpp`) already tries Vulkan before
OpenGL ES on Android for other reasons (a stated preference, not yet tested
against this specific question); this spike's finding is a second, sharper
reason that ordering matters here, provided the standard surface is what's
being loaded.

**One assumption corrected along the way**: requesting `FEATURE_LEVEL_3`
does *not* make `Engine::Builder::build()` fail when the backend's ceiling is
lower — tested directly (`requestFeatureLevel3` against OpenGL ES): the
request was logged, `Engine::build()` succeeded anyway, and
`getActiveFeatureLevel()` came back 1, same as never asking. It rendered
fine. So the failure `PORTING.md` describes ("the renderer does not start")
is not at engine construction — it must be further down, when a material
that actually declares `featureLevel : 3` is loaded into an engine running
below that (`matc` enforces the sampler-count rule against that declaration
at compile time; the runtime equivalent would be `Material::Builder().build()`,
or the `RenderableManager` built from it, refusing on a too-low engine).
This spike's own material (`unlit_colour.mat`) declares no feature level, so
it never exercises that specific runtime failure — worth checking directly,
with an actual level-3 material, once the real integration has one running
on Android. Filed as a corrected assumption, not a solved question.

## Verifying on the emulator

`flutter build apk --profile --target-platform=android-arm64 --split-per-abi`
(not `--debug` — see "APK size" below), `adb install -r`, `adb shell am
start -n dev.orbis.spike.android_surface_spike/.MainActivity`, then
`adb exec-out screencap -p > frame.png`, read with the Read tool. Two
captures roughly a second apart show different cube faces each time (proof
of animation, not just a colourful static frame); `adb logcat -s
OrbisSpike:V Filament:V` carries the backend/feature-level lines quoted
above. Frame timing comes straight off the device via the `stats` method
call, shown live in the app's own overlay (`fps`, `rendered`, `skipped`,
`worstFrameIntervalMs`) as well as loggable on demand — no separate profiling
tool needed for the numbers quoted in this document.

## Gotchas, roughly in the order they were hit

1. **`libzstd` missing at link time** — `-Wl,--no-undefined` caught it
   immediately as a build failure naming the exact missing symbols, rather
   than a device-side `dlopen` crash. See "Gradle/CMake settings" above.
2. **`keepDebugSymbols` inverted from its own comment** — listed the one
   library to *keep* unstripped while claiming to shrink it. Fixed by
   deleting the block.
3. **Two flags removed as risk-for-no-gain**
   (`-ffunction-sections`/`-fdata-sections`/`-Wl,--gc-sections`) — see
   "Gradle/CMake settings" above; this is the note referenced in the task.
4. **Texture aspect ratio vs. camera framing**: requesting a texture sized to
   the full (tall, narrow) phone screen made the cube overflow the camera's
   frustum on its short axis and fill the frame edge to edge at some
   rotations — no visible skybox border at all, which defeats the one thing
   the skybox is *for* (telling "the render path works, cube or no cube"
   apart from "nothing drew"). The scene in `spike_renderer.cpp` is framed
   for a roughly square view; fixed on the Dart side by requesting a square
   texture (`physicalSize.shortestSide`) and centering it with `AspectRatio`
   rather than stretching or cropping it to fill a taller box.
5. **Debug APK size vs. emulator disk space**: `flutter build apk --debug`
   produced a 153 MB fat APK (three ABIs of `libflutter.so`, a bundled
   Vulkan validation layer, an uncompiled JIT kernel blob) that wouldn't
   install — `INSTALL_FAILED_INSUFFICIENT_STORAGE` — on the (unrelated,
   shared) unrelated emulator this session started on, which was already
   94% full from other projects' test apps. `--target-platform=android-arm64
   --split-per-abi` cut it to 80 MB (single ABI); still too big for that
   emulator's disk. `--profile` (AOT-compiled Dart, no JIT snapshot, no
   bundled validation layer) got it to ~30 MB, which is what every
   functional test in this document used. None of this touches the native
   Filament path — it's a Dart compilation-mode question, orthogonal to
   whether the renderer works — but it blocked getting anything running at
   all until diagnosed, so a real CI/dev-loop config for this plugin should
   default to profile or release builds for on-device verification, and fat
   multi-ABI debug APKs to local `flutter run` only.
6. **Shared emulator too full to use**: rather than clear space on the
   pre-existing `Medium_Phone_API_36.0` AVD (which had other projects'
   apps on it, not mine to remove), created a dedicated one
   (`orbis_spike_arm64`, 8 GB data partition) and left the shared one
   untouched.
7. **Emulator GPU mode is a real tradeoff, not a default to ignore**:
   `-no-window -gpu auto` silently resolved to `swiftshader_indirect`
   (software rendering) and, combined with the AVD's default single vCPU,
   left the guest CPU-bound enough to produce >1 s single-frame stalls and
   (see the lifecycle section) taps that never reached the renderer screen's
   buttons. `-gpu host` (real GPU passthrough via the host's Metal) fixed
   performance and input responsiveness immediately, but broke
   `screencap`/`exec-out screencap` outright — a blank white PNG every time,
   reproduced with two different capture methods — on this headless,
   windowless configuration. Since this document's whole evidentiary basis
   is screenshots, working capture won out: settled on `swiftshader_indirect`
   explicitly plus `-cores 4`, which fixed most of the responsiveness
   problem (worst frame interval down from >2.6 s to under 1 s; picker-screen
   taps became reliable) without losing `screencap`. Whoever automates this
   next should budget time to find a config that has neither problem, or
   accept this tradeoff and know why.
8. **JNI name mangling for an underscore in the package name**:
   `dev.orbis.spike.filament_surface` → `Java_dev_orbis_spike_filament_1surface_...`
   (JNI escapes `_` in a Java identifier as `_1`). Correct in the code as
   found; noted here because it is the easiest way to get a silent
   `UnsatisfiedLinkError` on first run if the package or class is ever
   renamed without updating the C++ side to match.

## The `OrbisSurface` verdict

Read: `orbis_renderer.h`, `OrbisSurface.h`, `OrbisPlatform.h`, `PORTING.md`
(`packages/orbis_filament/darwin/orbis_filament/Sources/orbis_filament_native/`
in the `orbis-integration` worktree), plus `OrbisSurfaceHeadless.cpp` and
`OrbisRendererC.cpp`/`OrbisRendererCore.h` to see how `ORBIS_SURFACE_WINDOW`
is actually wired today.

**The swap-chain creation itself fits Android exactly as written, no changes
needed.** `OrbisCreateWindowSurface(void* window)` is already portable C++
(it lives in `OrbisSurfaceHeadless.cpp`, not an `Apple.mm` file, and includes
nothing platform-specific), and its window branch —

```cpp
_chain = _window != nullptr
    ? engine->createSwapChain(_window, 0)
    : engine->createSwapChain(width, height, filament::SwapChain::CONFIG_READABLE);
```

— is the identical call this spike makes directly with an `ANativeWindow*`
cast to `void*`. A real Android JNI/C++ plugin would call
`orbis_renderer_create(backend, &(orbis_surface_desc){ORBIS_SURFACE_WINDOW,
nativeWindow}, width, height)` and get exactly the presentation path this
spike proved, for free. The `count`-buffers shape of `OrbisSurface::allocate`
looks at first glance like it might not fit Android (Apple's path needs
several independent `CVPixelBuffer`s because render and present run on
different threads there), but it already doesn't need to: for a window,
`SharedChainSurface` hands the *same* chain out for every slot regardless of
`count`, which is the right answer on Android too — a single `ANativeWindow`'s
buffer queue is already multi-buffered by the system compositor, so wanting
`count` independent `ANativeWindow`-backed swap chains was never the right
model there in the first place. Good design already, not something this
spike had to work around.

**What's missing is entirely at the layer above it: surface lifecycle.**
`orbis_renderer.h` has a create call and a `resize` call and nothing
in between for "the window changed." `OrbisRendererCore.h` confirms why: `
_surface` and `_swapChains[kOrbisBufferCount]` are private members wired up
once, in the constructor and `initWithWidth`, and `resizeToWidth` only ever
touches dimensions — never the surface or swap chains themselves. That
model is correct for Apple, where the texture-sharing surface is stable for
the renderer's whole life. It is not correct for Android, where — as this
spike's own `SpikeRenderer::attachSurface`/`detachSurface` exists specifically
to handle — the `Surface` can be destroyed and replaced any number of times
while the engine, scene and every GPU resource in it need to survive
untouched. There is no `orbis_renderer_attach_surface`/`_detach_surface` (or
equivalent) in the C ABI to call when that happens.

The fix is additive, not a redesign: a new pair of calls —

```c
int orbis_renderer_attach_surface(orbis_renderer *renderer,
                                   const orbis_surface_desc *surface,
                                   uint32_t width, uint32_t height);
int orbis_renderer_detach_surface(orbis_renderer *renderer);
```

— doing at the `orbis::Renderer` level exactly what `SpikeRenderer`'s two
methods already do: `detach` destroys the swap chain(s) via `OrbisSurface::
release`, calls `engine->flushAndWait()` (the ordering this spike found is
load-bearing — see "Lifecycle" above — and that the core does not currently
know it needs), *then* lets go of the window; `attach` calls `OrbisSurface::
allocate` again against the new window and rebuilds the swap chain(s) into
`_swapChains`. `orbis_renderer.h`'s own threading rule — "one thread drives
a renderer, apart from `set_camera`, `resize` and `copy_presented`, which are
safe from any thread" — should cover these too: this spike keeps the whole
presentation lifecycle on the Android main thread (see the class comment on
`FilamentSurfaceSession`), consistent with the pattern the ABI already
documents, so the new calls fit the existing contract rather than needing a
new one.

## What's still unknown

- **Real devices.** Everything here is the emulator's software (OpenGL ES)
  or software-via-SwiftShader (Vulkan) path. A real device's OpenGL ES
  driver could sit anywhere from below this emulator's level 1 to a genuine
  level 3; a real device's Vulkan driver is a different, usually much
  faster, implementation than SwiftShader, and might expose a different
  `supportedFeatureLevel`. Nothing here should be read as "Android devices
  get feature level 1 on GL" — only this specific emulator does, verified;
  devices need their own pass.
- **Performance on hardware.** The frame-timing numbers in this document are
  an emulator software-rendering artifact (worst-case stalls in particular)
  and a red herring for judging real-device performance one way or the
  other — they say nothing about how the real renderer, with its full
  material and lighting cost, would perform on actual silicon.
- **The forced-reattach button.** Written up above under "Lifecycle": the
  code path is right by inspection and by compiling against Flutter's real
  API, but this session could not get a synthetic tap to trigger it, on
  three different emulator configurations. Needs a real device or a proper
  UI test driver, not `adb input`.
- **A feature-level-3 material on Android, end to end.** This spike's
  material is unlit and declares no feature level. The corrected assumption
  above (engine construction doesn't fail on a too-high request; a material
  load presumably does) is inferred from `PORTING.md` and Filament's
  documented behaviour, not directly observed on this platform — nobody
  has yet tried loading `lit.mat` on an Android engine running below level 3
  to watch it refuse.
- **The `orbis_renderer_attach_surface`/`_detach_surface` addition above** is
  a design, argued from the existing code and this spike's own working
  implementation of the same idea — it has not been built or tested against
  the real core.

## Files

- `filament_surface/` — the plugin: `android/build.gradle.kts`,
  `android/src/main/cpp/{CMakeLists.txt,spike_renderer.cpp}`,
  `android/src/main/kotlin/dev/orbis/spike/filament_surface/{FilamentSurfacePlugin,FilamentSurfaceSession,SpikeRenderer}.kt`,
  `android/src/main/materials/unlit_colour.mat`, `lib/filament_surface.dart`.
- `app/` — the demo: `lib/main.dart` (backend picker, `Texture` widget, live
  feature-level/stats overlay, `Recreate surface`/`Back` controls).
- `setup.sh` — symlinks the Filament Android release and compiles the
  material with the host `matc`; re-run after a fresh clone or a material
  change.
- `captures/` — screenshots taken while verifying this document; gitignored
  (see `.gitignore`) because they're evidence from one run, not source. This
  document says what they showed.
