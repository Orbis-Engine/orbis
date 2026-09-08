# orbis_codegen

Turns annotated Dart classes into component registration and a manifest other
front ends can read without compiling the package that declared them.

Part of [Orbis](https://github.com/Orbis-Engine/orbis), a Dart-first 3D game
engine. The documentation is at [the Orbis documentation]().

## Using it

```yaml
dependencies:
  orbis_codegen:
    git:
      url: https://github.com/Orbis-Engine/orbis.git
      path: packages/orbis_codegen
```

Needs Dart alone. Runs anywhere Dart runs, including a headless CI runner.

## Status

Pre-alpha. Nothing here is API-stable, and the version is bumped for every
feature — see [VERSIONING.md](../../VERSIONING.md).

## Licence

MIT. See [LICENSE](LICENSE), and the repository root for the third-party
notices that apply to builds linking the renderer.
