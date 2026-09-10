import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../example.dart';
import 'surface.dart' show linearOf;

/// Which of Filament's own lights is casting.
enum ShadowLight {
  sun('Sun'),
  spot('Spot'),
  point('Point');

  const ShadowLight(this.label);

  final String label;
}

/// Every shadow setting Filament has, on one set of objects.
///
/// A sun, a spot and a bare bulb all cast through the same machinery — a
/// depth map drawn from the light, compared against by every surface — and
/// differ in its shape: a sun's map is split into cascades running away from
/// the camera, a spot's is one perspective map, and a bulb's is six of them,
/// one per face of a cube. So the settings that matter differ too, and the
/// only way to learn which is which is to move them with the light that
/// reads them.
///
/// What each does is easiest seen at an edge. The stick lying on the floor
/// is for contact shadows: its shadow map is too coarse to put anything
/// between a centimetre-thick stick and the ground under it, and a short
/// march through the depth buffer is what does. The colonnade is for
/// cascades: its nearest shadow is a metre from the camera and its furthest
/// fifty, and a single map across that distance is a centimetre per texel at
/// best.
///
/// Two things this shows that are Filament's behaviour rather than a fault
/// here, both worth meeting in an example instead of in a bug report. Soft
/// and Area draw the same picture — byte-identical over a whole frame —
/// because Filament 1.76 marks its DPCF path deprecated and serves it with
/// PCSS. And Contact shadows put a grain over the far half of this floor:
/// the march finds the floor itself where the floor is nearly edge-on, and
/// nothing exposed tightens it. The floor here is deliberately a hundred and
/// twenty metres across, which is the worst case for it.
class ShadowsExample extends Example {
  ShadowsExample();

  @override
  String get name => 'Shadows';

  @override
  String get blurb =>
      'Filament\'s own shadows: sun, spot and point, with every setting — '
      'map size, cascades and splits, bias, distance, contact shadows, and '
      'the four kinds of edge.';

  @override
  ViewPoint get viewpoint =>
      const ViewPoint(distance: 14, pitch: 0.32, yaw: 0.55, height: 1.0);

  ShadowLight light = ShadowLight.sun;

  /// The pipeline's shadow settings, shared by whichever light casts.
  final OrbisShadows shadows = OrbisShadows(cascades: 3, distance: 60);

  /// Whether the cascades are placed by hand, and where the first ends.
  bool handSplits = false;
  double firstSplit = 0.08;

  /// How big the light is — what the area kind makes its penumbra from, and
  /// nothing else reads. Metres for a spot or a bulb; for the sun, degrees
  /// of sky, because a sun is an angle rather than a size.
  double lightSize = 0.4;

  static const int _floor = 1;

  @override
  OrbisScene scene(OrbisCamera camera, double seconds) {
    final objects = <OrbisObject>[
      OrbisObject(
        key: _floor,
        transform: Matrix4.identity()
          ..setTranslation(Vector3(0, -1.5, 0))
          ..scaleByDouble(120, 0.05, 120, 1),
        colour: linearOf(const Color(0xFFB9B4AA)),
        // A floor that casts is a plane shadowing itself, which is acne.
        castShadows: false,
      ),
      // The stick: a centimetre and a half thick, lying on the floor, so its
      // shadow is the contact shadow and nothing else.
      OrbisObject(
        key: 2,
        transform: Matrix4.identity()
          ..setTranslation(Vector3(0.6, -1.465, 2.6))
          ..rotateY(0.4)
          ..scaleByDouble(2.2, 0.02, 0.05, 1),
        colour: linearOf(const Color(0xFF3A3F47)),
      ),
      // Something in the middle, with an overhang to shadow its own base.
      OrbisObject(
        key: 3,
        transform: Matrix4.identity()
          ..setTranslation(Vector3(-0.8, -0.6, 0.6))
          ..rotateY(0.6)
          ..scaleByDouble(1.2, 1.8, 1.2, 1),
        colour: linearOf(const Color(0xFFD9634F)),
      ),
      OrbisObject(
        key: 4,
        transform: Matrix4.identity()
          ..setTranslation(Vector3(-0.8, 0.55, 0.6))
          ..rotateY(0.2)
          ..scaleByDouble(2.2, 0.12, 2.2, 1),
        colour: linearOf(const Color(0xFFE8E4DC)),
      ),
    ];
    // The colonnade, running away from the camera.
    for (var i = 0; i < 12; i++) {
      objects.add(
        OrbisObject(
          key: 100 + i,
          transform: Matrix4.identity()
            ..setTranslation(Vector3(3.0, 0.1, 2.0 - i * 4.0))
            ..scaleByDouble(0.4, 3.2, 0.4, 1),
          colour: linearOf(const Color(0xFF7FA8B8)),
        ),
      );
    }

    shadows.splits = handSplits
        ? [
            for (var i = 1; i < shadows.cascades; i++)
              // The first where it was asked for, the rest spread
              // evenly between it and the far end.
              firstSplit + (1 - firstSplit) * (i - 1) / (shadows.cascades - 1),
          ]
        : null;

    return OrbisScene(
      objects: objects,
      camera: camera,
      pipeline: OrbisPipeline(shadows: shadows),
      lights: [_light()],
      sky: OrbisSky(colour: Vector3(0.24, 0.33, 0.46), ambient: 9000),
    );
  }

  OrbisLight _light() => switch (light) {
    ShadowLight.sun => OrbisLight(
      key: 900,
      kind: OrbisLightKind.directional,
      // Low and across, so shadows are long and the far ones are where the
      // cascades run out.
      direction: Vector3(-0.55, -0.5, -0.67)..normalize(),
      intensity: 95000,
      // A sun's size is an angle, not a length: what the Area edge makes
      // its penumbra from. The real one is about a quarter of a degree.
      sunAngularRadius: lightSize,
      sourceRadius: lightSize,
    ),
    ShadowLight.spot => OrbisLight(
      key: 901,
      kind: OrbisLightKind.spot,
      position: Vector3(3.5, 5, 5),
      direction: Vector3(-0.5, -0.75, -0.6)..normalize(),
      // Lumens, and a lot of them: this has to hold its own against the
      // sky's ambient, or its shadow is a shade of a shade.
      intensity: 2000000,
      falloffRadius: 30,
      innerConeAngle: 0.45,
      outerConeAngle: 0.7,
      sourceRadius: lightSize,
    ),
    ShadowLight.point => OrbisLight(
      key: 902,
      kind: OrbisLightKind.point,
      position: Vector3(1.2, 2.6, 2.4),
      intensity: 3000000,
      falloffRadius: 25,
      sourceRadius: lightSize,
    ),
  };

  @override
  Widget settings(BuildContext context, VoidCallback changed) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Choice(
        label: 'Light',
        options: [for (final one in ShadowLight.values) one.label],
        selected: light.label,
        onSelect: (label) {
          light = ShadowLight.values.firstWhere((one) => one.label == label);
          changed();
        },
      ),
      Toggle(
        label: 'Shadows',
        value: shadows.enabled,
        onChanged: (value) {
          shadows.enabled = value;
          changed();
        },
      ),
      if (shadows.enabled) ..._shadowSettings(changed),
    ],
  );

  List<Widget> _shadowSettings(VoidCallback changed) => [
    Choice(
      label: 'Edge',
      options: [for (final one in OrbisShadowKind.values) one.label],
      selected: shadows.kind.label,
      onSelect: (label) {
        shadows.kind = OrbisShadowKind.values.firstWhere(
          (one) => one.label == label,
        );
        changed();
      },
    ),
    Setting(
      label: 'Map size',
      value: math.log(shadows.mapSize / 256) / math.ln2,
      min: 0,
      max: 4,
      decimals: 0,
      onChanged: (value) {
        shadows.mapSize = 256 * math.pow(2, value.round()).toInt();
        changed();
      },
    ),
    if (light == ShadowLight.sun) ...[
      Setting(
        label: 'Cascades',
        value: shadows.cascades.toDouble(),
        min: 1,
        max: 4,
        decimals: 0,
        onChanged: (value) {
          shadows.cascades = value.round();
          changed();
        },
      ),
      Toggle(
        label: 'Place splits by hand',
        value: handSplits,
        onChanged: (value) {
          handSplits = value;
          changed();
        },
      ),
      if (handSplits)
        Setting(
          label: 'First split',
          value: firstSplit,
          min: 0.02,
          max: 0.6,
          decimals: 2,
          onChanged: (value) {
            firstSplit = value;
            changed();
          },
        )
      else
        Setting(
          label: 'Split lambda',
          value: shadows.lambda,
          min: 0,
          max: 1,
          decimals: 2,
          onChanged: (value) {
            shadows.lambda = value;
            changed();
          },
        ),
      Toggle(
        label: 'Stable',
        value: shadows.stable,
        onChanged: (value) {
          shadows.stable = value;
          changed();
        },
      ),
    ],
    Setting(
      label: 'Distance',
      value: shadows.distance,
      min: 0,
      max: 200,
      unit: ' m',
      onChanged: (value) {
        shadows.distance = value;
        changed();
      },
    ),
    Setting(
      label: 'Constant bias',
      value: shadows.constantBias,
      min: 0,
      max: 0.05,
      decimals: 3,
      onChanged: (value) {
        shadows.constantBias = value;
        changed();
      },
    ),
    Setting(
      label: 'Normal bias',
      value: shadows.normalBias,
      min: 0,
      max: 4,
      decimals: 2,
      onChanged: (value) {
        shadows.normalBias = value;
        changed();
      },
    ),
    Toggle(
      label: 'Contact shadows',
      value: shadows.contact,
      onChanged: (value) {
        shadows.contact = value;
        changed();
      },
    ),
    if (shadows.contact)
      Setting(
        label: 'Contact distance',
        value: shadows.contactDistance,
        min: 0.05,
        max: 2,
        unit: ' m',
        decimals: 2,
        onChanged: (value) {
          shadows.contactDistance = value;
          changed();
        },
      ),
    if (shadows.kind == OrbisShadowKind.soft ||
        shadows.kind == OrbisShadowKind.area)
      Setting(
        label: 'Softness',
        value: shadows.softness,
        min: 0.1,
        max: 8,
        decimals: 1,
        onChanged: (value) {
          shadows.softness = value;
          changed();
        },
      ),
    if (shadows.kind == OrbisShadowKind.area) ...[
      Setting(
        label: 'Light size',
        value: lightSize,
        min: 0.02,
        max: 2,
        unit: light == ShadowLight.sun ? '°' : ' m',
        decimals: 2,
        onChanged: (value) {
          lightSize = value;
          changed();
        },
      ),
      Setting(
        label: 'Penumbra falloff',
        value: shadows.softnessFalloff,
        min: 0.2,
        max: 4,
        decimals: 1,
        onChanged: (value) {
          shadows.softnessFalloff = value;
          changed();
        },
      ),
    ],
    if (shadows.kind == OrbisShadowKind.variance) ...[
      Setting(
        label: 'Blur',
        value: shadows.variance.blur,
        min: 0,
        max: 20,
        unit: ' px',
        decimals: 1,
        onChanged: (value) {
          shadows.variance.blur = value;
          changed();
        },
      ),
      Setting(
        label: 'Light bleed reduction',
        value: shadows.variance.lightBleedReduction,
        min: 0,
        max: 1,
        decimals: 2,
        onChanged: (value) {
          shadows.variance.lightBleedReduction = value;
          changed();
        },
      ),
      Toggle(
        label: 'High precision',
        value: shadows.variance.highPrecision,
        onChanged: (value) {
          shadows.variance.highPrecision = value;
          changed();
        },
      ),
    ],
  ];

  @override
  String get code => '''
// Shadow settings belong to the pipeline, not to one light: every light
// that casts reads them. Filament keeps them on each light internally, and
// the renderer copies them onto every one whenever they change.
OrbisScene(
  pipeline: OrbisPipeline(
    shadows: OrbisShadows(
      // Sharp (PCF), Soft (DPCF), Area (PCSS) or Variance (VSM).
      kind: OrbisShadowKind.area,
      mapSize: 2048,
      // A sun's map split into cascades running away from the camera. The
      // splits are fractions of the distance; null lets lambda place them.
      cascades: 3,
      splits: [0.08, 0.3],
      distance: 60,
      constantBias: 0.001,
      normalBias: 1.0,
      // Locked to the world, so an edge does not crawl as the camera turns.
      stable: true,
      // A short march through the depth buffer, for what is too small for
      // the map: a stick on the floor, a foot on the ground.
      contact: true,
      contactDistance: 0.3,
      // For Area: how wide, and how fast it widens with distance.
      softness: 1.0,
      softnessFalloff: 1.0,
      // Only Variance reads these.
      variance: OrbisVarianceShadows(blur: 4, lightBleedReduction: 0.3),
    ),
  ),
  lights: [
    OrbisLight(
      key: 1,
      kind: OrbisLightKind.spot,
      // The light's real size: what an Area edge is made from.
      sourceRadius: 0.4,
      castShadows: true,
      ...
    ),
  ],
  ...
)

// Not reachable: caching a shadow map between frames. Filament redraws
// every map every frame and has no API to hold one still.
''';
}
