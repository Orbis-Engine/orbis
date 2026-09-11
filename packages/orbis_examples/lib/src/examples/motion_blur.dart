import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../example.dart';
import 'surface.dart' show linearOf;

/// What the shutter saw while it was open.
///
/// A renderer draws instants, and an instant of a spinning fan is a set of
/// perfectly sharp blades — the most reliable sign there is that a moving
/// picture was computed rather than photographed. A camera's shutter is open
/// for a length of time, and whatever moves while it is open is recorded all
/// along its path.
///
/// Three things move here in three different ways. The fan turns in place,
/// so its tips smear and its hub barely does. The block slides, so it
/// smears along its path by the same amount everywhere. And the camera can
/// pan, which smears everything, the still wall included — the case that
/// needs no object to have moved at all, rebuilt from depth alone. The blue
/// box never moves, and stays sharp under a still camera whatever the
/// shutter.
///
/// The shutter is the camera's own, with the sensitivity moved against it so
/// the picture stays equally bright: slowing the shutter lets in more light,
/// and the blur is what comes with it.
class MotionBlurExample extends Example {
  MotionBlurExample();

  @override
  String get name => 'Motion blur';

  @override
  String get blurb =>
      'A spinning fan and a sliding block smeared by their own motion while '
      'the wall behind them stays sharp, at a shutter you choose.';

  @override
  ViewPoint get viewpoint =>
      const ViewPoint(yaw: 0, pitch: 0, distance: 10, height: 1.5);

  bool on = true;
  bool objects = true;
  bool panning = false;

  /// The camera's shutter, in seconds.
  double shutter = 1 / 30;

  static const Map<String, double> shutters = {
    '1/1000 s': 1 / 1000,
    '1/250 s': 1 / 250,
    '1/60 s': 1 / 60,
    '1/30 s': 1 / 30,
  };

  /// How fast things go. Each is steady between turnarounds, so a picture
  /// taken at any moment has a streak whose length can be worked out by hand:
  /// speed across the picture times the time the shutter is open.
  static const double turnsPerSecond = 1;
  static const double slideSpeed = 4; // metres a second
  static const double panSpeed = 0.25; // radians a second

  static const int _floor = 1;
  static const int _wall = 2;
  static const int _stripes = 3; // and the eleven after it
  static const int _still = 20;
  static const int _hub = 30;
  static const int _blades = 31; // and the three after it
  static const int _block = 40;

  /// Nought to one and back at a steady rate, turning round every half unit.
  static double _triangle(double u) {
    final f = u - u.floorToDouble();
    return 1 - (2 * f - 1).abs();
  }

  OrbisObject _box(int key, Matrix4 transform, Color colour) => OrbisObject(
    key: key,
    transform: transform,
    colour: linearOf(colour),
    castShadows: true,
  );

  /// The built-in cube spans minus one to one, so a box is placed by its
  /// centre and its half-extents.
  Matrix4 _at(double x, double y, double z, Vector3 half) => Matrix4.identity()
    ..setTranslation(Vector3(x, y, z))
    ..scaleByDouble(half.x, half.y, half.z, 1);

  @override
  OrbisScene scene(OrbisCamera camera, double seconds) {
    final spin = seconds * turnsPerSecond * 2 * math.pi;
    // Ten metres there and back, a turnaround every two and a half seconds.
    final slid = -5 + 10 * _triangle(seconds * slideSpeed / 20);
    final hub = Vector3(2.8, 2.8, 0);

    var eye = camera;
    if (panning) {
      // A pan turns the camera where it stands rather than walking it round
      // the subject, so everything in the picture moves at the same rate
      // whatever its distance: a quarter radian either way, turning round
      // every two seconds.
      final angle = panSpeed * (2 * _triangle(seconds / 4) - 1);
      final look = Matrix3.rotationY(angle)
          .transform(camera.target - camera.position);
      eye = camera.copyWith(target: camera.position + look);
    }
    // The sensitivity moved against the shutter, so a slower shutter lets in
    // the same light and brings only its blur.
    eye = eye.copyWith(
      shutterSpeed: shutter,
      sensitivity: 100 * (1 / 125) / shutter,
    );

    return OrbisScene(
      camera: eye,
      objects: [
        _box(
          _floor,
          _at(0, -1.75, -1, Vector3(9, 0.1, 5)),
          const Color(0xFF8F8A80),
        ),
        _box(
          _wall,
          _at(0, 1.5, -4, Vector3(9, 4, 0.1)),
          const Color(0xFFE8E4DC),
        ),
        // Dark bars along the top of the wall: a pan has nothing to show on
        // a plain wall, and these are what it streaks.
        for (var i = 0; i < 12; i++)
          _box(
            _stripes + i,
            _at(-7.15 + i * 1.3, 3.9, -3.85, Vector3(0.18, 1.2, 0.05)),
            const Color(0xFF2B2F36),
          ),
        // The witness: never moves, so under a still camera it is the same
        // picture with the blur on and off.
        _box(
          _still,
          _at(-3.5, 1.2, 0, Vector3(0.6, 0.6, 0.6)),
          const Color(0xFF2F6DBF),
        ),
        _box(
          _hub,
          Matrix4.identity()
            ..setTranslation(hub)
            ..rotateZ(spin)
            ..scaleByDouble(0.22, 0.22, 0.12, 1),
          const Color(0xFF3A3F48),
        ),
        for (var blade = 0; blade < 4; blade++)
          _box(
            _blades + blade,
            Matrix4.identity()
              ..setTranslation(hub)
              ..rotateZ(spin + blade * math.pi / 2)
              ..translateByDouble(0.9, 0, 0, 1)
              ..scaleByDouble(0.9, 0.1, 0.04, 1),
            const Color(0xFFC7332B),
          ),
        // A plate rather than a cube, sliding in front of the plain wall: two
        // clean edges against one flat colour, so its streak can be measured
        // off the picture rather than guessed at.
        _box(
          _block,
          _at(slid, 0, 0, Vector3(0.45, 0.45, 0.05)),
          const Color(0xFFE0A526),
        ),
      ],
      lights: [
        OrbisLight(
          key: 1,
          kind: OrbisLightKind.directional,
          direction: Vector3(-0.3, -1, -0.5)..normalize(),
          colour: Vector3(1, 0.97, 0.92),
          intensity: 90000,
          castShadows: true,
        ),
      ],
      sky: OrbisSky(
        zenith: Vector3(0.30, 0.50, 0.78),
        horizon: Vector3(0.72, 0.84, 0.94),
        ambient: 24000,
      ),
      graph: on ? OrbisMotionBlur(objects: objects).graph() : null,
    );
  }

  @override
  Widget settings(BuildContext context, VoidCallback changed) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Toggle(
        label: 'Motion blur',
        value: on,
        onChanged: (value) {
          on = value;
          changed();
        },
      ),
      Toggle(
        label: 'Objects',
        value: objects,
        enabled: on,
        note: objects
            ? 'Each object blurs by its own motion'
            : 'Only the camera\'s motion, rebuilt from depth',
        onChanged: (value) {
          objects = value;
          changed();
        },
      ),
      Toggle(
        label: 'Pan',
        value: panning,
        onChanged: (value) {
          panning = value;
          changed();
        },
      ),
      Choice(
        label: 'Shutter',
        options: shutters.keys.toList(),
        selected: shutters.entries
            .firstWhere(
              (entry) => (entry.value - shutter).abs() < 1e-9,
              orElse: () => shutters.entries.last,
            )
            .key,
        onSelect: (label) {
          shutter = shutters[label]!;
          changed();
        },
      ),
    ],
  );

  @override
  String get code => '''
// The world into a target that keeps its depth, and the blur from there onto
// the screen. The shutter follows the camera's own unless one is given.
OrbisScene(
  camera: camera.copyWith(shutterSpeed: 1 / 30),
  graph: const OrbisMotionBlur().graph(),
  // ...
)

// Or as one pass in a graph of your own, reading a target with depth.
const OrbisMotionBlur(maxPixels: 32, objects: false)
    .pass(reads: 'frame', into: 'blurred')
''';
}
