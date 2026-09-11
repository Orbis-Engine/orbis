import 'package:flutter/material.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../example.dart';
import 'surface.dart' show linearOf;

/// Air that bends the light through it.
///
/// Three kinds at once, on a chequered floor because a grid is what shows a
/// bend: a straight line that stops being straight is the whole of the
/// effect. A shockwave runs out across the floor from one corner, heat rises
/// off a vent in the other, and the lens can warp the lot.
///
/// The pillar in front of the vent is the part worth looking at twice. The
/// haze is behind it, so its edges stay straight while the floor beyond them
/// shimmers — the distortion knows what is in front of it.
class DistortionExample extends Example {
  DistortionExample();

  @override
  String get name => 'Distortion';

  @override
  String get blurb =>
      'A shockwave across a chequered floor, heat rising off a vent, and a '
      'lens warping the lot.';

  @override
  ViewPoint get viewpoint =>
      const ViewPoint(yaw: 0, pitch: 0.55, distance: 13, height: 0);

  bool shockwave = true;
  bool haze = true;
  double strength = 0.03;
  double lens = 0;
  double chromatic = 0.3;

  /// Seconds between one wave and the next. Each is gone before the next
  /// begins, so there is always exactly one on the floor.
  static const double every = 2.5;

  static final Vector3 _blast = Vector3(-2.5, -1.5, 0.5);
  static final Vector3 _vent = Vector3(2.4, -1.5, -1.2);

  static const int _tiles = 1000;
  static const int _ventKey = 10;
  static const int _pillarKey = 11;

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
  OrbisScene scene(OrbisCamera camera, double seconds) => OrbisScene(
    objects: [
      // Sixteen by sixteen tiles of eighty centimetres.
      for (var i = 0; i < 256; i++)
        _box(
          _tiles + i,
          Vector3((i % 16 - 7.5) * 0.8, -1.6, (i ~/ 16 - 7.5) * 0.8),
          Vector3(0.4, 0.1, 0.4),
          (i % 16 + i ~/ 16).isEven
              ? const Color(0xFFE8E4DC)
              : const Color(0xFF26282C),
        ),
      _box(
        _ventKey,
        _vent + Vector3(0, 0.15, 0),
        Vector3(0.6, 0.15, 0.6),
        const Color(0xFF3A2A22),
      ),
      // In front of the haze, and not bent by it.
      _box(
        _pillarKey,
        _vent + Vector3(-0.2, 1.4, 1.6),
        Vector3(0.12, 1.4, 0.12),
        const Color(0xFFB8452E),
      ),
    ],
    lights: [
      OrbisLight(
        key: 1,
        kind: OrbisLightKind.directional,
        intensity: 90000,
        direction: Vector3(-0.4, -1, -0.3)..normalize(),
        colour: Vector3(1, 0.97, 0.92),
        castShadows: true,
      ),
    ],
    sky: OrbisSky(
      zenith: Vector3(0.30, 0.50, 0.78),
      horizon: Vector3(0.72, 0.84, 0.94),
      ambient: 24000,
    ),
    // A wave that has run its course and a lens at nought both have a
    // strength of nought, and a scene whose distortions are all at rest
    // draws no extra pass at all.
    distortions: [
      if (shockwave)
        OrbisDistortion.expanding(
          centre: _blast,
          age: seconds % every,
          speed: 3.5,
          lifetime: every,
          thickness: 0.8,
          strength: strength,
          chromatic: chromatic,
        ),
      if (haze)
        OrbisDistortion.haze(
          centre: _vent + Vector3(0, 1.6, 0),
          halfSize: Vector3(0.9, 1.6, 0.9),
          strength: 0.008,
          scale: 0.18,
          speed: 1.2,
          seconds: seconds,
        ),
      if (lens != 0) OrbisDistortion.lens(strength: lens, chromatic: chromatic),
    ],
    camera: camera,
  );

  @override
  Widget settings(BuildContext context, VoidCallback changed) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Toggle(
        label: 'Shockwave',
        value: shockwave,
        onChanged: (value) {
          shockwave = value;
          changed();
        },
      ),
      Toggle(
        label: 'Heat haze',
        value: haze,
        onChanged: (value) {
          haze = value;
          changed();
        },
      ),
      Setting(
        label: 'Wave strength',
        value: strength,
        min: 0,
        max: 0.08,
        onChanged: (value) {
          strength = value;
          changed();
        },
      ),
      Setting(
        label: 'Lens warp',
        value: lens,
        min: -0.3,
        max: 0.3,
        onChanged: (value) {
          lens = value;
          changed();
        },
      ),
      Setting(
        label: 'Chromatic split',
        value: chromatic,
        min: 0,
        max: 1,
        onChanged: (value) {
          chromatic = value;
          changed();
        },
      ),
    ],
  );

  @override
  String get code => '''
// Distortions are part of the scene, like its lights. The renderer sums
// them in one pass over the finished frame — and draws no pass at all
// when none of them is moving anything.
OrbisScene(
  distortions: [
    OrbisDistortion.expanding(
      centre: blast,
      age: seconds - wentOffAt,  // the host's clock
      speed: 3.5,
      chromatic: 0.3,
    ),
    OrbisDistortion.haze(
      centre: vent + Vector3(0, 1.6, 0),
      halfSize: Vector3(0.9, 1.6, 0.9),
      seconds: seconds,
    ),
    OrbisDistortion.lens(strength: 0.1),  // barrel; negative is pincushion
  ],
  ...
)
''';
}
