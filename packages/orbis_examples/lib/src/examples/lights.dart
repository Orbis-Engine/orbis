import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../example.dart';
import 'surface.dart' show linearOf;

/// What a light is, stated in the units a light is sold in.
///
/// A sun is lux, a bulb is lumens, and the renderer takes both. What changes
/// between them is not brightness but shape: where the light comes from, how
/// far it reaches, and how wide the source is — which is what decides whether
/// a shadow has an edge.
class LightsExample extends Example {
  LightsExample();

  @override
  String get name => 'Lights';

  @override
  String get blurb =>
      'Sun, point and spot, in lux and lumens, with the shadows each casts.';

  @override
  ViewPoint get viewpoint => const ViewPoint(distance: 13, pitch: 0.28);

  String kind = 'Sun';
  double intensity = 82000;
  double cone = 45;
  double sourceWidth = 0.5;
  double panelWidth = 3;
  double panelHeight = 1.4;
  bool shadows = true;
  bool orbiting = true;

  @override
  OrbisScene scene(OrbisCamera camera, double seconds) {
    final turn = orbiting ? seconds * 0.4 : 1.1;
    final from = Vector3(math.sin(turn) * 4.5, 3.4, math.cos(turn) * 4.5);

    // A light points down its own -Z, and here it is aimed at the floor in
    // the middle, which is what makes the cone visible as it goes round.
    final aim = (Vector3(0, 0.2, 0) - from)..normalize();

    return OrbisScene(
      objects: [
        for (var i = 0; i < 5; i++)
          OrbisObject(
            key: 100 + i,
            transform: Matrix4.identity()
              ..setTranslation(
                Vector3(
                  math.cos(i / 5 * math.pi * 2) * 2.4,
                  -0.4 + (i.isEven ? 0.35 : 0),
                  math.sin(i / 5 * math.pi * 2) * 2.4,
                ),
              )
              ..rotateY(i * 0.7)
              ..scaleByDouble(0.55, i.isEven ? 0.9 : 0.55, 0.55, 1),
            colour: linearOf(
              i.isEven ? const Color(0xFFD9634F) : const Color(0xFFE8E4DC),
            ),
          ),
        OrbisObject(
          key: 90,
          transform: Matrix4.identity()
            ..setTranslation(Vector3(0, -1.4, 0))
            ..scaleByDouble(9.0, 0.06, 9.0, 1),
          colour: linearOf(const Color(0xFF39404A)),
          // A floor that casts is a floor casting a shadow onto itself, and
          // the acne that produces is most of what makes a scene look dirty.
          castShadows: false,
        ),
      ],
      lights: [
        switch (kind) {
          'Point' => OrbisLight(
            key: 200,
            kind: OrbisLightKind.point,
            // Lumens: the whole output of the bulb, spread over a sphere.
            intensity: intensity,
            position: from,
            falloffRadius: 24,
            sourceRadius: sourceWidth,
            castShadows: shadows,
            colour: linearOf(const Color(0xFFFFE9C8)),
          ),
          'Spot' => OrbisLight(
            key: 200,
            kind: OrbisLightKind.spot,
            intensity: intensity,
            position: from,
            direction: aim,
            falloffRadius: 24,
            // Full brightness inside the inner angle, gone by the outer.
            innerConeAngle: math.max(cone * 0.55, 1) * math.pi / 180,
            outerConeAngle: cone * math.pi / 180,
            sourceRadius: sourceWidth,
            castShadows: shadows,
            colour: linearOf(const Color(0xFFFFF0D8)),
          ),
          'Panel' => OrbisLight(
            key: 200,
            kind: OrbisLightKind.area,
            // Lumens, like a bulb — but coming off a surface rather than out
            // of a point, so making the panel bigger spreads the same light
            // wider and softens its edge instead of brightening the room.
            intensity: intensity,
            position: from,
            // The face it emits from. A rectangle is one-sided: turn it round
            // and the scene goes dark.
            direction: aim,
            // Which way the width runs. Without it the panel is free to spin
            // in its own plane, and a strip on its side is a different light.
            tangent: Vector3(math.cos(turn), 0, -math.sin(turn)),
            width: panelWidth,
            height: panelHeight,
            falloffRadius: 24,
            colour: linearOf(const Color(0xFFFFF0D8)),
          ),
          _ => OrbisLight(
            key: 200,
            kind: OrbisLightKind.directional,
            // Lux: a sun has no total to state, only a strength per square
            // metre of whatever it lands on.
            intensity: intensity,
            direction: (Vector3(0, -1.1, 0) + from * -0.35)..normalize(),
            // Half the width of the disc in the sky. It is why an outdoor
            // shadow is crisp at your feet and soft at its far end.
            sunAngularRadius: math.max(sourceWidth, 0.25),
            castShadows: shadows,
            colour: linearOf(const Color(0xFFFFF3E0)),
          ),
        },
      ],
      sky: OrbisSky(
        colour: linearOf(const Color(0xFF161C25)),
        ambient: 6000,
        showBody: kind == 'Sun',
      ),
      camera: camera,
    );
  }

  @override
  Widget settings(BuildContext context, VoidCallback changed) {
    final punctual = kind != 'Sun';
    // A panel states its size as two edges, so the single 'how wide is the
    // source' slider has nothing to say about it.
    final hasSource = kind != 'Panel';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Choice(
          label: 'Kind',
          options: const ['Sun', 'Point', 'Spot', 'Panel'],
          selected: kind,
          onSelect: (option) {
            kind = option;
            // The units change with the kind, so the number does too. A
            // hundred thousand lumens is a floodlight; a hundred thousand lux
            // is the sun. A panel wants more than a bulb for the same effect
            // in shot: its flux leaves a whole surface rather than a filament,
            // so the same lumens land as a gentler wash.
            intensity = switch (option) {
              'Sun' => 82000.0,
              'Panel' => 260000.0,
              _ => 12000.0,
            };
            changed();
          },
        ),
        Setting(
          label: punctual ? 'Lumens' : 'Lux',
          value: intensity,
          min: 0,
          max: kind == 'Panel'
              ? 600000
              : punctual
              ? 60000
              : 140000,
          decimals: 0,
          onChanged: (value) {
            intensity = value;
            changed();
          },
        ),
        if (kind == 'Panel') ...[
          Setting(
            label: 'Panel width',
            value: panelWidth,
            min: 0.1,
            max: 8,
            unit: ' m',
            onChanged: (value) {
              panelWidth = value;
              changed();
            },
          ),
          Setting(
            label: 'Panel height',
            value: panelHeight,
            min: 0.1,
            max: 8,
            unit: ' m',
            onChanged: (value) {
              panelHeight = value;
              changed();
            },
          ),
        ],
        if (kind == 'Spot')
          Setting(
            label: 'Cone',
            value: cone,
            min: 5,
            max: 120,
            unit: '°',
            decimals: 0,
            onChanged: (value) {
              cone = value;
              changed();
            },
          ),
        if (hasSource)
          Setting(
            label: punctual ? 'Bulb radius' : 'Sun size',
            value: sourceWidth,
            min: 0.05,
            max: punctual ? 2 : 8,
            unit: punctual ? ' m' : '°',
            onChanged: (value) {
              sourceWidth = value;
              changed();
            },
          ),
        if (hasSource)
          Toggle(
            label: 'Shadows',
            value: shadows,
            onChanged: (value) {
              shadows = value;
              changed();
            },
          ),
        Toggle(
          label: 'Circling',
          value: orbiting,
          onChanged: (value) {
            orbiting = value;
            changed();
          },
        ),
      ],
    );
  }

  @override
  String get code => '''
// Sun: lux, and a width in degrees that decides how soft its shadows are.
OrbisLight(
  key: 200,
  kind: OrbisLightKind.directional,
  intensity: 82000,                  // lux
  direction: Vector3(-0.4, -1, -0.5)..normalize(),
  sunAngularRadius: 0.53,            // degrees; the real sun's
  castShadows: true,
)

// Point: lumens, a position, and a distance it stops mattering past.
OrbisLight(
  key: 200,
  kind: OrbisLightKind.point,
  intensity: 12000,                  // lumens
  position: Vector3(3, 3.4, 3),
  falloffRadius: 24,                 // metres
  sourceRadius: 0.5,                 // how wide the bulb is
)

// Spot: the same, aimed, with the cone it throws.
OrbisLight(
  key: 200,
  kind: OrbisLightKind.spot,
  intensity: 12000,
  position: Vector3(3, 3.4, 3),
  direction: aim,
  innerConeAngle: 25 * pi / 180,     // full brightness inside this
  outerConeAngle: 45 * pi / 180,     // nothing outside it
)

// Watts, metres and degrees belong in orbis_light, which converts them once.
''';
}
