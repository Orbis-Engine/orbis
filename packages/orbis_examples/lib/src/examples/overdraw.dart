import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../example.dart';
import 'surface.dart' show linearOf;

/// Surfaces stacked deep in front of each other, and a depth prepass to see
/// whether shading each pixel once is worth drawing everything twice.
///
/// The renderer already sorts opaque objects nearest first, so a pile of
/// separate things standing one behind another is mostly shaded once without
/// any help: the near one fills the depth buffer and the GPU skips the rest.
/// What sorting cannot fix is surfaces that pass *through* each other. These
/// slabs all cross at the middle, so every one is in front of the others
/// somewhere and behind them somewhere else, and no order of objects is the
/// right order for every pixel. That is the case a prepass exists for.
///
/// Be ready for it to make no difference here. Apple's GPUs work out which
/// surface is in front for a whole tile before shading any of it, which is a
/// prepass in hardware, so on this machine the second pass is mostly cost.
/// The same scene on a desktop GPU with a heavy material is where it pays.
class OverdrawExample extends Example {
  OverdrawExample();

  @override
  String get name => 'Depth prepass';

  @override
  String get blurb =>
      'Slabs that pass through each other, shaded once per pixel with the '
      'depth laid down first — or as many times as they overlap without.';

  @override
  ViewPoint get viewpoint =>
      const ViewPoint(yaw: 0.3, pitch: 0.25, distance: 16, height: 0);

  /// Whether depth is laid down before anything is shaded.
  bool prepass = false;

  /// How many slabs cross at the middle: how deep the overdraw goes.
  double slabs = 48;

  /// Whether the slabs wear the dearest surface there is, so that shading a
  /// pixel twice actually costs something.
  bool heavy = true;

  static const int _material = 3;

  @override
  OrbisScene scene(OrbisCamera camera, double seconds) {
    final count = slabs.round();
    final pipeline = OrbisPipeline(depthPrepass: prepass);
    return OrbisScene(
      pipeline: pipeline,
      materials: [
        OrbisMaterial(
          key: _material,
          baseColour: Vector4(0.62, 0.42, 0.30, 1),
          roughness: 0.35,
          metallic: heavy ? 0.4 : 0.0,
          // A coat over a sheen over a stretched highlight: three more lobes
          // for every pixel, which is what makes overdraw show up as time.
          clearCoat: heavy ? 1.0 : 0.0,
          clearCoatRoughness: 0.15,
          anisotropy: heavy ? 0.7 : 0.0,
        ),
      ],
      objects: [
        for (var i = 0; i < count; i++)
          OrbisObject(
            key: 100 + i,
            material: _material,
            // Every slab through the middle at its own angle, so each is
            // nearest somewhere and furthest somewhere else.
            transform: Matrix4.identity()
              ..rotateY(i * math.pi / count)
              ..rotateX(math.sin(i * 1.7) * 0.35)
              ..scaleByDouble(5.0, 3.0, 0.05, 1),
            colour: Vector3(1, 1, 1),
            castShadows: false,
          ),
        OrbisObject(
          key: 1,
          transform: Matrix4.identity()
            ..setTranslation(Vector3(0, -3.2, 0))
            ..scaleByDouble(14, 0.05, 14, 1),
          colour: linearOf(const Color(0xFF3A4048)),
          castShadows: false,
        ),
      ],
      lights: [
        OrbisLight(
          key: 2,
          kind: OrbisLightKind.directional,
          intensity: 70000,
          direction: Vector3(-0.3, -1, -0.5)..normalize(),
        ),
        for (var i = 0; i < 6; i++)
          OrbisLight(
            key: 10 + i,
            kind: OrbisLightKind.point,
            intensity: 30000,
            position: Vector3(
              math.cos(i * 1.05) * 4,
              0.5,
              math.sin(i * 1.05) * 4,
            ),
            colour: linearOf(
              Color.lerp(
                const Color(0xFF5FA8D3),
                const Color(0xFFD9634F),
                i / 5,
              )!,
            ),
            falloffRadius: 9,
            castShadows: false,
          ),
      ],
      sky: OrbisSky(colour: linearOf(const Color(0xFF1D242E)), ambient: 9000),
      camera: camera,
    );
  }

  @override
  Widget settings(BuildContext context, VoidCallback changed) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Toggle(
        label: 'Depth prepass',
        value: prepass,
        onChanged: (value) {
          prepass = value;
          changed();
        },
      ),
      Setting(
        label: 'Slabs',
        value: slabs,
        min: 4,
        max: 160,
        decimals: 0,
        onChanged: (value) {
          slabs = value;
          changed();
        },
      ),
      Toggle(
        label: 'Heavy surface',
        value: heavy,
        onChanged: (value) {
          heavy = value;
          changed();
        },
      ),
    ],
  );

  @override
  String get code => '''
// One switch on the pipeline. Every opaque object that can be drawn depth-
// only exactly where it is shaded gets a twin that is: same geometry, same
// transform, the cheapest material there is, drawn before everything else.
// The real surfaces then find the nearest depth already in the buffer, and
// everything behind it fails the depth test before it is shaded.
OrbisScene(
  pipeline: OrbisPipeline(depthPrepass: true),
  objects: slabs,
  camera: camera,
)

// Surfaces that could draw depth where they are not then shaded are left
// out rather than risked: anything masked, see-through, swaying in the
// wind, pushed back by a depth bias, or not writing depth at all.
''';
}
