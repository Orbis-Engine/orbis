import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../example.dart';
import 'surface.dart' show linearOf;

/// Many copies of one thing, drawn as few things.
///
/// Every crate here is an ordinary [OrbisObject] with its own key, and
/// nothing about how the scene is written changes when batching is switched
/// on. What changes is on the far side: crates that are the same mesh, made
/// of the same stuff, with the same shadow settings, are made to share one
/// material instance, and the renderer merges their draws into instanced ones
/// that each carry every copy's own transform.
///
/// Three things are worth trying. Flip Batching and the picture should not
/// move by a pixel — that is the promise, and it was measured rather than
/// assumed. Change the palette from one colour to every crate different, and
/// the batching has nothing left to do, because on the default surface a
/// crate's colour *is* its material. And turn Moving on: one crate in the
/// middle keeps turning, and only that one crate's transform is written each
/// frame, batched or not.
class BatchingExample extends Example {
  BatchingExample();

  @override
  String get name => 'Batching';

  @override
  String get blurb =>
      'Thousands of identical crates, merged into instanced draws without the '
      'scene saying so.';

  @override
  ViewPoint get viewpoint =>
      const ViewPoint(yaw: 0.5, pitch: 0.55, distance: 46, height: 0);

  /// Whether identical crates are merged.
  bool batching = true;

  /// How many crates there are.
  double count = 3000;

  /// How many different colours they come in: one, a handful, or one each.
  String palette = 'One';

  /// Whether they are made of a shared material rather than the default
  /// surface tinted by their colour.
  bool material = false;

  /// A model to use instead of the built-in cube, or null. Set by the gallery
  /// from the environment; there is no crate model in the repository.
  ///
  /// A model only batches alongside [material], because a model wearing its
  /// own file's materials has a set of them per copy and cannot be made to
  /// share without changing what the other copies are made of.
  String? mesh;

  /// Whether the crate in the middle turns, to show a single member of a
  /// batch being moved on its own.
  bool moving = true;

  static const List<Color> _swatches = [
    Color(0xFFC8874E),
    Color(0xFF8E6B45),
    Color(0xFF5FA8D3),
    Color(0xFFD9634F),
    Color(0xFF7FA86A),
    Color(0xFFE8D9B0),
  ];

  static const int _materialKey = 7;

  Vector3 _colourOf(int index, int total) => switch (palette) {
    'One' => linearOf(_swatches.first),
    'Six' => linearOf(_swatches[index % _swatches.length]),
    // Every one different, which is the case batching cannot help: a lerp
    // across the whole set gives each crate a colour of its own.
    _ => linearOf(
      Color.lerp(_swatches[2], _swatches[3], index / math.max(total - 1, 1))!,
    ),
  };

  @override
  OrbisScene scene(OrbisCamera camera, double seconds) {
    final total = count.round();
    final side = math.sqrt(total).ceil();
    const spacing = 1.1;
    final half = (side - 1) * spacing / 2;

    return OrbisScene(
      batching: batching,
      materials: [
        if (material)
          OrbisMaterial(
            key: _materialKey,
            baseColour: Vector4(
              linearOf(_swatches.first).x,
              linearOf(_swatches.first).y,
              linearOf(_swatches.first).z,
              1,
            ),
            roughness: 0.7,
          ),
      ],
      objects: [
        for (var i = 0; i < total; i++)
          OrbisObject(
            key: 1000 + i,
            mesh: mesh,
            material: material ? _materialKey : null,
            transform: Matrix4.identity()
              ..setTranslation(
                Vector3(
                  (i % side) * spacing - half,
                  -2.2,
                  (i ~/ side) * spacing - half,
                ),
              )
              // The one in the middle turns. Batched or not, its transform is
              // the only one written each frame — the rest are compared and
              // left alone.
              ..rotateY(moving && i == total ~/ 2 ? seconds : (i % 4) * 0.2)
              ..scaleByDouble(0.4, 0.4, 0.4, 1),
            colour: _colourOf(i, total),
            // One in five casts, so the shadow pass has its own batches to
            // merge rather than every crate or none.
            castShadows: i % 5 == 0,
          ),
        OrbisObject(
          key: 1,
          transform: Matrix4.identity()
            ..setTranslation(Vector3(0, -2.7, 0))
            ..scaleByDouble(half + 3, 0.06, half + 3, 1),
          colour: linearOf(const Color(0xFF3A4048)),
          castShadows: false,
        ),
      ],
      lights: [
        OrbisLight(
          key: 2,
          kind: OrbisLightKind.directional,
          intensity: 78000,
          direction: Vector3(-0.4, -1, -0.3)..normalize(),
          colour: linearOf(const Color(0xFFFFF3E0)),
        ),
      ],
      sky: OrbisSky(colour: linearOf(const Color(0xFF1D242E)), ambient: 12000),
      camera: camera,
    );
  }

  @override
  Widget settings(BuildContext context, VoidCallback changed) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Toggle(
        label: 'Batching',
        value: batching,
        onChanged: (value) {
          batching = value;
          changed();
        },
      ),
      Setting(
        label: 'Crates',
        value: count,
        min: 100,
        max: 6000,
        decimals: 0,
        onChanged: (value) {
          count = value;
          changed();
        },
      ),
      Choice(
        label: 'Colours',
        options: const ['One', 'Six', 'Every one'],
        selected: palette,
        onSelect: (value) {
          palette = value;
          changed();
        },
      ),
      Toggle(
        label: 'Shared material',
        value: material,
        onChanged: (value) {
          material = value;
          changed();
        },
      ),
      Toggle(
        label: 'Moving',
        value: moving,
        onChanged: (value) {
          moving = value;
          changed();
        },
      ),
    ],
  );

  @override
  String get code => '''
// Nothing about the objects changes. Each crate is still its own object
// with its own key; the scene just says that batching is allowed.
OrbisScene(
  batching: true,
  objects: [
    for (var i = 0; i < 3000; i++)
      OrbisObject(
        key: 1000 + i,
        transform: placementOf(i),
        colour: crateColour,      // the same for all, or they cannot share
        castShadows: i % 5 == 0,  // casters batch with casters
      ),
  ],
  camera: camera,
)

// On the other side, objects with the same mesh, material, flags and — on
// the default surface — colour are counted as they arrive. Groups of four
// or more share one material instance, and Filament merges their draws into
// instanced ones. A transform written to one crate moves that one only.
''';
}
