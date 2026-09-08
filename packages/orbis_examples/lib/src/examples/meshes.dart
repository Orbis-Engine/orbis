import 'dart:io';

import 'package:flutter/material.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../example.dart';
import 'surface.dart' show linearOf;

/// Somebody else's geometry.
///
/// A glTF file arrives with its own materials rather than being tinted by
/// whatever colour the object happened to carry, and it is parsed once
/// however many objects name it. A file that cannot be read is drawn as the
/// placeholder cube and says so — which is the only useful thing to do with
/// that failure.
class MeshesExample extends Example {
  MeshesExample();

  @override
  String get name => 'Meshes';

  @override
  String get blurb =>
      'A glTF file, loaded once and instanced, with failures reported back.';

  @override
  ViewPoint get viewpoint => const ViewPoint(distance: 9, pitch: 0.22);

  /// Left empty on purpose: there is no model in this repository to ship, and
  /// a path that only works on one machine is worse than a field that says
  /// what it wants.
  String path = Platform.environment['ORBIS_MESH'] ?? '';

  double copies = 3;
  bool spinning = true;

  /// What the renderer said about the file, if anything.

  @override
  OrbisScene scene(OrbisCamera camera, double seconds) {
    final total = copies.round();
    final turn = spinning ? seconds * 0.4 : 0.0;

    return OrbisScene(
      objects: [
        for (var i = 0; i < total; i++)
          OrbisObject(
            key: 600 + i,
            transform: Matrix4.identity()
              ..setTranslation(Vector3((i - (total - 1) / 2) * 2.4, -0.6, 0))
              ..rotateY(turn + i * 0.4),
            colour: linearOf(const Color(0xFFD9634F)),
            // The same path on every one of them: parsed once, and every
            // object after the first gets an instance of it.
            mesh: path.isEmpty ? null : path,
          ),
        OrbisObject(
          key: 590,
          transform: Matrix4.identity()
            ..setTranslation(Vector3(0, -1.8, 0))
            ..scaleByDouble(9.0, 0.06, 9.0, 1),
          colour: linearOf(const Color(0xFF3B424C)),
          castShadows: false,
        ),
      ],
      lights: [
        OrbisLight(
          key: 610,
          kind: OrbisLightKind.directional,
          intensity: 76000,
          direction: Vector3(-0.5, -1, -0.4)..normalize(),
          colour: linearOf(const Color(0xFFFFF3E0)),
        ),
      ],
      sky: OrbisSky(colour: linearOf(const Color(0xFF1B222C)), ambient: 14000),
      camera: camera,
    );
  }

  @override
  Widget settings(BuildContext context, VoidCallback changed) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: TextField(
            style: const TextStyle(fontSize: 12, fontFamily: 'Menlo'),
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Path to a .glb or .gltf',
              hintText: '/Users/you/models/crate.glb',
              border: OutlineInputBorder(),
            ),
            onChanged: (value) {
              path = value.trim();
              note = null;
              changed();
            },
          ),
        ),
        Setting(
          label: 'Copies',
          value: copies,
          min: 1,
          max: 8,
          decimals: 0,
          onChanged: (value) {
            copies = value;
            changed();
          },
        ),
        Toggle(
          label: 'Spinning',
          value: spinning,
          onChanged: (value) {
            spinning = value;
            changed();
          },
        ),
      ],
    );
  }

  @override
  String get code => '''
// A path, on as many objects as want it.
OrbisObject(
  key: 600,
  transform: placement,
  colour: Vector3(0.72, 0.13, 0.08),   // used only if the file will not load
  mesh: '/Users/you/models/crate.glb',
)

// Parsed once and kept, however many objects name it: a scene arrives on
// every frame of a drag, and re-reading a glTF at that rate is unusable.
// The second object using a file gets another instance of it rather than
// another copy.

// What could not be loaded comes back from the publish rather than going to
// a log, so a host can name the asset it is missing.
OrbisView(
  scene: scene,
  onSceneNotes: (notes) => setState(() => note = notes.values.first),
)
''';
}
