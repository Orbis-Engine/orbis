# orbis_sequence

Cutscenes as a function of time. A sequence is tracks of clips over a
playhead; sampling it at any moment gives the whole world's worth of values,
so scrubbing, replaying and stepping backwards all come out the same.

Part of [Orbis](https://github.com/Orbis-Engine/orbis), a Dart-first 3D game
engine. The documentation is at [orbis-site.vercel.app](https://orbis-site.vercel.app).

## Using it

```yaml
dependencies:
  orbis_sequence:
    git:
      url: https://github.com/Orbis-Engine/orbis.git
      path: packages/orbis_sequence
```

Needs Dart alone. Runs anywhere Dart runs, including a headless CI runner.

## Status

Pre-alpha. Nothing here is API-stable, and the version is bumped for every
feature — see [VERSIONING.md](../../VERSIONING.md).

## Licence

MIT, © 2026 Chris Beckett. See [LICENSE](LICENSE), and the repository root
for the third-party notices that apply to builds linking the renderer.
