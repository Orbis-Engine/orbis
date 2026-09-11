import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../example.dart';
import 'surface.dart' show linearOf;

/// Surfaces stacked deep in front of each other, to see what overdraw costs.
///
/// The renderer already sorts opaque objects nearest first, so a pile of
/// separate things standing one behind another is mostly shaded once without
/// any help: the near one fills the depth buffer and the GPU skips the rest.
/// What sorting cannot fix is surfaces that pass *through* each other. These
/// slabs all cross at the middle, so every one is in front of the others
/// somewhere and behind them somewhere else, and no order of objects is the
/// right order for every pixel. That is the case a depth prepass exists for.
///
/// It is also the scene that says a prepass is not worth turning on here. On
/// an Apple GPU, going from one slab to ninety-six of them — every one of them
/// wearing the dearest surface the engine has, three specular lobes and seven
/// lights — moves a frame from about 3.4 ms to about 3.9 ms, and forty-eight
/// slabs sometimes measures *faster* than one. The hardware works out which
/// surface wins a tile before it shades any of it, which is a prepass already,
/// so there is no fragment cost here left for a second pass to save and a
/// second pass would only add the draws. Where it should pay is a desktop
/// Vulkan or GL backend, which shades every layer it is handed in the order it
/// is handed them.
///
/// That is no longer a prediction. [OrbisScene.depthPrepass] builds the second
/// pass, and this scene was measured with it on and off, on an M4 Pro, three
/// runs each way — 3.97 ms against 4.10 ms at ninety-six slabs, 3.84 against
/// 3.89 at forty-eight, and 3.47 either way at one. The spread within a single
/// setting is a hundredth of a millisecond, so the loss at ninety-six slabs is
/// real rather than noise. A prepass on this hardware costs about three per
/// cent and returns nothing, which is why the switch ships off.
///
/// To reproduce, with the clock pinned so two runs are the same picture:
///
/// ```sh
/// ORBIS_EXAMPLE=Overdraw ORBIS_SLABS=96 ORBIS_SECONDS=2 ORBIS_CIRCLING=0 \
///   ORBIS_PREPASS=0 ORBIS_DUMP_FRAME=180 orbis_gallery
/// ```
///
/// and again with `ORBIS_PREPASS=1`; the frame's cost is on the
/// `[orbis] frame 180:` line. Gallery frame dumps share one path, so two of
/// these must not run at once.
///
/// The other half of the answer needed a GPU that is not tile-based, which no
/// Apple machine has. This same scene was built into the Flutter-free headless
/// host (`ORBIS_SLABS`) and run under Mesa's llvmpipe in a Linux container — a
/// software rasteriser, so immediate-mode by construction, shading every layer
/// it is handed. There the prepass roughly halves the frame: 40.9 ms against
/// 21.3 ms at ninety-six slabs, 44.0 against 17.3 at forty-eight, medians of
/// three runs. At one slab it is 11.0 against 11.3 — the control, and the same
/// small loss the Apple GPU shows, because with nothing hidden there is
/// nothing to save.
///
/// The picture is bit-identical with the prepass on and off, on both backends:
/// 0 of 518400 pixels differ. That is worth stating because it was not true of
/// the first attempt — a prepass entity sitting exactly on the surface it
/// stands in for occludes that surface in the structure buffer that contact
/// shadows march along, and one per cent of the frame came back visibly darker
/// until the depth-only draw was pushed a hair behind.
class OverdrawExample extends Example {
  OverdrawExample();

  @override
  String get name => 'Overdraw';

  @override
  String get blurb =>
      'Slabs that pass through each other, so that every pixel is covered as '
      'many times as they overlap.';

  @override
  ViewPoint get viewpoint =>
      const ViewPoint(yaw: 0.3, pitch: 0.25, distance: 16, height: 0);

  /// How many slabs cross at the middle: how deep the overdraw goes.
  double slabs = 48;

  /// Whether the slabs wear the dearest surface there is, so that shading a
  /// pixel twice actually costs something.
  bool heavy = true;

  static const int _material = 3;

  @override
  OrbisScene scene(OrbisCamera camera, double seconds) {
    final count = slabs.round();
    return OrbisScene(
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
// Slabs all crossing at the middle, so no order of objects is the right
// order for every pixel and each one is covered many times over.
OrbisScene(
  materials: [OrbisMaterial(key: 3, clearCoat: 1, anisotropy: 0.7)],
  objects: [
    for (var i = 0; i < 48; i++)
      OrbisObject(
        key: 100 + i,
        material: 3,
        transform: Matrix4.identity()
          ..rotateY(i * math.pi / 48)
          ..scaleByDouble(5, 3, 0.05, 1),
      ),
  ],
  camera: camera,
)

// What it is for is measuring. Turn the slabs up and watch the frame's GPU
// time: on this machine it barely moves, because the hardware already
// decides which surface wins a tile before shading any of it.
''';
}
