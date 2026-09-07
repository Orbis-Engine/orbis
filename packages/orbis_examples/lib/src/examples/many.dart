import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../example.dart';
import 'surface.dart' show linearOf;

/// What the keys are for.
///
/// Every frame here is a complete description of a thousand objects, sent
/// again from scratch. Nothing on the wire says what changed — and nothing
/// has to, because each object carries a number that is its own. The renderer
/// keeps what it built between frames, writes the transforms that actually
/// moved, and leaves the rest alone.
///
/// Turn Settling on and most of them stop. What that costs the renderer drops
/// with them, which is the whole point of the arrangement.
class ManyExample extends Example {
  ManyExample();

  @override
  String get name => 'A thousand objects';

  @override
  String get blurb =>
      'A whole scene sent every frame, and only what moved paid for.';

  @override
  ViewPoint get viewpoint =>
      const ViewPoint(distance: 34, pitch: 0.45, height: 1);

  double count = 600;
  bool settling = false;
  double speed = 1;

  @override
  OrbisScene scene(OrbisCamera camera, double seconds) {
    final total = count.round();

    return OrbisScene(
      objects: [
        for (var i = 0; i < total; i++) _crate(i, total, seconds),
        OrbisObject(
          key: 500,
          transform: Matrix4.identity()
            ..setTranslation(Vector3(0, -2.6, 0))
            ..scaleByDouble(30.0, 0.06, 30.0, 1),
          colour: linearOf(const Color(0xFF3A4048)),
          castShadows: false,
        ),
      ],
      lights: [
        OrbisLight(
          key: 510,
          kind: OrbisLightKind.directional,
          intensity: 78000,
          direction: Vector3(-0.4, -1, -0.4)..normalize(),
          colour: linearOf(const Color(0xFFFFF3E0)),
          sunAngularRadius: 1.2,
        ),
      ],
      sky: OrbisSky(colour: linearOf(const Color(0xFF1D242E)), ambient: 12000),
      camera: camera,
    );
  }

  OrbisObject _crate(int index, int total, double seconds) {
    // Placed on a spiral, so the count can change without everything jumping.
    final angle = index * 2.399;
    final radius = math.sqrt(index + 1) * 0.62;

    // Most of them stop when settling is on. The ones that keep going are
    // the only ones the renderer writes a transform for.
    final moving = !settling || index % 11 == 0;
    final wobble = moving ? math.sin(seconds * speed + index * 0.7) : 0.0;

    return OrbisObject(
      // Its own number, kept for as long as it exists. Two objects sharing one
      // would be one of them quietly taking the other's place.
      key: 1000 + index,
      transform: Matrix4.identity()
        ..setTranslation(
          Vector3(
            math.cos(angle) * radius,
            -2.2 + wobble * 0.6 + (index % 5) * 0.12,
            math.sin(angle) * radius,
          ),
        )
        ..rotateY(angle + wobble * 0.3)
        ..scaleByDouble(0.34, 0.34 + (index % 4) * 0.1, 0.34, 1),
      colour: linearOf(
        Color.lerp(
          const Color(0xFFD9634F),
          const Color(0xFF5FA8D3),
          (index / math.max(total - 1, 1)),
        )!,
      ),
      // Shadows from a thousand things are a thousand things in the shadow
      // map. Worth having off by default at this count.
      castShadows: index % 7 == 0,
    );
  }

  @override
  Widget settings(BuildContext context, VoidCallback changed) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Setting(
          label: 'Objects',
          value: count,
          min: 10,
          max: 2000,
          decimals: 0,
          onChanged: (value) {
            count = value;
            changed();
          },
        ),
        Setting(
          label: 'Speed',
          value: speed,
          min: 0,
          max: 4,
          onChanged: (value) {
            speed = value;
            changed();
          },
        ),
        Toggle(
          label: 'Settling',
          value: settling,
          onChanged: (value) {
            settling = value;
            changed();
          },
        ),
      ],
    );
  }

  @override
  String get code => '''
// The whole scene, every frame. There is no add, move or remove call: a
// description that says everything cannot go stale, and a key nobody sends
// this time is an object that has left.
OrbisScene(
  objects: [
    for (var i = 0; i < total; i++)
      OrbisObject(
        key: 1000 + i,                    // its own, for as long as it exists
        transform: placementOf(i, seconds),
        colour: colourOf(i),
        castShadows: i % 7 == 0,
      ),
  ],
  lights: [sun],
  camera: camera,
)

// On the other side: a transform is compared before it is written, because
// writing one dirties the node and everything under it. A mesh instance whose
// object is gone goes back to a pool rather than being destroyed. Only a
// change of mesh rebuilds anything.
''';
}
