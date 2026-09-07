import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../example.dart';
import 'surface.dart' show linearOf;

/// A hundred thousand of them, in four draw calls.
///
/// The object path in [ManyExample] is the right shape for a scene somebody is
/// arranging by hand: each thing has a key, is compared against what was there
/// last frame, and gets its own entity. Push that to six figures and every one
/// of those virtues becomes a cost — a hundred thousand comparisons, a hundred
/// thousand entities, a hundred thousand draw calls.
///
/// A population turns it around. One mesh, one buffer of transforms, and the
/// renderer submits it once per thirty-two thousand members, which is
/// Filament's own limit rather than ours.
///
/// The second half of it is the wire. Six megabytes of transforms is not
/// something to send sixty times a second in order to say nothing moved, so
/// the buffer is only sent when its revision changes. Leave Drifting off and
/// the scene costs nothing per member per frame at all: it is built once and
/// then only looked at. That is the difference between a world and a
/// slideshow, and it is the same trick every game that draws a forest uses.
class CrowdExample extends Example {
  CrowdExample();

  @override
  String get name => 'A hundred thousand';

  @override
  String get blurb =>
      'One buffer of transforms, sent once, drawn in a handful of calls.';

  @override
  ViewPoint get viewpoint =>
      const ViewPoint(distance: 190, pitch: 0.34, height: 6);

  // What is drawn, and what the sliders are showing.
  //
  // Two of each, because laying a hundred thousand members out takes fifty
  // milliseconds and a slider reports every pixel of a drag. Rebuilding on
  // each report is eighteen frames a second while dragging — so the drawn
  // numbers only catch up when the handle is let go.
  double count = 100000;
  double wantedCount = 100000;
  bool drifting = false;
  double spread = 700;
  double wantedSpread = 700;
  double range = 300;

  /// The buffers, kept rather than rebuilt.
  ///
  /// This is the point. Allocating a hundred thousand transforms every frame
  /// would cost more than drawing them, so they are written in place and the
  /// revision says when that has happened.
  Float32List _transforms = Float32List(0);
  Float32List _colours = Float32List(0);
  int _revision = 0;
  int _built = -1;
  double _builtSpread = -1;
  double _driftedTo = -1;

  @override
  OrbisScene scene(OrbisCamera camera, double seconds) {
    final total = count.round();

    if (_built != total || _builtSpread != spread) {
      _fill(total);
      _built = total;
      _builtSpread = spread;
      _revision++;
    }

    // Ten times a second rather than sixty, because the point being made is
    // that moving them is the expensive half and standing still is free.
    if (drifting) {
      final beat = (seconds * 10).floorToDouble();
      if (beat != _driftedTo) {
        _drift(total, seconds);
        _driftedTo = beat;
        _revision++;
      }
    }

    return OrbisScene(
      populations: [
        OrbisPopulation(
          key: 1,
          transforms: _transforms,
          colours: _colours,
          // One box around the lot. Every member is culled by it, so it has
          // to cover all of them.
          minimum: Vector3(-spread, -2, -spread),
          maximum: Vector3(spread, 14, spread),
          revision: _revision,
          // How far a member is still drawn from. The whole map stays
          // loaded — one buffer, uploaded once — and what is too far to see
          // costs a distance test rather than a draw.
          range: range,
          castShadows: false,
        ),
      ],
      objects: [
        OrbisObject(
          key: 900,
          transform: Matrix4.identity()
            ..setTranslation(Vector3(0, -2.4, 0))
            ..scaleByDouble(spread * 1.2, 0.06, spread * 1.2, 1),
          colour: linearOf(const Color(0xFF2E343C)),
          castShadows: false,
        ),
      ],
      lights: [
        OrbisLight(
          key: 910,
          kind: OrbisLightKind.directional,
          intensity: 82000,
          direction: Vector3(-0.4, -0.86, -0.32)..normalize(),
          colour: linearOf(const Color(0xFFFFF3E0)),
          sunAngularRadius: 0.6,
        ),
      ],
      // Air, so that the far end of the field goes into the distance rather
      // than stopping at a line. A range without it is honest but obvious:
      // the members sink, and what they sink into is a hard horizon.
      fog: OrbisFog(
        colour: linearOf(const Color(0xFFB9CBDD)),
        density: 0.0038,
        // Not right in front of the lens: the thing being looked at should be
        // seen, and only what is far away should be veiled.
        distance: 30,
        // All the way, so the far edge of the ground is not a line.
        maximumOpacity: 1,
      ),
      sky: OrbisSky(
        colour: linearOf(const Color(0xFF6E8DB4)),
        zenith: linearOf(const Color(0xFF2F5F97)),
        horizon: linearOf(const Color(0xFFB9CBDD)),
        ambient: 26000,
        bodyDirection: Vector3(0.4, 0.86, 0.32)..normalize(),
        bodyColour: linearOf(const Color(0xFFFFF6E8)),
        bodySize: 0.011,
        clouds: OrbisClouds.cumulus(cover: 0.3, wind: Vector2(4, 1.5)),
      ),
      camera: camera,
    );
  }

  /// Lays the crowd out. Called when the count or the spread changes, and not
  /// otherwise.
  void _fill(int total) {
    _transforms = Float32List(total * 16);
    _colours = Float32List(total * 3);

    final random = math.Random(7);
    for (var i = 0; i < total; i++) {
      final x = (random.nextDouble() * 2 - 1) * spread;
      final z = (random.nextDouble() * 2 - 1) * spread;
      final height = 0.6 + random.nextDouble() * 3.4;
      final width = 0.3 + random.nextDouble() * 0.5;

      _write(i, x, height * 0.5 - 2.2, z, width, height, random.nextDouble());

      // Something between grass and rust, so the field reads as a crowd of
      // different things rather than one thing repeated.
      final tone = random.nextDouble();
      final colour = linearOf(
        Color.lerp(const Color(0xFF6F8F55), const Color(0xFFB86B3C), tone)!,
      );
      _colours[i * 3 + 0] = colour.x;
      _colours[i * 3 + 1] = colour.y;
      _colours[i * 3 + 2] = colour.z;
    }
  }

  /// Sways the lot, in place.
  ///
  /// Writes into the buffer that is already there rather than making a new
  /// one. A hundred thousand new matrices a frame is the thing this whole
  /// arrangement exists to avoid.
  void _drift(int total, double seconds) {
    final random = math.Random(7);
    for (var i = 0; i < total; i++) {
      final x = (random.nextDouble() * 2 - 1) * spread;
      final z = (random.nextDouble() * 2 - 1) * spread;
      final height = 0.6 + random.nextDouble() * 3.4;
      final width = 0.3 + random.nextDouble() * 0.5;
      final phase = random.nextDouble();

      _write(
        i,
        x + math.sin(seconds * 0.9 + phase * 6.28) * 0.8,
        height * 0.5 - 2.2,
        z + math.cos(seconds * 0.7 + phase * 6.28) * 0.8,
        width,
        height,
        phase,
      );
    }
  }

  /// One member, written straight into the flat buffer.
  ///
  /// Column-major, which is what the renderer's matrices already are, so
  /// nothing on either side has to convert anything.
  void _write(
    int i,
    double x,
    double y,
    double z,
    double width,
    double height,
    double turn,
  ) {
    final at = i * 16;
    final angle = turn * math.pi * 2;
    final c = math.cos(angle) * width;
    final s = math.sin(angle) * width;

    _transforms[at + 0] = c;
    _transforms[at + 1] = 0;
    _transforms[at + 2] = -s;
    _transforms[at + 3] = 0;

    _transforms[at + 4] = 0;
    _transforms[at + 5] = height * 0.5;
    _transforms[at + 6] = 0;
    _transforms[at + 7] = 0;

    _transforms[at + 8] = s;
    _transforms[at + 9] = 0;
    _transforms[at + 10] = c;
    _transforms[at + 11] = 0;

    _transforms[at + 12] = x;
    _transforms[at + 13] = y;
    _transforms[at + 14] = z;
    _transforms[at + 15] = 1;
  }

  @override
  Widget settings(BuildContext context, VoidCallback changed) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Setting(
          label: 'Members',
          value: wantedCount,
          min: 1000,
          max: 100000,
          decimals: 0,
          onChanged: (value) {
            wantedCount = value;
            changed();
          },
          onSettled: (value) {
            count = value;
            changed();
          },
        ),
        Setting(
          label: 'Spread',
          value: wantedSpread,
          min: 40,
          max: 2000,
          decimals: 0,
          unit: ' m',
          onChanged: (value) {
            wantedSpread = value;
            changed();
          },
          onSettled: (value) {
            spread = value;
            changed();
          },
        ),
        Setting(
          label: 'View range',
          value: range,
          min: 0,
          max: 600,
          decimals: 0,
          unit: ' m',
          onChanged: (value) {
            range = value;
            changed();
          },
        ),
        Toggle(
          label: 'Drifting',
          value: drifting,
          onChanged: (value) {
            drifting = value;
            changed();
          },
        ),
      ],
    );
  }

  @override
  String get code => '''
// One mesh, one buffer of transforms, one submission.
//
// The buffer is written once and kept. `revision` is what tells the renderer
// whether it has to be sent again — leave it alone and a hundred thousand
// members cost nothing per frame at all.
final transforms = Float32List(count * 16);
final colours = Float32List(count * 3);

for (var i = 0; i < count; i++) {
  // Column-major, straight into the buffer. Nothing is allocated per member.
  transforms[i * 16 + 0] = width;
  transforms[i * 16 + 5] = height;
  transforms[i * 16 + 10] = width;
  transforms[i * 16 + 12] = x;
  transforms[i * 16 + 13] = y;
  transforms[i * 16 + 14] = z;
  transforms[i * 16 + 15] = 1;
}

OrbisScene(
  populations: [
    OrbisPopulation(
      key: 1,
      transforms: transforms,
      colours: colours,
      // Every member is culled by this one box, so it must cover all of them.
      minimum: Vector3(-spread, -2, -spread),
      maximum: Vector3(spread, 14, spread),
      // Bump this when you write into the buffers. Do not, and nothing is
      // sent.
      revision: revision,
    ),
  ],
  camera: camera,
);
''';
}
