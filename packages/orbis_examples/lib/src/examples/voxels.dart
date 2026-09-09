import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
/// of them one: everything about a point is a function of that point, so it is
/// continuous, and it is the same every time from the same seed.
///
/// The generator's shape — climate fields rather than a height field, splines
/// from continentalness, surface rules by biome, features planted afterwards —
/// is the approach Pebble takes (github.com/thebriangao/pebble, MIT), read as
/// a reference and written again here. None of its code is in this file: it is
/// forty-five thousand lines of Swift against a different renderer, and what
/// was worth having from it was the shape rather than the source.
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
      const ViewPoint(distance: 96, pitch: 0.6, height: 8, yaw: 0.7);

  /// How far the world reaches, in blocks from the middle.
  double reach = 56;

  /// How high the hills go.
  double relief = 14;

  /// How far a block is still drawn from. Everything is in the buffer either
  /// way; this decides how much of it is looked at.
  double range = 140;

  /// Whether the water is there.
  bool sea = true;

  /// Whether anything grows.
  bool trees = true;

  /// Whether you are in the world or looking at it.
  bool walking = true;

  int _seed = 7;
  int _revision = 0;
  Float32List _transforms = Float32List(0);
  Float32List _colours = Float32List(0);
  int _blockCount = 0;

  /// Where the eyes are, which way they face, and how fast the body is
  /// falling. Head height is a metre and sixty-two, which is a person.
  Vector3 _eye = Vector3(0.5, 20, 0.5);
  double _yaw = 0.7;
  double _pitch = -0.15;
  double _fall = 0;
  double _wasAt = 0;

  /// The keys held down. A set rather than a callback per key, because
  /// walking diagonally is two keys at once and an event tells you about one.
  final Set<LogicalKeyboardKey> _pressed = {};

  /// Where the water sits, as a share of the height.
  ///
  /// A fraction rather than a number of blocks: a fixed level in a world
  /// whose relief can be doubled is a world that becomes entirely dry the
  /// moment somebody drags the slider.
  int get _seaLevel => (relief * 0.28).round();

  @override
  OrbisScene scene(OrbisCamera camera, double seconds) {
    final far = reach + 8;

    // The example takes the camera over when somebody is walking. The
    // gallery's camera orbits a point, which is the right thing for looking
    // at a scene and the wrong thing for being inside one.
    if (walking) {
      // Whatever has passed since the last frame, capped. A tab left in the
      // background comes back with a gap of several seconds in it, and a
      // player who falls through the world for all of it is a player who was
      // not there to see it.
      final dt = (seconds - _wasAt).clamp(0.0, 0.05);
      _wasAt = seconds;
      _step(dt);

      camera = OrbisCamera(
        position: _eye.clone(),
        target:
            _eye +
            Vector3(
              math.sin(_yaw) * math.cos(_pitch),
              math.sin(_pitch),
              math.cos(_yaw) * math.cos(_pitch),
            ),
        fieldOfView: 68,
      );
    } else {
      _wasAt = seconds;
    }

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
          '$_blockCount blocks drawn, one buffer.',
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
          label: 'Walk',
          value: walking,
          note: walking
              ? 'WASD, space, drag to look, click to dig'
              : 'Drag to orbit the world instead',
          onChanged: (value) {
            walking = value;
            if (value) _standOnGround();
            changed();
          },
        ),
        Toggle(
          label: 'Trees',
          value: trees,
          note: 'Where it is warm enough and damp enough for them',
          onChanged: (value) {
            trees = value;
            _build();
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
  Widget? overlay(BuildContext context, VoidCallback changed) {
    if (!walking) return null;

    // Over the scene rather than beside it, because the keys have to reach
    // the thing being looked at and a panel that steals focus is a player who
    // presses W and watches a slider.
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          _pressed.add(event.logicalKey);
        } else if (event is KeyUpEvent) {
          _pressed.remove(event.logicalKey);
        }
        // Held, not handled: the world reads the set every frame, so an
        // event's job is only to say what changed.
        return KeyEventResult.handled;
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.precise,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (details) {
            _yaw -= details.delta.dx * 0.005;
            // Short of straight up and straight down, where the view matrix
            // collapses and the picture turns over.
            _pitch = (_pitch - details.delta.dy * 0.005).clamp(-1.5, 1.5);
          },
          onTap: () {
            dig();
            changed();
          },
          onSecondaryTap: () {
            place();
            changed();
          },
          child: Stack(
            children: [
              const Positioned.fill(child: SizedBox.expand()),
              // A crosshair, because digging is aiming and nothing else on
              // screen says where the middle is.
              const Center(
                child: SizedBox(
                  width: 15,
                  height: 15,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border(
                        left: BorderSide(color: Color(0x99FFFFFF), width: 1.5),
                        top: BorderSide(color: Color(0x99FFFFFF), width: 1.5),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 12,
                bottom: 12,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xAA0E1116),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    child: Text(
                      'WASD to walk · space to jump · drag to look\n'
                      'click to dig · right-click to put one back',
                      style: TextStyle(fontSize: 11.5, height: 1.5),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  String get code => '''
// The world is a grid of bytes, not a list of what to draw. The moment
// somebody can dig, "what is at this point" is asked constantly — by the
// body falling, by every step, by every ray under the crosshair — and a
// grid answers it in one lookup instead of sixty thousand.
Uint8List blocks;  // side * side * tall, nought is air

// Only what can be seen is drawn. A block with six solid neighbours is
// invisible from everywhere, and in a world of hills that is most of them.
if (!buriedOnAllSides) {
  transforms.addAll(placed(x, y, z));
  colours.addAll(colourOf(kind));
}

// Moved one axis at a time, which is the whole reason it works: move in
// one step and test afterwards and you are inside a wall with no way to
// know which way to come back out. One at a time, a corner stops you
// sideways and lets you keep walking forwards — which is what sliding
// along a wall is.
for (final step in [(dx, 0.0), (0.0, dz)]) { ... }

// And digging is a ray walked a fraction of a block at a time. A proper
// grid traversal is faster; this is called once per click, on a ray six
// blocks long, and being obviously correct is worth more here.
''';

  // ---- the world ----

  /// Every block, as one byte each.
  ///
  /// A grid rather than a list of what to draw, because the moment somebody
  /// can dig, "what is at this point" becomes a question asked constantly —
  /// by the camera falling, by a step forward, by every ray looking for what
  /// is under the crosshair. A list answers it in sixty thousand comparisons
  /// and a grid answers it in one.
  ///
  /// Nought is air; anything else is the kind of block, which is also what
  /// decides its colour.
  Uint8List _blocks = Uint8List(0);
  int _side = 0;
  int _tall = 0;

  static const _air = 0;
  static const _grass = 1;
  static const _dirt = 2;
  static const _stone = 3;
  static const _deepslate = 4;
  static const _sand = 5;
  static const _sandstone = 6;
  static const _snow = 7;
  static const _water = 8;
  static const _log = 9;
  static const _leaves = 10;

  int _at(int x, int y, int z) {
    if (x < 0 || z < 0 || y < 0) return _air;
    if (x >= _side || z >= _side || y >= _tall) return _air;
    return _blocks[(y * _side + z) * _side + x];
  }

  void _put(int x, int y, int z, int kind) {
    if (x < 0 || z < 0 || y < 0) return;
    if (x >= _side || z >= _side || y >= _tall) return;
    _blocks[(y * _side + z) * _side + x] = kind;
  }

  /// Whether something standing here would be inside a block.
  ///
  /// Water is not solid, which is the whole of this example's physics: you
  /// can walk into a lake and you cannot walk into a hill.
  bool _solidAt(double x, double y, double z) {
    final kind = _at(
      (x + _side / 2).floor(),
      y.floor(),
      (z + _side / 2).floor(),
    );
    return kind != _air && kind != _water;
  }

  /// Generates the world.
  ///
  /// The shape of this is borrowed from how the genre does it, which is worth
  /// saying plainly: a height that comes from one noise field gives rolling
  /// dunes and nothing else, and the thing that makes a block world read as a
  /// *place* is that different parts of it are different — a beach, a desert,
  /// a snow line, trees where trees grow.
  ///
  /// So there are four fields rather than one, and none of them is height:
  ///
  ///   * **continentalness** decides how far above the sea a region sits, and
  ///     is the one that makes coasts;
  ///   * **erosion** decides how much the land is allowed to vary there, which
  ///     is what separates a plain from a mountain range rather than making
  ///     the mountains taller;
  ///   * **temperature** and **humidity** decide what grows, not what shape it
  ///     is.
  ///
  /// Height is then continentalness put through a curve and scaled by erosion.
  /// The curve matters: a straight line gives a world with as much land at
  /// every altitude, and a real one has a lot of coast, a lot of gentle
  /// ground, and a little that is high.
  void _build() {
    // Different offsets rather than different seeds, so one number still
    // decides the whole world and the fields stay independent of each other.
    final land = FractalNoise(GradientNoise(seed: _seed), octaves: 3);
    final erosion = FractalNoise(GradientNoise(seed: _seed + 101), octaves: 2);
    final warmth = FractalNoise(GradientNoise(seed: _seed + 202), octaves: 2);
    final damp = FractalNoise(GradientNoise(seed: _seed + 303), octaves: 2);
    final rough = FractalNoise(GradientNoise(seed: _seed + 404), octaves: 3);

    _side = reach.round() * 2 + 1;
    _tall = relief.round() + 8;
    _blocks = Uint8List(_side * _side * _tall);

    final half = _side ~/ 2;
    final sea = _seaLevel;

    // Every field runs to about half either side of zero rather than to one,
    // measured rather than assumed — so each is opened out before it is used.
    double field(Noise n, int x, int z, double scale) =>
        (n.at(x * scale, z * scale) * 1.9).clamp(-1.0, 1.0);

    int heightAt(int x, int z) {
      final c = field(land, x, z, 0.021);
      final e = field(erosion, x, z, 0.045);

      // The curve. Flat around the coast so beaches are wide, steepening
      // through the middle so there is somewhere to walk up, and easing off
      // at the top so peaks are rare rather than a plateau.
      final shaped = c < -0.3
          ? (c + 1) / 0.7 * 0.28
          : c < 0.35
          ? 0.28 + (c + 0.3) / 0.65 * 0.42
          : 0.70 + (c - 0.35) / 0.65 * 0.30;

      // Erosion scales how far from the sea the land is allowed to get, which
      // is what makes a range of hills rather than a taller everything.
      final vary = 0.35 + (1 - (e + 1) / 2) * 0.65;
      final above = (shaped - 0.30) * relief * 1.5 * vary;

      // And a little roughness on top, so a hillside is not a smooth ramp.
      final bumps = field(rough, x, z, 0.14) * 1.6;
      return (sea + above + bumps).round().clamp(1, _tall - 3);
    }

    for (var x = 0; x < _side; x++) {
      for (var z = 0; z < _side; z++) {
        final wx = x - half;
        final wz = z - half;
        final top = heightAt(wx, wz);

        final t = field(warmth, wx, wz, 0.017);
        final h = field(damp, wx, wz, 0.019);

        // Down to the lowest neighbour rather than only the surface, so a
        // cliff is a wall instead of a row of floating tops — and so digging
        // into one finds rock rather than the sky.
        var lowest = top;
        for (final (dx, dz) in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
          final beside = heightAt(wx + dx, wz + dz);
          if (beside < lowest) lowest = beside;
        }
        final from = math.max(math.min(lowest, sea - 1), 0);

        for (var y = from; y <= top; y++) {
          _put(x, y, z, _surfaceAt(y, top, t, h));
        }
        if (this.sea) {
          for (var y = top + 1; y <= sea; y++) {
            _put(x, y, z, _water);
          }
        }
      }
    }

    if (trees) _plant(warmth, damp);
    _standOnGround();
    _pack();
  }

  /// What a block is, from where it sits and what the weather is there.
  ///
  /// Surface rules, in the sense the genre means: the top of a column and the
  /// two or three under it are decided by climate, and everything below that
  /// is stone regardless. It is a small rule that does most of the work of
  /// making a world look like somewhere.
  int _surfaceAt(int y, int top, double t, double h) {
    final depth = top - y;

    // Deep down, a darker stone. Nothing here needs it to be a different
    // material — it needs the bottom of a hole to look like the bottom of a
    // hole rather than more of the same.
    if (depth > 4) return y < _tall * 0.28 ? _deepslate : _stone;

    // Beaches: anything at the water's edge is sand, whatever the climate,
    // because that is what the shore of a lake looks like.
    final shore = top <= _seaLevel + 1;
    if (shore) return depth == 0 || depth == 1 ? _sand : _sandstone;

    // Desert: hot and dry, and sand all the way down to sandstone.
    if (t > 0.35 && h < -0.1) {
      return depth <= 2 ? _sand : _sandstone;
    }

    // Snow, by height first and cold second — a peak is white because it is
    // high, and a cold region is white at a lower line than a warm one.
    final snowLine = _tall * (0.62 - t * 0.18);
    if (top > snowLine) return depth == 0 ? _snow : _stone;

    // Bare rock just under the snow, so a mountain has a stony shoulder
    // rather than grass running to the summit.
    if (top > snowLine - 3) return _stone;

    return depth == 0 ? _grass : _dirt;
  }

  /// Puts trees where trees grow.
  ///
  /// A feature pass, after the ground: they need to know where the surface
  /// ended up, and they are placed on a grid with an offset rather than at
  /// random, so a forest is spread out instead of clumping into thickets and
  /// bare patches.
  void _plant(Noise warmth, Noise damp) {
    final chance = math.Random(_seed * 7717);
    final half = _side ~/ 2;

    for (var gx = 2; gx < _side - 2; gx += 4) {
      for (var gz = 2; gz < _side - 2; gz += 4) {
        final x = gx + chance.nextInt(3) - 1;
        final z = gz + chance.nextInt(3) - 1;
        final wx = x - half;
        final wz = z - half;

        final t = (warmth.at(wx * 0.017, wz * 0.017) * 1.9).clamp(-1.0, 1.0);
        final h = (damp.at(wx * 0.019, wz * 0.019) * 1.9).clamp(-1.0, 1.0);
        // Where it is warm enough and damp enough. Deserts and peaks get none,
        // which is most of what makes them read as deserts and peaks.
        if (h < 0.05 || t < -0.35) continue;
        if (chance.nextDouble() > 0.55 + h * 0.35) continue;

        // On grass only — not on sand, not on stone, not in a lake.
        var ground = -1;
        for (var y = _tall - 1; y > 0; y--) {
          if (_at(x, y, z) != _air) {
            ground = y;
            break;
          }
        }
        if (ground < 0 || _at(x, ground, z) != _grass) continue;

        final tall = 4 + chance.nextInt(3);
        if (ground + tall + 2 >= _tall) continue;

        for (var i = 1; i <= tall; i++) {
          _put(x, ground + i, z, _log);
        }
        // A blob of leaves rather than a shape: two layers wide around the
        // top of the trunk, narrowing to a cap.
        for (var dy = -1; dy <= 1; dy++) {
          final spread = dy == 1 ? 1 : 2;
          for (var dx = -spread; dx <= spread; dx++) {
            for (var dz = -spread; dz <= spread; dz++) {
              if (dx == 0 && dz == 0 && dy < 1) continue;
              // Corners off, so it is round rather than a cube.
              if (dx.abs() == spread && dz.abs() == spread) continue;
              _put(x + dx, ground + tall + dy, z + dz, _leaves);
            }
          }
        }
        _put(x, ground + tall + 2, z, _leaves);
      }
    }
  }

  /// Turns the grid into the buffers the renderer draws.
  ///
  /// Only blocks with air beside them. A block surrounded on all six sides
  /// cannot be seen from anywhere, and in a world of solid hills that is most
  /// of them — this is the difference between drawing the surface and drawing
  /// the volume, and it is about eight times fewer.
  void _pack() {
    final transforms = <double>[];
    final colours = <double>[];
    final half = _side / 2;

    for (var y = 0; y < _tall; y++) {
      for (var z = 0; z < _side; z++) {
        for (var x = 0; x < _side; x++) {
          final kind = _at(x, y, z);
          if (kind == _air) continue;

          final buried =
              _at(x + 1, y, z) != _air &&
              _at(x - 1, y, z) != _air &&
              _at(x, y + 1, z) != _air &&
              _at(x, y - 1, z) != _air &&
              _at(x, y, z + 1) != _air &&
              _at(x, y, z - 1) != _air;
          if (buried) continue;

          transforms.addAll(
            _placed(x - half + 0.5, y.toDouble(), z - half + 0.5),
          );
          colours.addAll(_colourOf(kind, x, z));
        }
      }
    }

    _transforms = Float32List.fromList(transforms);
    _colours = Float32List.fromList(colours);
    _blockCount = colours.length ~/ 3;
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

  /// What a kind of block looks like, with a little variation by where it is.
  ///
  /// The variation matters more than the colours do: without it a hillside is
  /// one flat green, and a field of identical cubes reads as a spreadsheet.
  /// Hashed from the position rather than random, so a block is the same
  /// shade every time the world is built and digging one out does not
  /// re-shuffle its neighbours.
  List<double> _colourOf(int kind, int x, int z) {
    final shade =
        0.88 + (((x * 73856093) ^ (z * 19349663)) & 0xFF) / 0xFF * 0.2;
    return switch (kind) {
      _grass => [0.26 * shade, 0.52 * shade, 0.20 * shade],
      _dirt => [0.36 * shade, 0.26 * shade, 0.17 * shade],
      _stone => [0.44 * shade, 0.44 * shade, 0.45 * shade],
      _deepslate => [0.20 * shade, 0.20 * shade, 0.22 * shade],
      _sand => [0.80 * shade, 0.73 * shade, 0.50 * shade],
      _sandstone => [0.70 * shade, 0.62 * shade, 0.42 * shade],
      _snow => [0.93 * shade, 0.95 * shade, 0.98 * shade],
      _log => [0.30 * shade, 0.21 * shade, 0.12 * shade],
      _leaves => [0.14 * shade, 0.38 * shade, 0.13 * shade],
      _water => [0.10, 0.30, 0.46],
      _ => [0.31 * shade, 0.29 * shade, 0.27 * shade],
    };
  }

  // ---- being in it ----

  /// Puts the player on top of whatever is in the middle of the world.
  void _standOnGround() {
    for (var y = _tall - 1; y >= 0; y--) {
      if (_at(_side ~/ 2, y, _side ~/ 2) != _air) {
        _eye = Vector3(0.5, y + 2.7, 0.5);
        _fall = 0;
        return;
      }
    }
    _eye = Vector3(0.5, _tall.toDouble(), 0.5);
  }

  /// Moves the player, one frame's worth.
  ///
  /// Each axis separately, and that is the whole of why it works: moving in
  /// one step and then testing puts you inside a wall with no way to know
  /// which direction to come back out of. Tested one at a time, a corner
  /// stops you sideways and lets you keep going forwards, which is what
  /// sliding along a wall is.
  void _step(double dt) {
    final ahead = Vector3(math.sin(_yaw), 0, math.cos(_yaw));
    final side = Vector3(math.cos(_yaw), 0, -math.sin(_yaw));

    var wish = Vector3.zero();
    if (_pressed.contains(LogicalKeyboardKey.keyW)) wish += ahead;
    if (_pressed.contains(LogicalKeyboardKey.keyS)) wish -= ahead;
    if (_pressed.contains(LogicalKeyboardKey.keyA)) wish -= side;
    if (_pressed.contains(LogicalKeyboardKey.keyD)) wish += side;
    if (wish.length2 > 0) wish.normalize();

    const pace = 7.0;
    const gravity = 26.0;
    const jump = 8.4;

    // Feet, not eyes: the camera is at head height and the body is what the
    // world is tested against.
    final feet = _eye.y - 1.62;
    final standing = _solidAt(_eye.x, feet - 0.08, _eye.z);
    if (standing && _fall <= 0) {
      _fall = 0;
      if (_pressed.contains(LogicalKeyboardKey.space)) _fall = jump;
    } else {
      _fall -= gravity * dt;
    }

    for (final (dx, dz) in [
      (wish.x * pace * dt, 0.0),
      (0.0, wish.z * pace * dt),
    ]) {
      final x = _eye.x + dx;
      final z = _eye.z + dz;
      // Two heights, because a step is blocked by anything at the knee or at
      // the chest and a floor is neither.
      final blocked = _solidAt(x, feet + 0.2, z) || _solidAt(x, feet + 1.4, z);
      if (!blocked) {
        _eye.x = x;
        _eye.z = z;
      }
    }

    final rise = _fall * dt;
    final wanted = _eye.y + rise;
    if (rise < 0 && _solidAt(_eye.x, wanted - 1.62, _eye.z)) {
      // Landed: put the feet on top of the block rather than inside it.
      _eye.y = (wanted - 1.62).floorToDouble() + 1 + 1.62;
      _fall = 0;
    } else if (rise > 0 && _solidAt(_eye.x, wanted - 1.62 + 1.8, _eye.z)) {
      _fall = 0;
    } else {
      _eye.y = wanted;
    }
  }

  /// What is under the crosshair, and the empty cell in front of it.
  ///
  /// Stepped a fraction of a block at a time rather than solved. A proper
  /// grid traversal is faster and this is called once per click, on a ray
  /// six blocks long — the version that is obviously correct is worth more
  /// here than the version that is quick.
  ({int x, int y, int z, int fx, int fy, int fz})? _looking() {
    final dir = Vector3(
      math.sin(_yaw) * math.cos(_pitch),
      math.sin(_pitch),
      math.cos(_yaw) * math.cos(_pitch),
    );
    final half = _side / 2;
    var fx = 0, fy = 0, fz = 0;
    var has = false;

    for (var t = 0.0; t < 6.0; t += 0.03) {
      final p = _eye + dir * t;
      final x = (p.x + half).floor();
      final y = p.y.floor();
      final z = (p.z + half).floor();
      final kind = _at(x, y, z);
      if (kind != _air && kind != _water) {
        return (
          x: x,
          y: y,
          z: z,
          fx: has ? fx : x,
          fy: has ? fy : y,
          fz: has ? fz : z,
        );
      }
      fx = x;
      fy = y;
      fz = z;
      has = true;
    }
    return null;
  }

  /// Takes out the block under the crosshair.
  void dig() {
    final hit = _looking();
    if (hit == null) return;
    _put(hit.x, hit.y, hit.z, _air);
    _pack();
  }

  /// Puts one back, against the face being looked at.
  void place() {
    final hit = _looking();
    if (hit == null) return;
    if (_at(hit.fx, hit.fy, hit.fz) != _air) return;
    _put(hit.fx, hit.fy, hit.fz, _stone);
    _pack();
  }
}
