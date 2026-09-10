import 'package:flutter/material.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../example.dart';
import 'surface.dart' show linearOf;

/// The shadow a window casts.
///
/// A point source gives a knife edge: every surface either sees the point or
/// does not, so the shadow has a boundary and no gradient. A panel is not a
/// point — a surface near the edge of its shadow can see *part* of the
/// rectangle, and how much it sees is what the gradient is made of. That
/// gradient is the whole reason to light anything with a softbox, and until
/// this example there was nothing in the engine that could draw one.
///
/// Two things are worth watching here rather than reading about. Widen the
/// panel and the shadow's edge softens while the light on the floor barely
/// changes, because the same flux is spread over more surface. Raise it and
/// the shadow lengthens and softens further, because everything under it is
/// further from the thing lighting it.
class PanelShadowExample extends Example {
  PanelShadowExample();

  @override
  String get name => 'Panel shadows';

  @override
  String get blurb =>
      'The soft shadow a rectangular light casts, and how its edge changes '
      'with the size of the panel.';

  /// Looking down at the floor, which is where the shadow is.
  ///
  /// Worth stating because the obvious camera is the wrong one: a shadow
  /// lives on the ground, and a viewpoint at eye level shows the lit *sides*
  /// of things and almost none of the floor they stand on.
  @override
  ViewPoint get viewpoint =>
      const ViewPoint(yaw: 0.6, pitch: 0.85, distance: 15, height: 0.5);

  /// The panel's edges, in metres.
  double panel = 2.0;

  /// How far above the floor it hangs.
  double height = 5.0;

  /// Whether it casts at all, so the difference can be seen rather than
  /// described.
  bool shadows = true;

  static const int _floor = 10;
  static const int _pillar = 11;
  static const int _block = 12;
  static const int _slab = 13;

  OrbisObject _box(
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
  OrbisScene scene(OrbisCamera camera, double seconds) {
    // Straight down. A panel emits along its own normal and this one is
    // pointed at the floor, so everything standing on it is between the two.
    final at = Vector3(0, height, 0);

    return OrbisScene(
      objects: [
        // Pale and matt. What lands on it is what is seen on it, which is the
        // only reason a shadow is visible at all.
        _box(
          _floor,
          Vector3(0, -2, 0),
          Vector3(9, 0.12, 9),
          const Color(0xFFE8E4DA),
        ),
        // Three occluders at three heights, because the softness of an edge
        // grows with the distance between the thing casting and the thing
        // catching. The tall one's shadow is noticeably softer at its far end
        // than at its foot, which is the effect this example exists to show.
        _box(
          _pillar,
          Vector3(-2.2, -0.4, -0.6),
          Vector3(0.35, 1.6, 0.35),
          const Color(0xFFD9634F),
        ),
        _box(
          _block,
          Vector3(1.4, -1.35, 1.2),
          Vector3(0.9, 0.6, 0.9),
          const Color(0xFFE8E4DC),
          turn: 0.5,
        ),
        _box(
          _slab,
          Vector3(2.0, -1.05, -1.8),
          Vector3(1.4, 0.9, 0.25),
          const Color(0xFF7FA8B8),
          turn: -0.35,
        ),
      ],
      lights: [
        OrbisLight(
          key: 1,
          kind: OrbisLightKind.area,
          // Lumens, like a bulb. Making the panel bigger below does not
          // brighten the floor — the same flux is spread over more surface,
          // which softens the shadow instead.
          intensity: 900000,
          position: at,
          direction: Vector3(0, -1, 0),
          // Which way the width runs. Without it the panel is free to spin in
          // its own plane, and a strip on its side is a different light.
          tangent: Vector3(1, 0, 0),
          width: panel,
          height: panel,
          falloffRadius: 30,
          castShadows: shadows,
          colour: linearOf(const Color(0xFFFFF4E2)),
        ),
      ],
      // Low, so what fills the shadow is the shadow's own darkness rather
      // than the sky. An ambient bright enough to see by would flatten the
      // gradient this example is about.
      sky: OrbisSky(colour: linearOf(const Color(0xFF1A1F27)), ambient: 900),
      camera: camera,
    );
  }

  @override
  Widget settings(BuildContext context, VoidCallback changed) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Toggle(
        label: 'Cast shadows',
        value: shadows,
        onChanged: (value) {
          shadows = value;
          changed();
        },
      ),
      Setting(
        label: 'Panel size',
        value: panel,
        min: 0.15,
        max: 6,
        unit: ' m',
        onChanged: (value) {
          panel = value;
          changed();
        },
      ),
      Setting(
        label: 'Height',
        value: height,
        min: 2,
        max: 12,
        unit: ' m',
        onChanged: (value) {
          height = value;
          changed();
        },
      ),
    ],
  );

  @override
  String get code => '''
// A rectangle of light, hung above the floor and pointed at it.
//
// `castShadows` is what this example is about. A rectangle is not one of
// Filament's own lights — it is shaded in the surface material against a
// fitted table — so its shadow is a depth map of its own, drawn once from
// where the panel stands and compared against by every surface it reaches.
OrbisLight(
  key: 1,
  kind: OrbisLightKind.area,
  // Lumens off a surface rather than out of a point, so a wider panel
  // spreads the same light instead of adding more of it.
  intensity: 900000,
  position: Vector3(0, 5, 0),
  direction: Vector3(0, -1, 0),
  // Which way the width runs. A strip on its side is a different light.
  tangent: Vector3(1, 0, 0),
  width: 2,
  height: 2,
  falloffRadius: 30,
  castShadows: true,
)

// One rectangle casts. A scene has one key light and the rest are fill, and
// giving every panel a map would cost a scene render each to shadow lights
// whose job is to not be noticed. A second one asking is reported and lit
// without a shadow rather than dropped.
''';
}
