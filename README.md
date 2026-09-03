# Orbis Engine

A Dart-first 3D game engine. You write game logic and UI in Flutter; a C++ ECS
core and Google's [Filament](https://github.com/google/filament) renderer do the
heavy lifting underneath.

The bet is that the thing games are worst at — iteration speed — is the thing
Flutter is best at. Hot reload, the widget inspector, and all of pub.dev, over a
renderer that produces physically-based images.

## Status

Pre-alpha. The renderer bridge is proven; the engine on top of it is being built.

- [x] **M0** — Filament renders directly into a `CVPixelBuffer` (see [`spike/`](spike/))
- [ ] **M1** — that surface live in a Flutter `Texture` widget on macOS
- [ ] **M2** — C++ ECS core and the scene document model

See [ROADMAP.md](ROADMAP.md) for the rest and [ARCHITECTURE.md](ARCHITECTURE.md)
for how the pieces fit.

## Platforms

macOS, iOS, Android, Linux, Windows and Web. Filament has a backend for every
one of them.

Consoles are out of scope, and it is worth being precise about why: Flutter has
no console embedder, and the platform SDKs are NDA-gated in a way an open-source
port cannot satisfy. Reaching a console would mean a native shell that reuses
the C++ core and leaves Flutter behind. The core is designed to make that
possible later; nothing here is being built toward it now.

## Licence

MIT. Portions derive from [flutter_scene](https://github.com/bdero/flutter_scene)
by Brandon DeRosier, used under the same licence.
