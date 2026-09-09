import 'package:flutter/material.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../example.dart';
import 'surface.dart' show linearOf;

/// A reflection taken from inside the scene rather than brought to it.
///
/// An environment is a photograph of somewhere else, and indoors that is the
/// wrong photograph: a chrome box in a red and blue room reflects the sky,
/// because the sky is the only environment the scene has. A probe is the
/// scene photographing itself from a point inside, so the box reflects the
/// room it is actually standing in — red down one side, blue down the other.
///
/// The comparison is the point of this example, which is why it is a switch
/// rather than a setting: the same room lit by a picture of the sky, and lit
/// by a picture of itself.
class ProbesExample extends Example {
  ProbesExample();

  @override
  String get name => 'Reflection probes';

  @override
  String get blurb =>
      'A chrome box reflecting the room it is in, from a cubemap the scene '
      'captured of itself.';

  @override
  ViewPoint get viewpoint =>
      const ViewPoint(yaw: 0, pitch: 0.10, distance: 10.5, height: -0.9);

  bool on = true;
  double roughness = 0.08;
  double intensity = 1;

  /// The layer the reflective things sit on.
  ///
  /// A probe captured from inside a mirror photographs the mirror, and the
  /// mirror then reflects a smaller copy of itself. Keeping them on their own
  /// layer and leaving that layer out of the capture is the whole of the fix.
  static const int _shinyLayer = 1;
  static const int _roomLayer = 0;

  OrbisObject _slab(int key, Vector3 at, Vector3 size, Color colour) =>
      OrbisObject(
        key: key,
        transform: Matrix4.identity()
          ..setTranslation(at)
          ..scaleByDouble(size.x, size.y, size.z, 1),
        colour: linearOf(colour),
        layer: _roomLayer,
      );

  @override
  OrbisScene scene(OrbisCamera camera, double seconds) => OrbisScene(
    objects: [
      _slab(
        10,
        Vector3(0, -3, 0),
        Vector3(4, 0.15, 4),
        const Color(0xFFEDEAE3),
      ),
      _slab(
        11,
        Vector3(-4, 0, 0),
        Vector3(0.15, 3, 4),
        const Color(0xFFC7332B),
      ),
      _slab(12, Vector3(4, 0, 0), Vector3(0.15, 3, 4), const Color(0xFF2F6DBF)),
      _slab(
        13,
        Vector3(0, 0, -4),
        Vector3(4, 3, 0.15),
        const Color(0xFFEDEAE3),
      ),
      _slab(14, Vector3(0, 3, 0), Vector3(4, 0.15, 4), const Color(0xFFEDEAE3)),
      // The witness, on its own layer so the capture leaves it out.
      OrbisObject(
        key: 20,
        transform: Matrix4.identity()
          ..setTranslation(Vector3(0, -1.6, 0.4))
          // Turned a half-right angle so that two of its faces are visible at
          // once, one looking at each wall. A box square to the camera shows
          // only the face that reflects what is behind the camera, which is
          // the one face that says nothing about the room.
          ..rotateY(0.785)
          ..scaleByDouble(1.1, 1.1, 1.1, 1),
        // The colour is the material's, not this; the object still has to
        // state one because every object does.
        colour: Vector3(1, 1, 1),
        material: 1,
        layer: _shinyLayer,
      ),
    ],
    materials: [
      OrbisMaterial(
        key: 1,
        baseColour: Vector4(0.95, 0.95, 0.96, 1),
        metallic: 1,
        // Never quite nought: a highlight smaller than a pixel flickers, and
        // that reads as the renderer being broken rather than as a mirror.
        roughness: roughness.clamp(0.02, 1.0),
        reflectance: 0.9,
      ),
    ],
    probes: on
        ? [
            OrbisProbe(
              key: 100,
              // Head height in the middle of the room, not on the floor: a
              // probe on the floor sees a great deal of floor.
              position: Vector3(0, -0.4, 0),
              radius: 14,
              resolution: 256,
              // Everything but the shiny things.
              layers: 1 << _roomLayer,
              intensity: intensity,
            ),
          ]
        : const [],
    lights: [
      OrbisLight(
        key: 1,
        kind: OrbisLightKind.directional,
        intensity: 45000,
        direction: (Vector3(-0.3, -1, -0.2))..normalize(),
        sunAngularRadius: 1.5,
        castShadows: true,
        colour: linearOf(const Color(0xFFFFF6E8)),
      ),
    ],
    sky: OrbisSky(colour: linearOf(const Color(0xFF6E8CB4)), ambient: 9000),
    camera: camera,
  );

  @override
  Widget settings(BuildContext context, VoidCallback changed) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Toggle(
        label: 'Probe',
        value: on,
        onChanged: (value) {
          on = value;
          changed();
        },
      ),
      Setting(
        label: 'Roughness',
        value: roughness,
        min: 0.02,
        max: 0.6,
        onChanged: (value) {
          roughness = value;
          changed();
        },
      ),
    ],
  );

  @override
  String get code => '''
// The scene photographs itself from a point inside, and is lit by that
// instead of by the environment. Captured once and kept: six renders of
// the whole scene is not a per-frame cost, so bumping `version` is how a
// host says the room has changed.
OrbisScene(
  probes: [
    OrbisProbe(
      key: 100,
      position: Vector3(0, -0.4, 0),   // head height, not the floor
      radius: 14,                      // how far its influence reaches
      resolution: 256,
      // Everything but the reflective things. A probe captured from inside
      // a mirror photographs the mirror, and the mirror then reflects a
      // smaller copy of itself.
      layers: 1 << 0,
    ),
  ],
  // ...
)
''';
}
