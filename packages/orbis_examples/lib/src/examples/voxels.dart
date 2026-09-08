import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:orbis_noise/orbis_noise.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../example.dart';
import 'surface.dart' show linearOf;

/// A world made of blocks, generated and walked over.
///
/// The genre this belongs to is well enough known that the interesting part
/// is not what it looks like but what it costs. A landscape of cubes is the
/// worst case for a renderer that draws things one at a time — sixty thousand
/// of them here — and the whole point is that it is not drawn one at a time:
/// it is one buffer of transforms, uploaded when the world changes and not
/// again, and the renderer decides what is near enough to be worth drawing.
///
/// What makes it a world rather than a heap is the same thing that makes any
/// of them one: the height at a point is a function of the point, so it is
/// continuous, and it is the same every time from the same seed. The blocks
/// underneath a surface block are not built, because nothing can see them —
/// which is the first optimisation anybody makes here and the reason a
/// landscape this size fits in a buffer at all.
class VoxelExample extends Example {
  VoxelExample() {
    _build();
  }

  @override
  String get name => 'Blocks';

  @override
  String get blurb =>
      'A landscape of sixty thousand cubes, generated and sent once.';

  @override
  ViewPoint get viewpoint =>
      const ViewPoint(distance: 88, pitch: 0.62, height: 5, yaw: 0.7);

  /// How far the world reaches, in blocks from the middle.
  double reach = 56;

  /// How high the hills go.
  double relief = 14;

  /// How far a block is still drawn from. Everything is in the buffer either
  /// way; this decides how much of it is looked at.
  double range = 140;

  /// Whether the water is there.
  bool sea = true;

  int _seed = 7;
  int _revision = 0;
  Float32List _transforms = Float32List(0);
  Float32List _colours = Float32List(0);
  int _blocks = 0;

  /// Where the water sits, as a share of the height.
  ///
  /// A fraction rather than a number of blocks: a fixed level in a world
  /// whose relief can be doubled is a world that becomes entirely dry the
  /// moment somebody drags the slider.
  int get _seaLevel => (relief * 0.28).round();

  @override
  OrbisScene scene(OrbisCamera camera, double seconds) {
    final far = reach + 8;

    return OrbisScene(
      camera: camera,
      populations: [
        OrbisPopulation(
          key: 1,
          transforms: _transforms,
          colours: _colours,
          // One box around the lot, because every member is culled by it.
          minimum: Vector3(-far, -2, -far),
          maximum: Vector3(far, relief + 4, far),
          // Bumped when the world is rebuilt, and only then. The renderer
          // keeps the buffer between frames and re-uploads sixty thousand
          // transforms when this changes, which is why it must not change
          // for a camera move.
          revision: _revision,
          range: range,
          castShadows: true,
        ),
      ],
      objects: const [],
      lights: [
        OrbisLight(
          key: 1,
          kind: OrbisLightKind.directional,
          // Across rather than down. A sun overhead lights every cube's top
          // and nothing else, and a world of cubes lit only on top has no
          // shape at all — the shadows are what turn a heightfield into
          // hills.
          direction: Vector3(-0.55, -0.62, -0.35)..normalize(),
          colour: linearOf(const Color(0xFFFFF0D8)),
          intensity: 92000,
          castShadows: true,
        ),
      ],
      sky: OrbisSky(
        zenith: linearOf(const Color(0xFF4E86C4)),
        horizon: linearOf(const Color(0xFFC5DAEC)),
        ambient: 22000,
      ),
      pipeline: OrbisPipeline(
        // The blocks are big and their edges are all axis-aligned, so a
        // thousand-square cascade is plenty — this is not a scene that needs
        // to resolve the shadow of a railing.
        shadows: OrbisShadows(
          kind: OrbisShadowKind.soft,
          cascades: 3,
          mapSize: 1024,
          distance: 160,
        ),
        resolution: OrbisResolution(adaptive: true, minScale: 0.6),
      ),
      post: OrbisPostProcess(
        antiAliasing: AntiAliasing.temporal,
        occlusion: OrbisOcclusion(enabled: true, quality: 1, radius: 1.2),
      ),
    );
  }

  @override
  Widget settings(BuildContext context, VoidCallback changed) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '$_blocks blocks, one buffer.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Setting(
          label: 'Reach',
          value: reach,
          min: 16,
          max: 80,
          decimals: 0,
          // On the way up rather than on every pixel of the drag: this
          // rebuilds the world, and a slider that rebuilds sixty thousand
          // blocks per pixel is a slider nobody can drag.
          onChanged: (value) => reach = value,
          onSettled: (value) {
            reach = value;
            _build();
            changed();
          },
        ),
        Setting(
          label: 'Relief',
          value: relief,
          min: 2,
          max: 26,
          decimals: 0,
          onChanged: (value) => relief = value,
          onSettled: (value) {
            relief = value;
            _build();
            changed();
          },
        ),
        Setting(
          label: 'Drawn to',
          value: range,
          min: 20,
          max: 240,
          decimals: 0,
          onChanged: (value) {
            range = value;
            changed();
          },
        ),
        Toggle(
          label: 'Sea',
          value: sea,
          note: 'Everything below $_seaLevel is under it',
          onChanged: (value) {
            sea = value;
            changed();
          },
        ),
        const SizedBox(height: 4),
        Choice(
          label: 'World',
          options: const ['1', '2', '3', '4'],
          selected: '$_seed',
          onSelect: (option) {
            _seed = int.parse(option);
            _build();
            changed();
          },
        ),
      ],
    );
  }

  @override
  String get code => '''
// Sixty thousand cubes are not sixty thousand draws. One buffer of
// transforms and one of colours, uploaded when `revision` changes and
// left alone otherwise — a camera move is not a change.
OrbisPopulation(
  key: 1,
  transforms: transforms,   // sixteen floats each
  colours: colours,         // three floats each
  minimum: Vector3(-far, -2, -far),
  maximum: Vector3(far, relief + 4, far),
  revision: revision,
  range: 140,               // how far one is still worth drawing
  castShadows: true,
)

// The world itself is a function of position, which is what makes it
// continuous and what makes it the same every time.
final height = (noise.at(x * 0.045, z * 0.045) * relief).round();

// And only the block somebody can see is built. The ones underneath
// are the difference between sixty thousand and half a million.
''';

  // ---- the world ----

  /// Builds the landscape.
  ///
  /// Surface blocks only. A column of height twelve is one cube, not twelve:
  /// nothing can see the eleven underneath it, and building them is the
  /// difference between sixty thousand blocks and half a million. The sides
  /// of a cliff are the exception — a column beside a much lower one has its
  /// face showing — so a column fills down as far as its lowest neighbour.
  void _build() {
    // Two octaves of gradient noise: one for the hills and one for the lumps
    // on them. More than that is finer than one block and cannot be seen.
    // Four octaves rather than two. With two, the field is smooth enough
    // that rounding it to whole blocks produces wide flat terraces and the
    // world reads as a contour map — the detail is what makes a hillside a
    // hillside instead of a set of steps drawn round it.
    final noise = FractalNoise(
      GradientNoise(seed: _seed),
      octaves: 2,
      gain: 0.45,
    );
    final side = reach.round();
    final transforms = <double>[];
    final colours = <double>[];

    int heightAt(int x, int z) {
      // Noise comes back around zero either side; the world wants nought to
      // one, because a height below the ground is not a height.
      final shaped = (noise.at(x * 0.03, z * 0.03) * 0.5 + 0.5).clamp(0.0, 1.0);
      return (shaped * relief).round();
    }

    for (var x = -side; x <= side; x++) {
      for (var z = -side; z <= side; z++) {
        final top = heightAt(x, z);

        // Down to the lowest neighbour, so a cliff face is a wall rather than
        // a row of floating tops with the world showing through it.
        var lowest = top;
        for (final (dx, dz) in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
          final beside = heightAt(x + dx, z + dz);
          if (beside < lowest) lowest = beside;
        }
        // And never below the sea floor, or the water has holes under it.
        final from = math.max(math.min(lowest, _seaLevel - 1), 0);

        for (var y = from; y <= top; y++) {
          transforms.addAll(_placed(x.toDouble(), y.toDouble(), z.toDouble()));
          colours.addAll(_colourOf(y, top, noise));
        }

        // Water is blocks too, filling each hollow up to the level.
        //
        // A single transparent slab across the world was the obvious way and
        // it was wrong: a transparent surface is drawn after the solid ones
        // and painted straight over them, so the whole landscape disappeared
        // under a flat sheet whatever its height. Blocks go in the same
        // buffer as the ground, are drawn with it, and cannot get in front
        // of a hill they are behind.
        if (sea) {
          for (var y = top + 1; y <= _seaLevel; y++) {
            transforms.addAll(
              _placed(x.toDouble(), y.toDouble(), z.toDouble()),
            );
            // Deeper water is darker, which is most of what makes a flat
            // blue area read as depth rather than as paint.
            final deep = ((_seaLevel - y) / math.max(_seaLevel, 1)).clamp(
              0.0,
              1.0,
            );
            colours.addAll([
              0.10 - deep * 0.05,
              0.30 - deep * 0.14,
              0.44 - deep * 0.18,
            ]);
          }
        }
      }
    }

    _transforms = Float32List.fromList(transforms);
    _colours = Float32List.fromList(colours);
    _blocks = colours.length ~/ 3;
    _revision++;
  }

  /// One cube's transform, in the sixteen floats the population wants.
  ///
  /// Written out rather than built through Matrix4 and copied: this runs
  /// sixty thousand times and the matrix is known — a translation and a
  /// uniform half-scale, so the cube is one unit across rather than two.
  List<double> _placed(double x, double y, double z) => [
    0.5, 0, 0, 0, //
    0, 0.5, 0, 0, //
    0, 0, 0.5, 0, //
    x, y, z, 1, //
  ];

  /// What a block is made of, from where it sits.
  ///
  /// By height rather than by a stored material, because the point of the
  /// buffer is that a block is sixteen floats and three, and a world that
  /// also carried a type per block would be carrying something it can work
  /// out.
  List<double> _colourOf(int y, int top, Noise noise) {
    final buried = y < top;
    if (buried) return _rock;
    // Banded by where the top of this column is rather than by where this
    // block is, so a beach is a beach all the way up its little rise instead
    // of a stripe drawn across the hillside at the water's height.
    if (top <= _seaLevel + 1) return _sand;
    if (top > relief * 0.82) return _snow;
    if (top > relief * 0.58) return _stone;
    // A little variation between neighbours, or a hillside is one flat green.
    final shade = 0.88 + noise.at(y * 3.1, top * 1.7).abs() * 0.24;
    return [0.24 * shade, 0.47 * shade, 0.19 * shade];
  }

  static const _rock = [0.31, 0.29, 0.27];
  static const _sand = [0.76, 0.69, 0.48];
  static const _stone = [0.44, 0.43, 0.41];
  static const _snow = [0.92, 0.94, 0.97];
}
