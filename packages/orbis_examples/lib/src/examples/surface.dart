import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../example.dart';

/// The first thing the engine had to prove: a lit scene that is a widget.
///
/// Not a window on top of the application — a texture inside it, which lays
/// out, clips and scrolls like anything else. Everything in this gallery is
/// drawn into the panel beside these words, which is the point.
class SurfaceExample extends Example {
  SurfaceExample();

  @override
  String get name => 'A scene as a widget';

  @override
  String get blurb =>
      'A lit surface composited by Flutter, laid out like any other widget.';

  double spin = 0.35;
  int swatch = 0;

  static const _swatches = {
    'Clay': Color(0xFFD9634F),
    'Amber': Color(0xFFE5B84F),
    'Sky': Color(0xFF5FA8D3),
    'Moss': Color(0xFF6FBF73),
    'Bone': Color(0xFFE8E4DC),
  };

  Color get colour => _swatches.values.elementAt(swatch);

  @override
  OrbisScene scene(OrbisCamera camera, double seconds) {
    final turn = seconds * spin;

    return OrbisScene(
      objects: [
        OrbisObject(
          key: 1,
          transform: Matrix4.identity()
            ..rotateY(turn)
            ..rotateX(turn * 0.42),
          colour: _linear(colour),
        ),
        // A floor, so the light has somewhere to land and the shadow has
        // somewhere to fall.
        OrbisObject(
          key: 2,
          transform: Matrix4.identity()
            ..setTranslation(Vector3(0, -1.6, 0))
            ..scaleByDouble(6.0, 0.06, 6.0, 1),
          colour: _linear(const Color(0xFF3B424C)),
          castShadows: false,
        ),
      ],
      lights: [
        OrbisLight(
          key: 10,
          kind: OrbisLightKind.directional,
          intensity: 82000,
          colour: _linear(const Color(0xFFFFF3E0)),
          direction: Vector3(-0.4, -1, -0.55)..normalize(),
        ),
      ],
      sky: OrbisSky(colour: _linear(const Color(0xFF1B222C)), ambient: 9000),
      camera: camera,
    );
  }

  @override
  Widget settings(BuildContext context, VoidCallback changed) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Setting(
          label: 'Spin',
          value: spin,
          min: 0,
          max: 2,
          onChanged: (value) {
            spin = value;
            changed();
          },
        ),
        Choice(
          label: 'Colour',
          options: _swatches.keys.toList(),
          selected: _swatches.keys.elementAt(swatch),
          onSelect: (option) {
            swatch = _swatches.keys.toList().indexOf(option);
            changed();
          },
        ),
      ],
    );
  }

  @override
  String get code => '''
// A scene is a description, handed over whole every frame.
OrbisView(
  scene: OrbisScene(
    objects: [
      OrbisObject(
        key: 1,
        transform: Matrix4.identity()..rotateY(turn),
        colour: Vector3(0.72, 0.13, 0.08),   // linear RGB
      ),
    ],
    lights: [
      OrbisLight(
        key: 10,
        kind: OrbisLightKind.directional,
        intensity: 82000,                     // lux
        direction: Vector3(-0.4, -1, -0.55)..normalize(),
      ),
    ],
    sky: OrbisSky(colour: Vector3(0.01, 0.02, 0.03), ambient: 9000),
    camera: camera,
  ),
)

// The key is what makes saying it again cheap. Same key, same object: the
// renderer moves what moved instead of building the scene a second time.
''';
}

/// sRGB out of a swatch and into the linear the renderer works in.
Vector3 _linear(Color colour) {
  double channel(double value) => value <= 0.04045
      ? value / 12.92
      : math.pow((value + 0.055) / 1.055, 2.4).toDouble();
  return Vector3(channel(colour.r), channel(colour.g), channel(colour.b));
}

/// Shared by every example in here, so each one can be read on its own.
Vector3 linearOf(Color colour) => _linear(colour);
