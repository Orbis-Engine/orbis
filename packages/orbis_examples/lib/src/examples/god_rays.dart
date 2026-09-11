import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../example.dart';
import 'surface.dart' show linearOf;

/// A low sun behind a colonnade, and the shafts of light between the pillars.
///
/// A shaft is not light itself but air: the air in a gap between two pillars
/// is lit and scatters some of that light towards the eye, while the air in a
/// pillar's shadow is not and does not. So the shafts are the colonnade's
/// shadows seen from inside the volume they fall through, and they point at
/// the sun because every shadow does.
///
/// A low sun behind the subject is the arrangement that shows it most, which
/// is why it is the one every photograph of a cathedral is taken in. Turn the
/// bearing round and the shafts fade as the sun leaves the frame and are gone
/// once it is behind the camera; raise the cloud and they thin.
class GodRaysExample extends Example {
  GodRaysExample();

  @override
  String get name => 'God rays';

  @override
  String get blurb =>
      'A low sun behind a colonnade, and the shafts of light the air between '
      'the pillars catches.';

  @override
  ViewPoint get viewpoint =>
      const ViewPoint(yaw: 0, pitch: 0.04, distance: 15, height: 1.2);

  bool on = true;
  double strength = 0.8;
  double decay = 0.97;
  double density = 0.9;
  double samples = 64;

  /// Degrees round from straight ahead of where the example opens: nought is
  /// the sun behind the colonnade, 180 is the sun behind the camera.
  double bearing = 0;

  /// Degrees above the horizon. Low enough, from where the example opens,
  /// that the sun sits in the gap under the lintel rather than above it.
  double altitude = 5;
  double cover = 0;

  static const int _floor = 10;
  static const int _lintel = 11;
  static const int _pillars = 20;

  OrbisObject _box(int key, Vector3 at, Vector3 half, Color colour) =>
      OrbisObject(
        key: key,
        transform: Matrix4.identity()
          ..setTranslation(at)
          ..scaleByDouble(half.x, half.y, half.z, 1),
        colour: linearOf(colour),
        castShadows: true,
      );

  @override
  OrbisScene scene(OrbisCamera camera, double seconds) {
    final up = altitude * math.pi / 180;
    final round = bearing * math.pi / 180;
    final toSun = Vector3(
      math.sin(round) * math.cos(up),
      math.sin(up),
      -math.cos(round) * math.cos(up),
    );

    const lux = 60000.0;
    final sunColour = linearOf(const Color(0xFFFFC98A));
    const ambient = lux * 0.3;
    final incident = lux * math.max(0, math.sin(up)) + ambient;

    return OrbisScene(
      objects: [
        _box(
          _floor,
          Vector3(0, -1.6, 0),
          Vector3(16, 0.1, 16),
          const Color(0xFF8C8478),
        ),
        // Nine pillars and a lintel over them, so the sun is only seen
        // through the gaps: every shaft is one gap.
        for (var i = 0; i < 9; i++)
          _box(
            _pillars + i,
            Vector3((i - 4) * 1.5, 1.5, -2),
            Vector3(0.24, 3, 0.24),
            const Color(0xFFD8CFC0),
          ),
        _box(
          _lintel,
          Vector3(0, 4.75, -2),
          Vector3(7, 0.25, 0.4),
          const Color(0xFFD8CFC0),
        ),
      ],
      lights: [
        OrbisLight(
          key: 1,
          kind: OrbisLightKind.directional,
          intensity: lux,
          direction: -toSun,
          colour: sunColour,
          sunAngularRadius: 0.53,
          haloSize: 12,
          haloFalloff: 70,
          castShadows: true,
        ),
      ],
      sky: OrbisSky(
        colour: linearOf(const Color(0xFF7D8FAE)),
        zenith: linearOf(const Color(0xFF4F6C98)),
        horizon: linearOf(const Color(0xFFE9B889)),
        ambient: ambient,
        bodyDirection: toSun,
        bodyColour: sunColour,
        bodySize: 0.011,
        clouds: cover > 0.01
            ? OrbisClouds.cumulus(cover: cover, wind: Vector2(3, 1))
            : OrbisClouds.none,
      ),
      // The only line the shafts need. No graph: the renderer puts in the
      // passes it needs, and takes them out again when this is off.
      godRays: on
          ? OrbisGodRays(
              strength: strength,
              decay: decay,
              density: density,
              samples: samples.round(),
            )
          : OrbisGodRays.off,
      camera: _metered(camera, incident),
    );
  }

  /// The camera set for the light falling on the scene, as the Day and night
  /// example does it: sunny sixteen at EV 15, stopping down first.
  OrbisCamera _metered(OrbisCamera camera, double lux) {
    final light = math.max(lux, 1e-5) * 100 / 250;
    final aperture = math.sqrt(light / 125).clamp(1.4, 22.0);
    final shutter = (aperture * aperture / light).clamp(1 / 4000, 1 / 30);
    return camera.copyWith(
      aperture: aperture,
      shutterSpeed: shutter,
      sensitivity: 100,
    );
  }

  @override
  Widget settings(BuildContext context, VoidCallback changed) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Toggle(
        label: 'God rays',
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
        max: 2,
        onChanged: (value) {
          strength = value;
          changed();
        },
      ),
      Setting(
        label: 'Decay',
        value: decay,
        min: 0.85,
        max: 1,
        onChanged: (value) {
          decay = value;
          changed();
        },
      ),
      Setting(
        label: 'Density',
        value: density,
        min: 0.2,
        max: 1.2,
        onChanged: (value) {
          density = value;
          changed();
        },
      ),
      Setting(
        label: 'Samples',
        value: samples,
        min: 8,
        max: 128,
        onChanged: (value) {
          samples = value;
          changed();
        },
      ),
      Setting(
        label: 'Sun bearing',
        value: bearing,
        min: -180,
        max: 180,
        unit: '°',
        onChanged: (value) {
          bearing = value;
          changed();
        },
      ),
      Setting(
        label: 'Sun altitude',
        value: altitude,
        min: 2,
        max: 40,
        unit: '°',
        onChanged: (value) {
          altitude = value;
          changed();
        },
      ),
      Setting(
        label: 'Cloud cover',
        value: cover,
        min: 0,
        max: 1,
        onChanged: (value) {
          cover = value;
          changed();
        },
      ),
    ],
  );

  @override
  String get code => '''
// The scene's own directional light is the sun the shafts come from, so
// they always point where the shadows do. Nothing else to wire up: with no
// graph of its own, the scene gets the passes it needs.
OrbisScene(
  lights: [sun],
  godRays: OrbisGodRays(
    strength: 0.8,  // how bright; nought is off, and free
    decay: 0.97,    // how far along its length a shaft fades
    density: 0.9,   // how far towards the sun each pixel looks
    samples: 64,    // smoothness against cost
  ),
  ...
)
''';
}
