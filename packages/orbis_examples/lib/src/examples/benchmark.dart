import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../example.dart';
import 'surface.dart' show linearOf;

/// What the engine costs, with the load in your hands.
///
/// Every other example is arranged to look like something. This one is
/// arranged to be measured: each dial adds work of one particular kind, and
/// the readout says what a frame costs the GPU — not how often a frame is
/// presented, which is the display's business and looks identical whether the
/// engine has ten per cent of headroom or two hundred.
///
/// The three loads are separated because they are not the same cost at all.
/// A member of a population is a row in a buffer and sixty-four of them share
/// a draw. An object is tracked one at a time: it has a key, it is compared
/// against last frame, and it gets its own entity. The sky is neither — it is
/// a volume marched per pixel, and it is the only one of the three whose cost
/// does not depend on how much of anything there is.
class BenchmarkExample extends Example {
  BenchmarkExample();

  @override
  String get name => 'Benchmark';

  @override
  String get blurb =>
      'Turn the load up and watch what a frame costs. Nothing here is staged.';

  @override
  ViewPoint get viewpoint =>
      const ViewPoint(distance: 70, pitch: 0.36, height: 4);

  /// Members of a population: a row in a buffer, sixty-four to a draw.
  double members = 50000;
  double wantedMembers = 50000;

  /// Objects tracked one at a time, each with its own entity and draw.
  double objects = 200;
  double wantedObjects = 200;

  SkyQuality sky = SkyQuality.fair;
  bool shadows = true;
  bool moving = false;

  Float32List _transforms = Float32List(0);
  Float32List _colours = Float32List(0);
  int _revision = 0;
  int _built = -1;

  /// What the last frame cost, as the renderer measured it.
  double gpuMilliseconds = 0;
  int? _viewport;

  /// Told the view's number, so the cost can be asked after.
  void watch(int viewport) => _viewport = viewport;

  /// Asks the renderer what a frame is costing. Called by the overlay, which
  /// is the only part of this that redraws often enough to be worth it.
  Future<void> refresh() async {
    final viewport = _viewport;
    if (viewport == null) return;
    gpuMilliseconds = await OrbisView.gpuMilliseconds(viewport);
  }

  @override
  OrbisScene scene(OrbisCamera camera, double seconds) {
    final total = members.round();
    if (_built != total) {
      _fill(total);
      _built = total;
      _revision++;
    }

    // Only when something is asked to move, because the point of a population
    // is that standing still costs nothing at all.
    if (moving) _revision++;

    final individually = objects.round();
    final drift = moving ? seconds : 0.0;

    return OrbisScene(
      populations: [
        if (total > 0)
          OrbisPopulation(
            key: 1,
            transforms: _transforms,
            colours: _colours,
            minimum: Vector3(-60, -2, -60),
            maximum: Vector3(60, 8, 60),
            revision: _revision,
            castShadows: shadows,
          ),
      ],
      objects: [
        // The other kind of load: each of these is compared against last
        // frame, gets an entity of its own, and costs a draw.
        for (var i = 0; i < individually; i++)
          OrbisObject(
            key: 2000 + i,
            transform: Matrix4.identity()
              ..setTranslation(
                Vector3(
                  math.cos(i * 2.399963) * (1.6 * math.sqrt(i + 1)),
                  0.6 + math.sin(drift * 0.9 + i) * (moving ? 0.5 : 0),
                  math.sin(i * 2.399963) * (1.6 * math.sqrt(i + 1)),
                ),
              )
              ..rotateY(i * 0.7 + drift * 0.3)
              ..scaleByDouble(0.6, 1.2, 0.6, 1),
            colour: linearOf(
              Color.lerp(
                const Color(0xFFD9634F),
                const Color(0xFF5FA8D3),
                (i % 17) / 16,
              )!,
            ),
            castShadows: shadows,
          ),
        OrbisObject(
          key: 1990,
          transform: Matrix4.identity()
            ..setTranslation(Vector3(0, -1.2, 0))
            ..scaleByDouble(90.0, 0.06, 90.0, 1),
          colour: linearOf(const Color(0xFF39404A)),
          castShadows: false,
        ),
      ],
      lights: [
        OrbisLight(
          key: 1980,
          kind: OrbisLightKind.directional,
          intensity: 78000,
          direction: Vector3(-0.4, -0.9, -0.35)..normalize(),
          colour: linearOf(const Color(0xFFFFF3E0)),
          sunAngularRadius: 0.6,
          castShadows: shadows,
        ),
      ],
      fog: OrbisFog(
        colour: linearOf(const Color(0xFFB9CBDD)),
        density: 0.004,
        distance: 25,
        maximumOpacity: 1,
      ),
      sky: OrbisSky(
        colour: linearOf(const Color(0xFF6E8DB4)),
        zenith: linearOf(const Color(0xFF2F5F97)),
        horizon: linearOf(const Color(0xFFB9CBDD)),
        ambient: 24000,
        bodyDirection: Vector3(0.4, 0.9, 0.35)..normalize(),
        bodyColour: linearOf(const Color(0xFFFFF6E8)),
        bodySize: 0.011,
        quality: sky,
        clouds: OrbisClouds.cumulus(cover: 0.42, wind: Vector2(4, 1.5)),
      ),
      camera: camera,
    );
  }

  void _fill(int total) {
    _transforms = Float32List(total * 16);
    _colours = Float32List(total * 3);

    final random = math.Random(11);
    for (var i = 0; i < total; i++) {
      final x = (random.nextDouble() * 2 - 1) * 58;
      final z = (random.nextDouble() * 2 - 1) * 58;
      final height = 0.4 + random.nextDouble() * 2.6;
      final width = 0.25 + random.nextDouble() * 0.4;
      final turn = random.nextDouble() * math.pi * 2;

      final at = i * 16;
      final c = math.cos(turn) * width;
      final s = math.sin(turn) * width;

      _transforms[at + 0] = c;
      _transforms[at + 2] = -s;
      _transforms[at + 5] = height * 0.5;
      _transforms[at + 8] = s;
      _transforms[at + 10] = c;
      _transforms[at + 12] = x;
      _transforms[at + 13] = height * 0.5 - 1.2;
      _transforms[at + 14] = z;
      _transforms[at + 15] = 1;

      final tone = random.nextDouble();
      final colour = linearOf(
        Color.lerp(const Color(0xFF6F8F55), const Color(0xFFB86B3C), tone)!,
      );
      _colours[i * 3 + 0] = colour.x;
      _colours[i * 3 + 1] = colour.y;
      _colours[i * 3 + 2] = colour.z;
    }
  }

  @override
  Widget? overlay(BuildContext context, VoidCallback changed) =>
      _Readout(example: this);

  @override
  Widget settings(BuildContext context, VoidCallback changed) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Setting(
          label: 'Members',
          value: wantedMembers,
          min: 0,
          max: 200000,
          decimals: 0,
          onChanged: (value) {
            wantedMembers = value;
            changed();
          },
          // Laying two hundred thousand out takes long enough that doing it on
          // every pixel of a drag is the only thing you would be measuring.
          onSettled: (value) {
            members = value;
            changed();
          },
        ),
        Setting(
          label: 'Objects',
          value: wantedObjects,
          min: 0,
          max: 3000,
          decimals: 0,
          onChanged: (value) {
            wantedObjects = value;
            changed();
          },
          onSettled: (value) {
            objects = value;
            changed();
          },
        ),
        Choice(
          label: 'Sky',
          options: const ['Lean', 'Fair', 'Full'],
          selected: switch (sky) {
            SkyQuality.lean => 'Lean',
            SkyQuality.fair => 'Fair',
            SkyQuality.full => 'Full',
          },
          onSelect: (option) {
            sky = switch (option) {
              'Lean' => SkyQuality.lean,
              'Fair' => SkyQuality.fair,
              _ => SkyQuality.full,
            };
            changed();
          },
        ),
        Toggle(
          label: 'Shadows',
          value: shadows,
          onChanged: (value) {
            shadows = value;
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
  }

  @override
  String get code => '''
// The three loads, and why they are separate dials.
//
// A member of a population is a row in a buffer. Sixty-four share a draw, and
// standing still costs nothing at all — the buffer is only sent when its
// revision moves.
OrbisPopulation(key: 1, transforms: transforms, colours: colours,
                revision: revision, minimum: ..., maximum: ...)

// An object is tracked one at a time: its own key, its own entity, its own
// draw, compared against last frame every frame.
OrbisObject(key: 2000 + i, transform: ..., colour: ...)

// And the sky is neither. It is a volume marched per pixel, so its cost has
// nothing to do with how much of anything is in the scene.
OrbisSky(quality: SkyQuality.fair, clouds: OrbisClouds.cumulus(cover: 0.42))

// What a frame cost, from Filament's own frame history — the median of the
// last handful, because a mean is dragged about by the one frame in thirty
// that hits a hitch.
final ms = await OrbisView.gpuMilliseconds(viewport);
''';
}

/// The figure, over the scene.
///
/// Its own widget because it ticks on its own: asking the renderer what a
/// frame cost is a trip across the platform channel, and doing that inside the
/// scene's own rebuild would be measuring the measurement.
class _Readout extends StatefulWidget {
  const _Readout({required this.example});

  final BenchmarkExample example;

  @override
  State<_Readout> createState() => _ReadoutState();
}

class _ReadoutState extends State<_Readout> {
  @override
  void initState() {
    super.initState();
    _ask();
  }

  Future<void> _ask() async {
    while (mounted) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (!mounted) return;
      await widget.example.refresh();
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final cost = widget.example.gpuMilliseconds;
    final rate = cost > 0 ? 1000 / cost : 0.0;

    // Green while there is room for a frame at sixty, amber when it is close,
    // red when a frame no longer fits.
    final colour = cost <= 0
        ? const Color(0xFF8A93A0)
        : cost < 8
        ? const Color(0xFF7FB069)
        : cost < 16.6
        ? const Color(0xFFE0B252)
        : const Color(0xFFD9634F);

    return IgnorePointer(
      child: Align(
        alignment: Alignment.topLeft,
        child: Container(
          margin: const EdgeInsets.all(18),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xE6111418),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFF2A313A)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                cost <= 0
                    ? 'measuring…'
                    : '${cost.toStringAsFixed(2)} ms a frame',
                style: TextStyle(
                  color: colour,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              if (cost > 0)
                Text(
                  '${rate.round()} a second if nothing waited for the display',
                  style: const TextStyle(
                    color: Color(0xFF8A93A0),
                    fontSize: 12,
                  ),
                ),
              const SizedBox(height: 6),
              Text(
                '${widget.example.members.round()} members · '
                '${widget.example.objects.round()} objects · '
                'sky ${widget.example.sky.name}',
                style: const TextStyle(color: Color(0xFF6E7681), fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
