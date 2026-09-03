# Roadmap

Ordered by risk, not by visibility. The unknowns come first so that the work
built on top of them is not built twice.

### M0 — the renderer bridge ✅

Filament renders into a `CVPixelBuffer` with no CPU readback. Proven in
[`spike/`](spike/); this was the one question that could have invalidated the
whole design.

### M1 — a live viewport on macOS

A macOS plugin registering that pixel buffer with Flutter's texture registry, a
render loop driven off the Flutter frame callback, resize handling, and an
`OrbisView` widget. Ends with a spinning cube inside a real Flutter app,
surrounded by ordinary widgets.

### M2 — the core

`orbis_core` as a C++ archetype ECS behind `dart:ffi`, built with native assets.
`orbis_scene` ported from flutter_scene's `scene` package. `orbis_codegen`
turning component annotations into registration on both sides of the boundary.

### M3 — scenes that mean something

Transform hierarchy synced to Filament, materials, and glTF loading through
Filament's own `gltfio`. Ends when an artist's file renders unmodified.

### M4 — the editor

`orbis_editor` ported onto a Filament viewport, with `orbis_render_gpu` retired
on macOS once it is no longer the thing keeping the viewport alive.

### M5 — mobile

iOS first, since it is the same Metal and `IOSurface` path as macOS. Then Android
on Vulkan, over `AHardwareBuffer`.

### M6 — desktop

Linux over `dma-buf`, following ivi-homescreen. Windows over a DXGI shared handle.

### M7 — web

Filament's WASM build composited through `HtmlElementView`. The one target where
the seam differs, so it is sequenced last.

### M8 — simulation

Jolt physics over FFI, audio backends, and networking ported from
`flutter_scene_net`.

## Deliberately not on this list

**Consoles.** Flutter has no console embedder and the platform SDKs cannot be
satisfied by an open-source port. If it ever happens it is a native shell reusing
`orbis_core`, not a Flutter target. The core is layered so that stays possible.

**A renderer of our own.** Filament is a decade of Google's work on exactly this
problem. Replacing it is not a differentiator.
