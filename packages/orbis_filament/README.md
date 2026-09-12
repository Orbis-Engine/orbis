# orbis_filament

Filament rendering for Orbis, composited by Flutter. Renders into IOSurface-
backed pixel buffers the texture registry adopts without a readback.

Part of [Orbis](https://github.com/Orbis-Engine/orbis), a Dart-first 3D game
engine. The documentation is at [orbis-site.vercel.app](https://orbis-site.vercel.app).

## Using it

```yaml
dependencies:
  orbis_filament:
    git:
      url: https://github.com/Orbis-Engine/orbis.git
      path: packages/orbis_filament
```

Needs Flutter. Draws on macOS, iOS, Android and Windows. One renderer serves
all four through a C ABI, behind a Swift plugin on the Apple platforms, a
Kotlin/JNI one on Android and a Win32 one on Windows; each hands a frame to
Flutter the way its embedder can take one, which is without a copy everywhere
but Windows (see `windows/orbis_viewport.h` for why).

## Status

Pre-alpha. Nothing here is API-stable, and the version is bumped for every
feature — see [VERSIONING.md](../../VERSIONING.md).

## Licence

MIT, © 2026 Chris Beckett. See [LICENSE](LICENSE), and the repository root
for the third-party notices that apply to builds linking the renderer.
