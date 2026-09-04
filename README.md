# Orbis Engine

A Dart-first 3D game engine. Game logic and UI in Flutter, an entity-component
core in C++, and Google's [Filament](https://github.com/google/filament) doing
the rendering.

```sh
./tool/check.sh    # analyze and test everything that needs no window
```

| Package | What it is |
| --- | --- |
| `orbis_core` | Archetype entity-component store in C++ behind a C ABI, with a transform hierarchy. Component data reaches Dart as views, not copies. |
| `orbis_codegen` | Turns annotated component classes into registration and a manifest other front ends read without compiling this package. |
| `orbis_filament` | Filament rendering composited by Flutter's texture registry. macOS so far. |

## The rest of Orbis

| Repository | What it is |
| --- | --- |
| [`orbis-net`](https://github.com/Orbis-Engine/orbis-net) | Multiplayer. Replicates component columns, with ownership rules and interpolation. |
| [`orbis-script`](https://github.com/Orbis-Engine/orbis-script) | TypeScript scripting on QuickJS, as a peer of Dart over the same core. |
| [`orbis-examples`](https://github.com/Orbis-Engine/orbis-examples) | Worked examples of what the engine does, and how. |

Design notes live outside these repositories, as Claude artifacts, so a
checkout carries what it needs to build and run and nothing else.

Pre-alpha. Nothing here is stable.

## Licence

MIT. Builds link Filament, which carries its own Apache 2.0 licence — see
[LICENSE](LICENSE).
