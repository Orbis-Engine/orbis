import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../example.dart';
import 'surface.dart' show linearOf;

/// A track that never ends, and the trick that makes it not end.
///
/// The genre is familiar; the thing worth showing is that nothing here is
/// ever created or destroyed while it runs. The world is a fixed number of
/// pieces — track sections, obstacles, coins, the scenery either side — and
/// when one falls behind the camera it is moved to the far end and given new
/// contents rather than replaced. A runner that allocated a section per
/// second would spend its life in the collector, and the frame it dropped
/// would be the one somebody was mid-jump in.
///
/// So the length of the world is decided once, and after that the only thing
/// that changes is where along it everything is. It is the same trick as the
/// crowd and the blocks — one buffer, written when it changes — pointed at
/// something that moves towards you.
class RunnerExample extends Example {
  RunnerExample() {
    _lay();
  }

  @override
  String get name => 'Runner';

  @override
  String get blurb =>
      'A track that never ends, and never allocates a piece of one.';

  @override
  ViewPoint get viewpoint =>
      // Behind and a little above, looking the way the track runs. The
      // gallery's camera sits at +z for a yaw of nought, and the track is
      // laid out towards -z — the first version had this the other way
      // round and looked at an empty sky with the whole world behind it.
      const ViewPoint(distance: 13, pitch: 0.24, height: 1.6, yaw: 0);

  /// How fast the world comes towards you, in metres a second.
  double pace = 13;

  /// Whether the runner moves between the lanes on its own.
  bool weaving = true;

  /// How far ahead the track is drawn.
  double ahead = 120;

  /// Three lanes, which is the number this kind of game has and is not an
  /// accident: two gives no middle to return to, four gives no obvious one.
  static const _lanes = [-2.6, 0.0, 2.6];
  static const _pieces = 90;
  static const _spacing = 4.4;

  int _revision = 0;
  Float32List _blocks = Float32List(0);
  Float32List _blockColours = Float32List(0);

  /// Where each obstacle sits along the track, and in which lane. Fixed at
  /// the start and reused for ever: what changes is the offset subtracted
  /// from it.
  final List<({double along, int lane, bool low})> _hazards = [];
  final List<({double along, int lane})> _coins = [];

  double _runnerLane = 0;
  double _runnerAt = 0;

  @override
  OrbisScene scene(OrbisCamera camera, double seconds) {
    // How far the world has come. Everything is placed relative to this, and
    // nothing is rebuilt because of it.
    final travelled = seconds * pace;
    final length = _pieces * _spacing;

    // The runner weaves between lanes on a slow rhythm, and the number is
    // eased rather than snapped: a character that teleports between lanes
    // reads as a bug even when it is the rule.
    if (weaving) {
      final wanted = _lanes[((seconds * 0.42).floor()) % _lanes.length];
      _runnerLane += (wanted - _runnerLane) * 0.06;
    }
    // And hops, on a rhythm that is not the same as the weaving one, so the
    // two never lock into a pattern.
    _runnerAt = math.max(0, math.sin(seconds * 2.9)) * 1.15;

    final objects = <OrbisObject>[
      // The runner, which stays where it is while the world moves past. That
      // is the other half of the trick: a character that actually travelled
      // would need a camera chasing it and a world stretching ahead of it.
      OrbisObject(
        key: 1,
        transform: Matrix4.identity()
          // Nearer the camera than the middle of the track, so it is a
          // character being followed rather than a speck at the far end.
          ..setTranslation(Vector3(_runnerLane, 1.0 + _runnerAt, 6.5))
          ..multiply(Matrix4.diagonal3(Vector3(0.5, 0.8, 0.5))),
        colour: Vector3(1, 1, 1),
        material: 1,
      ),
      // The track: one long slab, moved so its seams pass underneath.
      OrbisObject(
        key: 2,
        transform: Matrix4.identity()
          ..setTranslation(Vector3(0, -0.1, -length / 2 + 8))
          ..multiply(Matrix4.diagonal3(Vector3(4.6, 0.1, length / 2))),
        colour: Vector3(1, 1, 1),
        material: 2,
        castShadows: false,
      ),
    ];

    // The hazards and the coins, each moved by how far the world has come and
    // wrapped when they pass behind. `%` is doing the work a spawner would
    // otherwise do, without allocating anything.
    var key = 100;
    for (final hazard in _hazards) {
      final z = -((hazard.along - travelled) % length);
      if (-z > ahead) continue;
      objects.add(
        OrbisObject(
          key: key++,
          transform: Matrix4.identity()
            ..setTranslation(
              Vector3(_lanes[hazard.lane], hazard.low ? 0.45 : 1.7, z),
            )
            ..multiply(
              Matrix4.diagonal3(
                hazard.low ? Vector3(0.9, 0.45, 0.5) : Vector3(0.9, 0.14, 0.5),
              ),
            ),
          colour: Vector3(1, 1, 1),
          material: hazard.low ? 3 : 5,
        ),
      );
    }

    for (final coin in _coins) {
      final z = -((coin.along - travelled) % length);
      if (-z > ahead) continue;
      objects.add(
        OrbisObject(
          key: key++,
          transform: Matrix4.identity()
            ..setTranslation(Vector3(_lanes[coin.lane], 1.15, z))
            ..rotateY(seconds * 3.1)
            ..multiply(Matrix4.diagonal3(Vector3(0.34, 0.34, 0.06))),
          colour: Vector3(1, 1, 1),
          material: 4,
        ),
      );
    }

    return OrbisScene(
      camera: camera,
      objects: objects,
      populations: [
        // The scenery either side. Hundreds of blocks that never change and
        // never move — the world moves, so these are laid out once along the
        // whole length and simply keep coming round.
        OrbisPopulation(
          key: 1,
          transforms: _blocks,
          colours: _blockColours,
          minimum: Vector3(-40, -2, -length),
          maximum: Vector3(40, 20, length),
          revision: _revision,
          range: ahead + 20,
          castShadows: true,
        ),
      ],
      // The colour lives on the material rather than on the object.
      //
      // An object's colour is a tint over whatever its material already is,
      // and a material nobody gave a colour to is a bright neutral grey — so
      // tinting it produced a white track and black obstacles under a sun of
      // eighty-eight thousand lux, which is a correctly exposed picture of
      // the wrong thing.
      materials: [
        // The runner.
        OrbisMaterial(
          key: 1,
          baseColour: Vector4(0.72, 0.31, 0.08, 1),
          roughness: 0.45,
          emissive: Vector3(0.5, 0.18, 0.04),
          emissiveIntensity: 0.5,
        ),
        // The track: dark, so that everything standing on it reads.
        OrbisMaterial(
          key: 2,
          baseColour: Vector4(0.052, 0.058, 0.075, 1),
          roughness: 0.8,
        ),
        // What is jumped over.
        OrbisMaterial(
          key: 3,
          baseColour: Vector4(0.42, 0.10, 0.08, 1),
          roughness: 0.55,
        ),
        // What is ducked under.
        OrbisMaterial(
          key: 5,
          baseColour: Vector4(0.44, 0.30, 0.06, 1),
          roughness: 0.55,
        ),
        // The coins, which are the only thing here that gives off light —
        // it is what makes them read as a reward rather than as an obstacle.
        // Not metal, though a coin is. A metal reflects its surroundings and
        // nothing else, and the surroundings here are one directional light
        // and a painted sky — so a metallic coin came out black, which is
        // physically right and useless. Bright and glowing instead.
        OrbisMaterial(
          key: 4,
          baseColour: Vector4(0.86, 0.66, 0.16, 1),
          roughness: 0.3,
          metallic: 0.0,
          emissive: Vector3(1.0, 0.78, 0.28),
          emissiveIntensity: 1.4,
        ),
      ],
      lights: [
        OrbisLight(
          key: 1,
          kind: OrbisLightKind.directional,
          direction: Vector3(-0.4, -0.8, 0.45)..normalize(),
          colour: linearOf(const Color(0xFFFFEFD6)),
          intensity: 88000,
          castShadows: true,
        ),
      ],
      sky: OrbisSky(
        zenith: linearOf(const Color(0xFF2B3E63)),
        horizon: linearOf(const Color(0xFFCE7A54)),
        ambient: 17000,
      ),
      pipeline: OrbisPipeline(
        shadows: OrbisShadows(
          kind: OrbisShadowKind.soft,
          cascades: 2,
          mapSize: 1024,
          distance: 60,
        ),
        resolution: OrbisResolution(adaptive: true, minScale: 0.6),
      ),
      post: OrbisPostProcess(
        antiAliasing: AntiAliasing.temporal,
        bloom: OrbisBloom(enabled: true, strength: 0.16),
      ),
    );
  }

  @override
  Widget settings(BuildContext context, VoidCallback changed) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${_hazards.length} hazards and ${_coins.length} coins, laid out '
          'once. Nothing is made or thrown away while it runs.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Setting(
          label: 'Pace',
          value: pace,
          min: 0,
          max: 34,
          decimals: 0,
          unit: ' m/s',
          onChanged: (value) {
            pace = value;
            changed();
          },
        ),
        Setting(
          label: 'Seen ahead',
          value: ahead,
          min: 30,
          max: 200,
          decimals: 0,
          unit: ' m',
          onChanged: (value) {
            ahead = value;
            changed();
          },
        ),
        Toggle(
          label: 'Weaving',
          value: weaving,
          note: 'Between the three lanes, eased rather than snapped',
          onChanged: (value) {
            weaving = value;
            changed();
          },
        ),
      ],
    );
  }

  @override
  String get code => '''
// Nothing is created or destroyed while this runs. The track is a fixed
// number of pieces laid out once, and what changes is how far the world
// has come:
final travelled = seconds * pace;

// A piece that goes behind the camera comes round the front again. The
// modulo is doing the work a spawner would otherwise do — without
// allocating a thing.
final z = -((hazard.along - travelled) % length);

// And the runner does not run. It stays where it is and the world moves
// past, which is why there is no camera chasing anything and no world
// stretching out ahead.
''';

  // ---- the track, laid out once ----

  /// Places every hazard, coin and roadside block.
  ///
  /// Deterministic from a fixed seed, because a track that is different every
  /// time it is opened is one nobody can say anything about — including
  /// whether a change made it better.
  void _lay() {
    final chance = math.Random(19);
    final length = _pieces * _spacing;

    for (var i = 4; i < _pieces; i++) {
      final along = i * _spacing;
      // Not every piece has something on it, or there is no track left to
      // run along.
      if (chance.nextDouble() < 0.42) {
        _hazards.add((
          along: along,
          lane: chance.nextInt(_lanes.length),
          // Low ones are jumped and high ones are ducked under, which is the
          // whole vocabulary of the genre.
          low: chance.nextBool(),
        ));
      }
      if (chance.nextDouble() < 0.5) {
        _coins.add((along: along + _spacing / 2, lane: chance.nextInt(3)));
      }
    }

    // The scenery: blocks along both verges, at varying heights, so there is
    // something to judge the speed against. Without them the track reads as
    // still no matter how fast it is going.
    final transforms = <double>[];
    final colours = <double>[];
    for (var i = 0; i < _pieces * 3; i++) {
      final along = i / 3 * _spacing;
      for (final side in const [-1.0, 1.0]) {
        if (chance.nextDouble() < 0.35) continue;
        final out = 4.2 + chance.nextDouble() * 9;
        final tall = 0.6 + chance.nextDouble() * 5.5;
        transforms.addAll([
          0.9, 0, 0, 0, //
          0, tall, 0, 0, //
          0, 0, 0.9, 0, //
          side * out, tall - 0.2, -(along % length), 1, //
        ]);
        final shade = 0.5 + chance.nextDouble() * 0.4;
        colours.addAll([0.16 * shade, 0.19 * shade, 0.28 * shade]);
      }
    }

    _blocks = Float32List.fromList(transforms);
    _blockColours = Float32List.fromList(colours);
    _revision++;
  }
}
