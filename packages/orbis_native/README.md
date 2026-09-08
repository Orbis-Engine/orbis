# orbis_native

Compiling and loading C++ scripts. A script is a file the engine loads, not a
file the engine has to have been linked into: it is handed a table of what it
may call, and answers start, step and stop.

Part of [Orbis](https://github.com/Orbis-Engine/orbis), a Dart-first 3D game
engine. The documentation is at [orbis-site.vercel.app](https://orbis-site.vercel.app).

## Using it

```yaml
dependencies:
  orbis_native:
    git:
      url: https://github.com/Orbis-Engine/orbis.git
      path: packages/orbis_native
```

Needs Dart alone. Runs anywhere Dart runs, including a headless CI runner.

## Status

Pre-alpha. Nothing here is API-stable, and the version is bumped for every
feature — see [VERSIONING.md](../../VERSIONING.md).

## Licence

MIT, © 2026 Chris Beckett. See [LICENSE](LICENSE), and the repository root
for the third-party notices that apply to builds linking the renderer.
