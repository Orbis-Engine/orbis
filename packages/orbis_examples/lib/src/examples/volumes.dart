import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../example.dart';
import 'surface.dart' show linearOf;

/// A courtyard in the sun and a hall off it, and the look changing as the
/// camera walks through the door.
///
/// A scene has one fog, one sky and one exposure, which is right for as long
/// as the camera stays in one kind of place. The moment it goes indoors every
/// one of them is wrong: the flat sky ambient comes from every direction and
/// nothing blocks it, so a hall with a roof on it is lit exactly as brightly
/// as the courtyard outside, and the air in it is the same clear air.
///
/// A volume is a region that says what is different about it. This one is
/// the hall's own box: darker, warmer, dustier, and a little graded. A second,
/// smaller one sits at the far end — a cold, damp corner — at a higher
/// priority, so where the two overlap its blue fog wins.
///
/// Nothing here is a new kind of rendering. The volumes are resolved against
/// the camera before the scene is sent, and the renderer is told a fog, a sky
/// and an exposure exactly as it always was — which is why the change is
/// continuous: it is the same settings, moving.
class EnvironmentVolumesExample extends Example {
  EnvironmentVolumesExample();

  @override
  String get name => 'Environment volumes';

  @override
  String get blurb =>
      'A sunny courtyard and a dim, dusty hall, and the look blending between '
      'them as the camera walks through the door.';

  /// Whether the camera walks in and out on its own.
  bool walking = true;

  /// Where along the walk the camera is, from the courtyard (nought) to the
  /// back of the hall (one), when it is not walking.
  double along = 0.3;

  /// Whether the volumes are applied at all, so the difference they make can
  /// be seen rather than described.
  bool volumes = true;

  /// How far outside the hall its look reaches, in metres.
  double blend = 4;

  /// Where the walk starts and ends. Straight down the middle of the
  /// doorway, at eye height.
  static final Vector3 _from = Vector3(0, 1.7, 14);
  static final Vector3 _to = Vector3(0, 1.7, -16);

  /// The hall: twenty metres deep behind a doorway at z = -4.
  static const double _front = -4;
  static const double _back = -24;
  static const double _halfWidth = 4;
  static const double _height = 5;

  /// Where the camera is, nought to one along the walk.
  double progressAt(double seconds) {
    if (!walking) return along;
    // There and back over twenty-four seconds, eased at each end so the
    // camera lingers in both places rather than bouncing off them.
    final phase = (seconds / 24) % 1;
    final triangle = phase < 0.5 ? phase * 2 : 2 - phase * 2;
    return 0.5 - 0.5 * math.cos(triangle * math.pi);
  }

  OrbisObject _box(
    int key,
    Vector3 at,
    Vector3 size,
    Color colour, {
    double turn = 0,
    bool casts = true,
  }) => OrbisObject(
    key: key,
    // The built-in cube runs from minus one to one, so a box [size] across
    // is the cube scaled by half of it. Getting this wrong closes the
    // doorway to half a metre, which is how it was found.
    transform: Matrix4.identity()
      ..setTranslation(at)
      ..rotateY(turn)
      ..scaleByDouble(size.x / 2, size.y / 2, size.z / 2, 1),
    colour: linearOf(colour),
    castShadows: casts,
  );

  /// The hall's volume, and the damp corner at the back of it.
  List<OrbisEnvironmentVolume> get _volumes => [
    OrbisEnvironmentVolume.box(
      key: 1,
      centre: Vector3(0, _height / 2, (_front + _back) / 2),
      halfExtents: Vector3(_halfWidth, _height / 2, (_front - _back) / 2),
      blendDistance: blend,
      overrides: OrbisEnvironmentOverrides(
        // Dust in the air, lit warm by the lamps.
        fogDensity: 0.09,
        fogColour: linearOf(const Color(0xFF8A6A4C)),
        fogHeightFalloff: 0,
        // A fraction of the sky's light gets in, and it is the colour of the
        // stone it has bounced off.
        ambient: 2000,
        skyColour: linearOf(const Color(0xFFC89A6A)),
        // Half a stop down: indoors should read as indoors, not as the
        // courtyard with the lights off and the exposure chasing it.
        exposureCompensation: -0.5,
        bloomStrength: 0.25,
        saturation: 0.85,
        temperature: 0.15,
      ),
    ),
    OrbisEnvironmentVolume.sphere(
      key: 2,
      centre: Vector3(0, 1.5, -20),
      radius: 3,
      blendDistance: 3,
      priority: 1,
      overrides: OrbisEnvironmentOverrides(
        fogDensity: 0.14,
        fogColour: linearOf(const Color(0xFF4A5C70)),
        skyColour: linearOf(const Color(0xFF7890B0)),
        temperature: -0.1,
      ),
    ),
  ];

  @override
  OrbisScene scene(OrbisCamera camera, double seconds) {
    final t = progressAt(seconds);
    final eye = _from + (_to - _from) * t;
    // Looking where it is going, a touch down, so the floor of the hall and
    // the doorway both stay in frame.
    final walkCamera = OrbisCamera(
      position: eye,
      target: eye + Vector3(0, -0.12, -1),
      fieldOfView: 60,
    );

    const stone = Color(0xFFB8AC98);
    const wallKey = 20;
    final walls = <OrbisObject>[
      // The two long walls, the back, and the roof that makes it a hall.
      _box(
        wallKey,
        Vector3(-_halfWidth - 0.25, _height / 2, (_front + _back) / 2),
        Vector3(0.5, _height, _front - _back),
        stone,
      ),
      _box(
        wallKey + 1,
        Vector3(_halfWidth + 0.25, _height / 2, (_front + _back) / 2),
        Vector3(0.5, _height, _front - _back),
        stone,
      ),
      _box(
        wallKey + 2,
        Vector3(0, _height / 2, _back - 0.25),
        Vector3(_halfWidth * 2 + 1, _height, 0.5),
        stone,
      ),
      _box(
        wallKey + 3,
        Vector3(0, _height + 0.25, (_front + _back) / 2 - 0.25),
        Vector3(_halfWidth * 2 + 1, 0.5, _front - _back + 0.5),
        stone,
      ),
      // The front, with a doorway three metres wide and three and a half
      // tall cut out of it.
      _box(
        wallKey + 4,
        Vector3(-2.75, _height / 2, _front + 0.25),
        Vector3(2.5, _height, 0.5),
        stone,
      ),
      _box(
        wallKey + 5,
        Vector3(2.75, _height / 2, _front + 0.25),
        Vector3(2.5, _height, 0.5),
        stone,
      ),
      _box(
        wallKey + 6,
        Vector3(0, 4.25, _front + 0.25),
        Vector3(3, 1.5, 0.5),
        stone,
      ),
    ];

    final things = <OrbisObject>[
      // Pillars down the hall, so there is depth in it to fog.
      for (var i = 0; i < 4; i++) ...[
        _box(
          40 + i * 2,
          Vector3(-2.2, _height / 2, -8 - i * 4.0),
          Vector3(0.6, _height, 0.6),
          const Color(0xFFCFC3AE),
        ),
        _box(
          41 + i * 2,
          Vector3(2.2, _height / 2, -8 - i * 4.0),
          Vector3(0.6, _height, 0.6),
          const Color(0xFFCFC3AE),
        ),
      ],
      // Out in the courtyard: something red and something blue in the sun.
      _box(
        60,
        Vector3(-4.5, 0.6, 6),
        Vector3(1.2, 1.2, 1.2),
        const Color(0xFFC8533F),
        turn: 0.4,
      ),
      _box(
        61,
        Vector3(4.2, 1.0, 3),
        Vector3(0.8, 2.0, 0.8),
        const Color(0xFF4F7FA8),
      ),
      _box(
        62,
        Vector3(1.4, 0.4, -14),
        Vector3(1.4, 0.8, 0.9),
        const Color(0xFF9C7A55),
        turn: -0.3,
      ),
    ];

    return OrbisScene(
      objects: [
        _box(
          10,
          Vector3(0, -0.1, -5),
          Vector3(60, 0.2, 60),
          const Color(0xFFD8D0C0),
          casts: false,
        ),
        ...walls,
        ...things,
      ],
      lights: [
        OrbisLight(
          key: 1,
          kind: OrbisLightKind.directional,
          // Low enough to throw the front wall's shadow into the courtyard,
          // and from behind the camera's shoulder so the courtyard is lit.
          direction: Vector3(0.35, -0.75, -0.55)..normalize(),
          colour: linearOf(const Color(0xFFFFF3E0)),
          intensity: 100000,
          castShadows: true,
        ),
        // Two warm lamps in the hall. The sun does not get in, and without
        // these the hall is lit by nothing but the ambient the volume turns
        // down.
        for (var i = 0; i < 2; i++)
          OrbisLight(
            key: 2 + i,
            kind: OrbisLightKind.point,
            position: Vector3(0, 3.8, -10 - i * 8.0),
            colour: linearOf(const Color(0xFFFFC88A)),
            // A few thousand lux on the floor beneath, which is about what
            // the volume leaves the ambient at — so the lamps read as pools
            // rather than disappearing into the wash.
            intensity: 600000,
            falloffRadius: 16,
            castShadows: false,
          ),
      ],
      sky: OrbisSky(
        colour: linearOf(const Color(0xFFA8C4E8)),
        zenith: Vector3(0.18, 0.36, 0.72),
        horizon: Vector3(0.66, 0.78, 0.92),
        ambient: 12000,
      ),
      // A little haze outdoors, so the courtyard has air in it too and the
      // hall's fog is a change of air rather than air appearing from nothing.
      fog: OrbisFog(
        density: 0.004,
        colour: linearOf(const Color(0xFFBCCCE0)),
        heightFalloff: 0.2,
      ),
      // The example drives the camera itself: the point is the walk through
      // the door, and an orbit round the origin would never go through it.
      camera: walkCamera,
      volumes: volumes ? _volumes : null,
    );
  }

  @override
  Widget settings(BuildContext context, VoidCallback changed) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Toggle(
        label: 'Volumes',
        value: volumes,
        onChanged: (value) {
          volumes = value;
          changed();
        },
      ),
      Toggle(
        label: 'Walk in and out',
        value: walking,
        onChanged: (value) {
          walking = value;
          changed();
        },
      ),
      Setting(
        label: 'Where',
        value: along,
        min: 0,
        max: 1,
        onChanged: (value) {
          along = value;
          walking = false;
          changed();
        },
      ),
      Setting(
        label: 'Blend distance',
        value: blend,
        min: 0,
        max: 10,
        unit: ' m',
        onChanged: (value) {
          blend = value;
          changed();
        },
      ),
    ],
  );

  @override
  String get code => '''
// The hall's own box, and what is different about being in it. Anything
// left out — here the environment, the contrast, the fog's height — is left
// exactly as the scene has it.
OrbisEnvironmentVolume.box(
  key: 1,
  centre: Vector3(0, 2.5, -14),
  halfExtents: Vector3(4, 2.5, 10),
  // Full strength inside; fading to nothing four metres out of the door.
  blendDistance: 4,
  overrides: OrbisEnvironmentOverrides(
    fogDensity: 0.09,
    fogColour: linearOf(const Color(0xFF8A6A4C)),
    ambient: 2000,          // lux, blended in log space
    skyColour: linearOf(const Color(0xFFC89A6A)),
    exposureCompensation: -0.5,   // stops
    bloomStrength: 0.25,
    saturation: 0.85,
    temperature: 0.15,
  ),
)

// A damp corner at the back, which wins where the two overlap.
OrbisEnvironmentVolume.sphere(
  key: 2,
  centre: Vector3(0, 1.5, -20),
  radius: 3,
  blendDistance: 3,
  priority: 1,
  overrides: OrbisEnvironmentOverrides(
    fogDensity: 0.14,
    fogColour: linearOf(const Color(0xFF4A5C70)),
  ),
)

// On the scene. They are resolved against the camera when it is sent, so
// nothing else has to know they are there.
OrbisScene(..., volumes: [hall, corner])
''';
}
