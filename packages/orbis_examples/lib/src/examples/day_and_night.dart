import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../example.dart';
import 'surface.dart' show linearOf;

/// A day, and the camera that makes it visible.
///
/// The arithmetic is the interesting part. A sun at noon lays about ninety
/// thousand lux on the ground and a moon lays one; that is seventeen stops,
/// and no single camera setting covers both. So the exposure is metered off
/// the light the scene actually has, the way a hand-held meter works, and
/// every hour of the day lands in the middle of the range.
class DayAndNightExample extends Example {
  DayAndNightExample();

  @override
  String get name => 'Day and night';

  @override
  String get blurb =>
      'A sun and a moon crossing the sky, with the camera metered for both.';

  @override
  ViewPoint get viewpoint => const ViewPoint(distance: 14, pitch: 0.18);

  double hour = 10;
  bool running = true;
  double hoursPerSecond = 0.6;
  double cover = 0.4;

  static Vector3 _mix(Vector3 from, Vector3 to, double t) => Vector3(
    from.x + (to.x - from.x) * t,
    from.y + (to.y - from.y) * t,
    from.z + (to.z - from.z) * t,
  );

  @override
  OrbisScene scene(OrbisCamera camera, double seconds) {
    final now = running ? (hour + seconds * hoursPerSecond) % 24 : hour;

    // Zero at six in the morning and pi at six in the evening, so the sun is
    // up for half of it and highest at noon.
    final swing = math.sin((now - 6) / 12 * math.pi);
    final isDay = swing > 0;

    final altitude = (isDay ? swing : -swing) * (65 * math.pi / 180);
    final azimuth = now / 24 * 2 * math.pi + (isDay ? 0 : math.pi);

    final toBody = Vector3(
      math.cos(altitude) * math.sin(azimuth),
      math.sin(altitude),
      math.cos(altitude) * math.cos(azimuth),
    );

    // The sun falls to the moon's own strength as it reaches the horizon, so
    // the handover is a change of direction rather than a step in how much
    // light there is.
    const moonlight = 1.0;
    final lux = isDay ? moonlight + 75000 * swing * swing : moonlight;
    // A clear sky gives back about a third of what lands on it.
    final ambient = math.max(0.2, lux * 0.35);

    final incident = lux * math.max(0, math.sin(altitude)) + ambient;

    final bodyColour = linearOf(
      isDay
          ? Color.lerp(
              const Color(0xFFFF8A3D),
              const Color(0xFFFFF4E5),
              (swing / 0.18).clamp(0.0, 1.0),
            )!
          : const Color(0xFFC3D4FF),
    );

    // Deep overhead and pale along the ground, and the lower the body sits
    // the more the horizon takes its colour — which is the whole of a
    // sunset. Worked out from where the body actually is, so it happens on
    // both sides of the day without either being written down.
    final flat = linearOf(_skyAt(swing));
    final glow = (1 - altitude / 0.45).clamp(0.0, 1.0);

    return OrbisScene(
      objects: [
        for (var i = 0; i < 6; i++)
          OrbisObject(
            key: 300 + i,
            transform: Matrix4.identity()
              ..setTranslation(
                Vector3(
                  (i % 3 - 1) * 2.6,
                  -0.5 + (i ~/ 3) * 0.0,
                  (i ~/ 3 - 0.5) * 2.8,
                ),
              )
              ..rotateY(i * 0.5)
              ..scaleByDouble(0.7, 0.9 + (i % 3) * 0.4, 0.7, 1),
            colour: linearOf(const Color(0xFFCFC7BB)),
          ),
        OrbisObject(
          key: 290,
          transform: Matrix4.identity()
            ..setTranslation(Vector3(0, -1.5, 0))
            ..scaleByDouble(14.0, 0.06, 14.0, 1),
          colour: linearOf(const Color(0xFF43494F)),
          castShadows: false,
        ),
      ],
      lights: [
        OrbisLight(
          key: 310,
          kind: OrbisLightKind.directional,
          intensity: lux,
          // Light travels from the body towards the scene, which is the way
          // the body is not.
          direction: -toBody
            ..normalize(),
          colour: bodyColour,
          sunAngularRadius: 0.53,
          // A wide soft halo reads as a sun through air; a tight one reads as
          // a moon on a clear night. It is most of what tells them apart.
          haloSize: isDay ? 12 : 3,
          haloFalloff: isDay ? 70 : 240,
        ),
      ],
      sky: OrbisSky(
        colour: flat,
        zenith: flat.clone()..scale(0.82),
        horizon: _mix(
          _mix(flat, Vector3(0.72, 0.80, 0.92), 0.28),
          bodyColour,
          glow * 0.55,
        ),
        ambient: ambient,
        // The same direction the light comes from, which is why the cloud
        // lights up on the side the sun is on and goes to shadow on the
        // other — through the whole day, without either being drawn.
        bodyDirection: toBody,
        bodyColour: bodyColour.clone()..scale(isDay ? 1.0 : 0.30),
        bodySize: 0.011,
        clouds: OrbisClouds.cumulus(cover: cover, wind: Vector2(5, 2)),
      ),
      camera: _metered(camera, incident),
    );
  }

  /// The sky through the day: night, the minute before dawn, an hour after
  /// it, and midday. Three stops would read as a filter being turned.
  Color _skyAt(double swing) {
    const night = Color(0xFF070C18);
    const dusk = Color(0xFF2A2438);
    const dawn = Color(0xFF7A5A63);
    const day = Color(0xFF6E96C8);

    if (swing <= 0) {
      return Color.lerp(dusk, night, (-swing / 0.25).clamp(0.0, 1.0))!;
    }
    if (swing < 0.18) return Color.lerp(dusk, dawn, swing / 0.18)!;
    return Color.lerp(dawn, day, ((swing - 0.18) / 0.5).clamp(0.0, 1.0))!;
  }

  /// The camera, set for the light that is actually falling on the scene.
  ///
  /// Incident metering: the calibration puts sunny sixteen at EV 15, which is
  /// where a century of film boxes says it goes. Then the three settings are
  /// chosen in a photographer's order — stop down while there is light to
  /// spare, then open up, then hold the shutter, and only then raise the
  /// sensitivity, because grain is the price paid last.
  OrbisCamera _metered(OrbisCamera camera, double lux) {
    final wanted = math.log(math.max(lux, 1e-5) * 100 / 250) / math.ln2;
    final light = math.pow(2, wanted).toDouble();

    var aperture = math.sqrt(light / 125);
    var shutter = 1 / 125;
    var sensitivity = 100.0;

    if (aperture > 22) {
      aperture = 22;
      shutter = (484 / light).clamp(1 / 4000, 1.0);
    } else if (aperture < 1.4) {
      aperture = 1.4;
      shutter = 1.96 / light;
      if (shutter > 1 / 30) {
        shutter = 1 / 30;
        sensitivity = (100 * 1.96 * 30 / light).clamp(50, 25600);
      }
    }

    return camera.copyWith(
      aperture: aperture,
      shutterSpeed: shutter,
      sensitivity: sensitivity,
    );
  }

  @override
  Widget settings(BuildContext context, VoidCallback changed) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Toggle(
          label: 'Running',
          value: running,
          onChanged: (value) {
            running = value;
            changed();
          },
        ),
        Setting(
          label: 'Hour',
          value: hour,
          min: 0,
          max: 24,
          onChanged: (value) {
            hour = value;
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
        if (running)
          Setting(
            label: 'Speed',
            value: hoursPerSecond,
            min: 0.05,
            max: 4,
            unit: ' h/s',
            onChanged: (value) {
              hoursPerSecond = value;
              changed();
            },
          ),
      ],
    );
  }

  @override
  String get code => '''
// Where the body is, at this hour.
final swing = sin((hour - 6) / 12 * pi);      // up for half the day
final isDay = swing > 0;
final altitude = (isDay ? swing : -swing) * radians(65);
final azimuth  = hour / 24 * 2 * pi + (isDay ? 0 : pi);   // the moon opposes

// The sun falls to the moon's own strength at the horizon, so the swap is a
// change of direction rather than a step in how much light there is.
final lux     = isDay ? 1.0 + 75000 * swing * swing : 1.0;
final ambient = max(0.2, lux * 0.35);         // a clear sky returns a third

OrbisScene(
  lights: [
    OrbisLight(
      key: 310,
      kind: OrbisLightKind.directional,
      intensity: lux,
      direction: -toBody..normalize(),
      sunAngularRadius: 0.53,     // the real sun's, and the real moon's
      haloSize: isDay ? 12 : 3,   // glare, or none: what tells them apart
    ),
  ],
  sky: OrbisSky(colour: skyAt(swing), ambient: ambient),
  // Seventeen stops between noon and moonlight. Meter it, or one of the two
  // is a solid colour.
  camera: camera.copyWith(
    aperture: aperture, shutterSpeed: shutter, sensitivity: iso,
  ),
)
''';
}
