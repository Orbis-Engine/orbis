# Architecture

## The layers

```
  Flutter app          game logic and UI, both in Dart, sharing one widget tree
  ─────────────────────────────────────────────────────────────────────────────
  orbis                entities, components, systems, the frame loop
  orbis_scene          the .oscene document — renderer-agnostic by construction
  orbis_codegen        @Component annotations to ECS and FFI registration
  ──────────────────── dart:ffi, built by native assets ───────────────────────
  orbis_core (C++)     archetype component storage, scheduler, job system,
                       transform hierarchy, culling
  ─────────────────────────────────────────────────────────────────────────────
  Filament             PBR rendering        Jolt   physics
  ─────────────────────────────────────────────────────────────────────────────
  platform surface     IOSurface / AHardwareBuffer / dma-buf / DXGI shared handle
                       handed to Flutter's texture registry
```

Dart owns the game. C++ owns the frame. The boundary sits where it does because
per-entity work in Dart costs a garbage collector on the frame budget, while
per-frame batch work in C++ costs a single FFI call.

## Why the game logic stays in Dart

Because that is the entire point. An engine whose logic lives in C++ has thrown
away hot reload, the widget inspector, and pub.dev, and is then competing with
Unreal on Unreal's terms. Keeping logic in Dart means a designer changes a value
and sees it without a rebuild, which is the loop that actually decides how a game
turns out.

The cost is that Dart is garbage collected. The mitigation is that Dart never
touches per-vertex or per-frame data: components are stored in C++, and Dart
manipulates them through handles. Systems that must run per-entity per-frame are
written as C++ systems and configured from Dart.

## Getting a frame into Flutter

Filament renders into a platform surface; Flutter's texture registry composites
one. On every target those two are the same object, so no copy is needed:

| Platform | Filament backend  | Surface handed to Flutter        | Status    |
|----------|-------------------|----------------------------------|-----------|
| macOS    | Metal             | `CVPixelBuffer` over `IOSurface`  | proven    |
| iOS      | Metal             | `CVPixelBuffer` over `IOSurface`  | same path |
| Android  | Vulkan / GLES3    | `SurfaceTexture` / `AHardwareBuffer` | planned |
| Linux    | Vulkan / GL       | `dma-buf`                         | planned   |
| Windows  | Vulkan / GL       | DXGI shared handle                | planned   |
| Web      | WebGL2 (WASM)     | canvas via `HtmlElementView`      | planned   |

Web is the one genuine exception. Flutter Web has no texture registry, so the
Filament WASM build draws to its own canvas composited as a platform view. Same
renderer, different seam.

For the Linux and embedded path, Toyota Connected's
[ivi-homescreen](https://github.com/toyota-connected/ivi-homescreen) is a working
Flutter embedder doing zero-copy `dma-buf` under Vulkan, and is the reference to
follow rather than rediscover.

## Repository layout

One monorepo, many published packages — which is what Flame actually does, and
what it consolidated *to* after the split-repo years. The standalone repos left
in `flame-engine` are either archived after being merged in or libraries with no
engine dependency at all.

Package granularity is what keeps the engine small for a consumer. A game that
depends on `orbis` does not download the editor, the networking layer or the
Blender exporter. Repository granularity buys nothing here and costs a release
train, coordinated pull requests and version pinning across every change that
crosses a package.

```
packages/
  orbis                    umbrella API, frame loop
  orbis_core               C++ ECS and its FFI bindings
  orbis_scene              .oscene document model
  orbis_render             backend-agnostic renderer interface
  orbis_render_filament    Filament backend
  orbis_render_gpu         Flutter GPU backend, transitional
  orbis_codegen            component annotations to registration
  orbis_editor             editor UI
  orbis_editor_core        editor document and command model
  orbis_physics            physics contract
  orbis_physics_jolt       Jolt, via FFI
  orbis_audio              audio contract
  orbis_audio_fmod         FMOD Studio backend
  orbis_audio_soloud       SoLoud backend
  orbis_net                replication and transport
  orbis_mcp                editor automation over MCP
  orbis_lint               shared analysis options
  orbis_test               test harness and golden helpers
```

Separate repositories, for things with no engine dependency or a different
release cadence:

- `orbis-filament` — vendored Filament prebuilts per platform, large and slow moving
- `create-orbis` — project scaffolder
- `orbis-examples` — sample games
- `orbis-docs` — documentation site
- `orbis-blender` — Blender exporter, Python

## What carries over from flutter_scene

Orbis starts from flutter_scene, but not from its renderer — that is the part
Filament replaces, and it is about 197k of its 316k lines. What is worth moving
is the other half, which is the half that is hard to rebuild:

| From                        | Becomes             | Why it survives                                  |
|-----------------------------|---------------------|--------------------------------------------------|
| `scene`                     | `orbis_scene`       | already renderer-agnostic; the document model     |
| `flutter_scene_editor`      | `orbis_editor`      | a working editor is years of work                 |
| `flutter_scene_editor_core` | `orbis_editor_core` | document, commands, undo                          |
| `flutter_scene_codegen`     | `orbis_codegen`     | matters *more* with an ECS across an FFI boundary |
| `flutter_scene_net`         | `orbis_net`         | replication is transport-shaped, not render-shaped |
| `flutter_scene_mcp`         | `orbis_mcp`         | editor automation                                 |
| audio and physics backends  | `orbis_audio_*`     | the contracts hold; Rapier gives way to Jolt      |
| `flutter_scene`             | `orbis_render_gpu`  | kept only so the editor has a viewport during the port |

The native assets build hook in flutter_scene already compiles C and C++ sources
into a single library opened over `dart:ffi`. That is the mechanism `orbis_core`
needs, and it carries over intact.
