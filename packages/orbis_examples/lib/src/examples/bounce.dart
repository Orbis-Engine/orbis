import 'package:flutter/material.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../example.dart';
import 'surface.dart' show linearOf;

/// Light that has hit something before it arrives.
///
/// Direct lighting stops at the first surface it meets. Put a white box
/// between a red wall and a blue one and a renderer without a second bounce
/// draws it white on both sides — while the room it is standing in would
/// paint one side pink and the other blue. That difference is most of what
/// makes a lit interior read as a room rather than as objects on a stage.
///
/// The corner is deliberate. Two walls facing each other across a pale floor
/// is the arrangement that shows bounced light most plainly, which is why
/// every renderer since Cornell in 1984 has been photographed in one.
class BounceExample extends Example {
  BounceExample();

  @override
  String get name => 'Bounced light';

  @override
  String get blurb =>
      'One bounce, taken from the picture already drawn: coloured walls '
      'tinting a white box between them.';

  @override
  ViewPoint get viewpoint =>
      const ViewPoint(yaw: 0, pitch: 0.16, distance: 13, height: -0.6);

  double strength = 6;
  double reach = 3;
  bool on = true;

  static const int _floor = 10;
  static const int _left = 11;
  static const int _right = 12;
  static const int _back = 13;
  static const int _box = 14;
  static const int _tall = 15;

  /// A wall as a flattened cube: a box is the only shape this example needs,
  /// and a thin one is a wall.
  OrbisObject _slab(
    int key,
    Vector3 at,
    Vector3 size,
    Color colour, {
    double turn = 0,
  }) => OrbisObject(
    key: key,
    transform: Matrix4.identity()
      ..setTranslation(at)
      ..rotateY(turn)
      ..scaleByDouble(size.x, size.y, size.z, 1),
    colour: linearOf(colour),
    castShadows: true,
  );

  @override
  OrbisScene scene(OrbisCamera camera, double seconds) => OrbisScene(
    objects: [
      // Pale and matt, so what lands on it is what is seen on it.
      _slab(_floor, Vector3(0, -3, 0), Vector3(4, 0.15, 4),
          const Color(0xFFEDEAE3)),
      _slab(_left, Vector3(-4, 0, 0), Vector3(0.15, 3, 4),
          const Color(0xFFC7332B)),
      _slab(_right, Vector3(4, 0, 0), Vector3(0.15, 3, 4),
          const Color(0xFF2F6DBF)),
      _slab(_back, Vector3(0, 0, -4), Vector3(4, 3, 0.15),
          const Color(0xFFEDEAE3)),
      // The witnesses. White on every face when they leave the renderer, so
      // any colour on them arrived from somewhere else.
      _slab(_box, Vector3(-1.5, -1.85, 0.6), Vector3(1, 1, 1),
          const Color(0xFFF4F2EE)),
      _slab(_tall, Vector3(1.6, -1.35, -1.4), Vector3(0.9, 1.5, 0.9),
          const Color(0xFFF4F2EE), turn: 0.4),
    ],
    lights: [
      OrbisLight(
        key: 1,
        kind: OrbisLightKind.directional,
        intensity: 70000,
        // Steep, and leaning just enough to put real light on both walls.
        // A bounce can only carry light that arrived, so a wall in its own
        // shadow has nothing to give.
        direction: (Vector3(-0.32, -1, -0.16))..normalize(),
        sunAngularRadius: 1.5,
        castShadows: true,
        colour: linearOf(const Color(0xFFFFF6E8)),
      ),
    ],
    // Dim on purpose. Ambient sky light fills shadows evenly and for free,
    // and a room where it does that is a room where a second bounce has
    // nothing left to add. Turning it down is what leaves the shadowed side
    // of a box lit by the wall beside it rather than by the sky.
    sky: OrbisSky(colour: linearOf(const Color(0xFF181D24)), ambient: 400),
    graph: on
        ? OrbisRenderGraph(
            targets: const [OrbisTarget(name: 'frame')],
            passes: [
              const OrbisPass(name: 'world', into: 'frame'),
              OrbisPass(
                name: 'bounce',
                kind: OrbisPassKind.effect,
                effect: OrbisEffect.bounce,
                // The picture and its depth both come from this one target.
                reads: const ['frame'],
                plane: [reach, strength, 0, 0],
              ),
            ],
          )
        : null,
    camera: camera,
  );

  @override
  Widget settings(BuildContext context, VoidCallback changed) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Toggle(
        label: 'Bounced light',
        value: on,
        onChanged: (value) {
          on = value;
          changed();
        },
      ),
      Setting(
        label: 'Strength',
        value: strength,
        min: 0,
        max: 10,
        onChanged: (value) {
          strength = value;
          changed();
        },
      ),
      Setting(
        label: 'Reach',
        value: reach,
        min: 0.2,
        max: 8,
        unit: ' m',
        onChanged: (value) {
          reach = value;
          changed();
        },
      ),
    ],
  );

  @override
  String get code => '''
// One effect pass over the finished picture. It reads the colour and the
// depth of the same target, so the graph names that target once.
OrbisRenderGraph(
  targets: const [OrbisTarget(name: 'frame')],
  passes: [
    const OrbisPass(name: 'world', into: 'frame'),
    OrbisPass(
      name: 'bounce',
      kind: OrbisPassKind.effect,
      effect: OrbisEffect.bounce,
      reads: const ['frame'],
      // How far it looks, how much comes back, how solid the depth
      // buffer's surfaces are, and how many directions each pixel fans
      // along. Nought means the renderer's own default.
      plane: [3.0, 4.0, 0, 0],
    ),
  ],
)
''';
}
