# Orbis Engine

A Dart-first 3D game engine. Game logic and UI in Flutter, an entity-component
core in C++, and Google's [Filament](https://github.com/google/filament) doing
the rendering.

```sh
./tool/check.sh          # analyze and test everything that needs no window
cd examples/viewport && flutter run -d macos    # the renderer, on macOS
dart run examples/simulation/bin/simulation.dart
```

| Package | What it is |
| --- | --- |
| `orbis_core` | Archetype entity-component store in C++ behind a C ABI, with a transform hierarchy. Component data reaches Dart as views, not copies. |
| `orbis_filament` | Filament rendering composited by Flutter's texture registry. macOS so far. |
| `orbis_net` | Multiplayer. Replicates component columns, with ownership rules and interpolation. |
| `orbis_net_dashwire` | Carries replication over [dashwire](https://github.com/bdero/dashwire). Opt-in. |

Design notes live outside this repository, as Claude artifacts, so a checkout
carries what it needs to build and run and nothing else.

Pre-alpha. Nothing here is stable.

## Licence

MIT. Portions derive from [flutter_scene](https://github.com/bdero/flutter_scene)
by Brandon DeRosier, used under the same licence.
