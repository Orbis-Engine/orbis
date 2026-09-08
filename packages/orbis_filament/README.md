# orbis_filament

Filament rendering for Orbis, composited by Flutter. Renders into IOSurface-
backed pixel buffers the texture registry adopts without a readback.

Part of [Orbis](https://github.com/Orbis-Engine/orbis), a Dart-first 3D game
engine. The documentation is at [the Orbis documentation]().

## Using it

```yaml
dependencies:
  orbis_filament:
    git:
      url: https://github.com/Orbis-Engine/orbis.git
      path: packages/orbis_filament
```

Needs Flutter. Runs macOS — the renderer draws there and nowhere else yet.

## Status

Pre-alpha. Nothing here is API-stable, and the version is bumped for every
feature — see [VERSIONING.md](../../VERSIONING.md).

## Licence

MIT. See [LICENSE](LICENSE), and the repository root for the third-party
notices that apply to builds linking the renderer.
