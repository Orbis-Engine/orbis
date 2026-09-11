import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../example.dart';
import 'surface.dart' show linearOf;

/// A place made of soft blobs rather than of surfaces.
///
/// A Gaussian splat capture is millions of small coloured ellipsoids, fitted
/// to photographs until, seen from where the photographs were taken, they
/// add up to the place. Each is drawn as an ellipse the size its ellipsoid
/// projects to, fading out as a Gaussian, blended over whatever is behind it.
///
/// Nothing needs downloading here: the cloud is generated — a ring of flat,
/// half-transparent discs lying on the surface of a torus, striped so that
/// its near and far sides are different colours. That is deliberate. Where
/// the two sides overlap on screen, the order they are blended in decides
/// which colour wins, and turning the sort off shows exactly what a splat
/// renderer that does not sort gets wrong.
///
/// The pillar is solid geometry standing in the ring, to show the other rule:
/// splats test against the depth of the solid scene and never write their
/// own, so a wall hides a cloud and a cloud never hides a wall.
class SplatsExample extends Example {
  SplatsExample();

  @override
  String get name => 'Gaussian splats';

  @override
  String get blurb =>
      'A cloud of 3D Gaussians, drawn as ellipses and sorted back to front '
      'every time the camera turns.';

  @override
  ViewPoint get viewpoint =>
      const ViewPoint(yaw: 0.6, pitch: 0.35, distance: 6.5, height: 0.8);

  /// How many splats the generated ring has.
  int count = 300000;

  /// Whether they are sorted. Off is wrong on purpose, for comparison.
  bool sorted = true;

  /// Whether the solid pillar stands in the ring.
  bool pillar = true;

  double opacity = 1;
  double brightness = 1;

  /// A real capture to show instead, `.ply` or `.splat`.
  String? path;

  /// How many spherical-harmonic bands of a capture's colour to read.
  ///
  /// Only reaches a `.ply` from [path]. The generated ring is packed into the
  /// compact 32-byte records, which have no room for any, so it is the same
  /// colour from every side however this is set.
  int harmonics = 2;

  Uint8List? _data;
  int _builtFor = -1;
  int _revision = 0;

  static const _counts = {'100k': 100000, '300k': 300000, '1M': 1000000};

  @override
  OrbisScene scene(OrbisCamera camera, double seconds) {
    final file = path;
    if (file == null && _builtFor != count) {
      _data = ring(count);
      _builtFor = count;
      _revision++;
    }

    return OrbisScene(
      objects: [
        OrbisObject(
          key: 1,
          transform: Matrix4.identity()
            ..setTranslation(Vector3(0, -0.5, 0))
            ..scaleByDouble(7, 0.1, 7, 1),
          colour: linearOf(const Color(0xFF3A3F4A)),
        ),
        if (pillar)
          OrbisObject(
            key: 2,
            transform: Matrix4.identity()
              ..setTranslation(Vector3(0.9, 0.7, 1.2))
              ..scaleByDouble(0.3, 2.4, 0.3, 1),
            colour: linearOf(const Color(0xFFE8E4DA)),
          ),
      ],
      splats: [
        OrbisSplats(
          key: 1,
          path: file,
          data: file == null ? _data : null,
          // A capture comes out of structure-from-motion with y pointing
          // down, as the first photograph's camera had it, so one read from a
          // file is turned the right way up.
          transform: file == null ? null : Matrix4.rotationX(math.pi),
          opacity: opacity,
          brightness: brightness,
          sorted: sorted,
          harmonics: harmonics,
          revision: _revision,
        ),
      ],
      lights: [
        OrbisLight(
          key: 1,
          kind: OrbisLightKind.directional,
          direction: Vector3(-0.4, -0.8, -0.45)..normalize(),
          intensity: 60000,
          colour: Vector3(1, 0.97, 0.92),
        ),
      ],
      sky: OrbisSky(colour: linearOf(const Color(0xFF12151B)), ambient: 9000),
      // Straight through rather than filmic. A capture's colours are the
      // photographs' own, already graded by whatever camera took them, and a
      // second tone curve over them only greys them out.
      post: OrbisPostProcess(
        grading: OrbisGrading(toneMapping: ToneMapping.linear),
      ),
      camera: camera,
    );
  }

  /// A ring of [count] flat discs on a torus, as compact splat records.
  ///
  /// Discs rather than balls, oriented along the surface, which is what a
  /// trained capture's splats mostly are: flattened onto whatever surface they
  /// were fitted to. Half transparent, so both sides of the ring show where
  /// they overlap, and generated in order round the ring, so that drawing
  /// them unsorted is visibly wrong rather than accidentally right.
  static Uint8List ring(int count, {int seed = 7}) {
    final random = math.Random(seed);
    final positions = Float32List(count * 3);
    final scales = Float32List(count * 3);
    final colours = Float32List(count * 4);
    final rotations = Float32List(count * 4);

    const major = 1.6;
    const minor = 0.55;
    // Tilted, so the camera sees into the ring and across it at once.
    const tilt = 0.5;
    final ct = math.cos(tilt), st = math.sin(tilt);

    for (var i = 0; i < count; i++) {
      // In order round the ring, jittered.
      final u = (i + random.nextDouble()) / count * 2 * math.pi;
      final v = random.nextDouble() * 2 * math.pi;
      final cu = math.cos(u), su = math.sin(u);
      final cv = math.cos(v), sv = math.sin(v);

      // Position and frame on an untilted torus lying in the xz plane.
      final ring = major + minor * cv;
      var p = Vector3(ring * cu, minor * sv, ring * su);
      var along = Vector3(-su, 0, cu); // round the ring
      var around = Vector3(-sv * cu, cv, -sv * su); // round the tube
      var normal = Vector3(cv * cu, sv, cv * su);

      // Tilted about x, and lifted off the floor.
      Vector3 tilted(Vector3 a) =>
          Vector3(a.x, a.y * ct - a.z * st, a.y * st + a.z * ct);
      p = tilted(p)..y += 1.0;
      along = tilted(along);
      around = tilted(around);
      normal = tilted(normal);

      positions[i * 3] = p.x;
      positions[i * 3 + 1] = p.y;
      positions[i * 3 + 2] = p.z;

      // A few centimetres across and a few millimetres thick.
      final size = 0.018 + random.nextDouble() * 0.02;
      scales[i * 3] = size;
      scales[i * 3 + 1] = size * (0.6 + random.nextDouble() * 0.4);
      scales[i * 3 + 2] = 0.003;

      final q = Quaternion.fromRotation(Matrix3.columns(along, around, normal));
      rotations[i * 4] = q.w;
      rotations[i * 4 + 1] = q.x;
      rotations[i * 4 + 2] = q.y;
      rotations[i * 4 + 3] = q.z;

      // Stripes round the ring and bands round the tube, in two colours
      // that are easy to tell apart when one is seen through the other.
      final stripe = math.sin(u * 9) * math.sin(v * 2 + 0.4) > 0;
      final shade = 0.85 + random.nextDouble() * 0.15;
      final light = 0.6 + 0.4 * (0.5 + 0.5 * sv);
      colours[i * 4] = (stripe ? 0.95 : 0.12) * shade * light;
      colours[i * 4 + 1] = (stripe ? 0.55 : 0.70) * shade * light;
      colours[i * 4 + 2] = (stripe ? 0.18 : 0.85) * shade * light;
      colours[i * 4 + 3] = 0.55;
    }

    return OrbisSplats.pack(
      positions: positions,
      scales: scales,
      colours: colours,
      rotations: rotations,
    );
  }

  @override
  Widget settings(BuildContext context, VoidCallback changed) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Toggle(
        label: 'Sort back to front',
        value: sorted,
        note: sorted
            ? 'Re-sorted on its own thread whenever the view turns.'
            : 'Drawn in the order generated: the far side paints over the '
                  'near one wherever they overlap.',
        onChanged: (value) {
          sorted = value;
          changed();
        },
      ),
      Toggle(
        label: 'Solid pillar',
        value: pillar,
        onChanged: (value) {
          pillar = value;
          changed();
        },
      ),
      Choice(
        label: 'Splats',
        options: _counts.keys.toList(),
        selected: _counts.entries
            .firstWhere(
              (entry) => entry.value == count,
              orElse: () => _counts.entries.elementAt(1),
            )
            .key,
        onSelect: path != null
            ? null
            : (option) {
                count = _counts[option]!;
                changed();
              },
      ),
      Choice(
        label: 'Harmonics',
        options: const ['0', '1', '2', '3'],
        selected: '$harmonics',
        // Greyed out with no capture loaded, because there is nothing for it
        // to act on: the generated ring is packed into the compact records,
        // which carry a splat's colour and no bands at all.
        onSelect: path == null
            ? null
            : (option) {
                harmonics = int.parse(option);
                changed();
              },
      ),
      Setting(
        label: 'Opacity',
        value: opacity,
        min: 0,
        max: 1,
        onChanged: (value) {
          opacity = value;
          changed();
        },
      ),
      Setting(
        label: 'Brightness',
        value: brightness,
        min: 0,
        max: 2,
        onChanged: (value) {
          brightness = value;
          changed();
        },
      ),
    ],
  );

  @override
  String get code => '''
// A capture from a file: the reference trainer's .ply, or a compact .splat.
OrbisSplats(
  key: 1,
  path: 'garden.ply',
  // Structure-from-motion puts y down. Turned the right way up here.
  transform: Matrix4.rotationX(math.pi),
  // How much of the capture's view-dependent colour to read: the degree of
  // its spherical harmonics. Two is what most captures are trained to, and
  // costs 32 bytes a splat; 0 draws the flat colour alone and costs nothing.
  harmonics: 2,
)

// Or a cloud made in Dart, packed into the same 32-byte layout.
final data = OrbisSplats.pack(
  positions: positions, // three floats a splat, metres
  scales: scales,       // three standard deviations a splat, metres
  colours: colours,     // RGBA, nought to one; alpha is peak opacity
  rotations: rotations, // quaternions, (w, x, y, z)
);
OrbisSplats(key: 1, data: data, revision: revision)

// Sorted back to front on a thread of the renderer's own, whenever the view
// has turned a third of a degree. Drawn after the solid scene, tested against
// its depth, never writing any.
''';
}
