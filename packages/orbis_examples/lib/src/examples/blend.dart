import 'dart:async';
import 'dart:math' as math;

import '../platform/io.dart';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../example.dart';
import 'surface.dart' show linearOf;

/// Two surfaces on one mesh, and the three ways of choosing between them.
///
/// The problem this solves is ground. A field that becomes a path, cobbles
/// that disappear under grass, mud gathering at the bottom of a slope — none
/// of it is one material, and the alternatives are a seam where two meshes
/// meet or a texture painted for that one patch of world and useful nowhere
/// else.
///
/// All three panels are the same two surfaces and the same mask. What differs
/// is what the mask is taken to mean, and the third is the one worth looking
/// at: read as a height rather than as an opacity, grass fills the mortar
/// between the cobbles first and leaves the stones as stone until they are
/// buried. That is what ground does, and no amount of fading gets there — a
/// half-faded cobble is not half covered, it is grey-green.
class BlendExample extends Example {
  BlendExample() {
    _draw();
  }

  @override
  String get name => 'Blending';

  @override
  String get blurb =>
      'Two surfaces on one mesh: linear, masked, and masked by height.';

  @override
  ViewPoint get viewpoint =>
      const ViewPoint(distance: 12.5, pitch: 0.62, height: 0, yaw: 0.06);

  double amount = 0.5;
  double sharpness = 14;
  bool separateScale = true;

  String? _cobbles;
  String? _grass;
  String? _height;

  bool get _ready => _cobbles != null && _grass != null && _height != null;

  /// The three modes, left to right.
  static const _panels = <(OrbisBlendMode, String)>[
    (OrbisBlendMode.linear, 'Linear'),
    (OrbisBlendMode.masked, 'Masked'),
    (OrbisBlendMode.maskedDepth, 'Masked depth'),
  ];

  @override
  OrbisScene scene(OrbisCamera camera, double seconds) {
    return OrbisScene(
      camera: camera,
      materials: [
        for (var i = 0; i < _panels.length; i++)
          OrbisMaterial(
            key: 10 + i,
            baseColour: Vector4(1, 1, 1, 1),
            roughness: 0.78,
            baseColourMap: _cobbles == null ? null : OrbisTexture(_cobbles!),
            blendMode: _ready ? _panels[i].$1 : OrbisBlendMode.none,
            blendAmount: amount,
            blendSharpness: sharpness,
            blendBaseColourMap: _grass == null ? null : OrbisTexture(_grass!),
            blendMaskMap: _height == null
                ? null
                : OrbisTexture(_height!, srgb: false),
            tiling: Vector2(2, 2),
            // Grass at a different scale from the stones it grows between,
            // which is most of what stops two tiling textures from reading as
            // one repeating pattern.
            blendTiling: separateScale ? Vector2(5, 5) : null,
          ),
      ],
      objects: [
        for (var i = 0; i < _panels.length; i++)
          OrbisObject(
            key: 10 + i,
            material: 10 + i,
            // The cube spans minus one to one, so a scale of two is four
            // across and 4.4 apart leaves them a gap rather than a seam.
            transform: Matrix4.identity()
              ..setTranslation(Vector3((i - 1) * 4.4, 0, 0))
              ..multiply(Matrix4.diagonal3(Vector3(2.0, 0.16, 2.0))),
            colour: Vector3(1, 1, 1),
          ),
      ],
      lights: [
        OrbisLight(
          key: 900,
          kind: OrbisLightKind.directional,
          direction: Vector3(-0.4, -0.9, -0.35),
          colour: linearOf(const Color(0xFFFFF3E0)),
          intensity: 95000,
        ),
      ],
      sky: OrbisSky(
        zenith: linearOf(const Color(0xFF4E7FB4)),
        horizon: linearOf(const Color(0xFFBACEE0)),
        ambient: 24000,
      ),
      pipeline: OrbisPipeline(
        shadows: OrbisShadows(kind: OrbisShadowKind.soft, distance: 40),
      ),
    );
  }

  @override
  Widget settings(BuildContext context, VoidCallback changed) {
    final caption = Theme.of(context).textTheme.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Left to right: ${_panels.map((panel) => panel.$2).join(', ')}. '
          'Same two surfaces, same mask, three readings of it.',
          style: caption,
        ),
        const SizedBox(height: 8),
        Setting(
          label: 'Grass',
          value: amount,
          min: 0,
          max: 1,
          onChanged: (value) {
            amount = value;
            changed();
          },
        ),
        Setting(
          label: 'Sharpness',
          value: sharpness,
          min: 1,
          max: 40,
          decimals: 0,
          onChanged: (value) {
            sharpness = value;
            changed();
          },
        ),
        Toggle(
          label: 'Own scale',
          value: separateScale,
          onChanged: (value) {
            separateScale = value;
            changed();
          },
        ),
        const SizedBox(height: 6),
        Text(
          'At half grass the first two panels are half grass everywhere — one '
          'flat, one following the mask. The third has grass in the mortar '
          'and stone on the stones, and sharpness is how abruptly it hands '
          'over: turn it down and it becomes the second panel.',
          style: caption,
        ),
      ],
    );
  }

  @override
  String get code => '''
// One material, two surfaces. The mask decides between them — and what the
// mask is taken to mean is the mode.
OrbisMaterial(
  key: 1,
  baseColourMap: OrbisTexture(cobbles),
  blendBaseColourMap: OrbisTexture(grass),
  blendMaskMap: OrbisTexture(height, srgb: false),

  blendMode: OrbisBlendMode.maskedDepth,
  blendAmount: 0.5,           // how much grass there is
  blendSharpness: 14,         // how hard the handover is
  blendTiling: Vector2(5, 5), // grass at its own scale
)

// linear      — the amount, everywhere, ignoring the mask.
// masked      — the mask scaled by the amount: a proportional fade.
// maskedDepth — the mask read as a height, so the low ground fills first.
''';

  // ---- the surfaces, drawn rather than shipped ----

  /// Cobbles, grass, and the height that decides between them.
  ///
  /// Generated rather than bundled, so the example carries no assets and says
  /// exactly what its textures are. The height map being the cobble relief is
  /// what makes the third panel work: a mask painted independently of the
  /// surface it masks would put grass where the stones are.
  Future<void> _draw() async {
    final directory = Directory(
      '${Directory.systemTemp.path}/orbis_gallery_blend',
    );
    await directory.create(recursive: true);

    const size = 256;
    const across = 6;
    final cobbles = Uint8List(size * size * 4);
    final grass = Uint8List(size * size * 4);
    final height = Uint8List(size * size * 4);

    final noise = math.Random(7);
    final perStone = List.generate(across * across, (_) => noise.nextDouble());
    final perPixel = List.generate(64 * 64, (_) => noise.nextDouble());

    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final at = (y * size + x) * 4;
        final u = x / size;
        final v = y / size;

        // Stones laid in courses, every other course shifted half a width,
        // which is how paving is actually laid and most of why it reads as
        // paving rather than as spots.
        final row = (v * across).floor();
        final shifted = u * across + (row.isOdd ? 0.5 : 0.0);
        final cell = (row * across + shifted.floor()) % perStone.length;

        final withinX = shifted % 1 - 0.5;
        final withinY = (v * across) % 1 - 0.5;

        // A rounded square rather than a circle. Circles on a grid leave more
        // gap at their corners than any mortar joint has, and it is that gap
        // that reads as spots; a squarer stone packs, and the joint stays a
        // joint. One field again, drawn as colour and read as relief.
        final toEdge = math
            .pow(
              math.pow((withinX * 2).abs(), 5) +
                  math.pow((withinY * 2).abs(), 5),
              0.2,
            )
            .toDouble();

        // Each stone sits a little higher or lower than its neighbours, which
        // is what stops the grass line running dead straight along a joint.
        final sits = 0.86 + perStone[cell] * 0.12;
        final mortar = toEdge > sits;
        final stone = ((sits - toEdge) / 0.26).clamp(0.0, 1.0);

        final shade = 0.82 + perStone[cell] * 0.26;
        // Darker into the joint, so the relief is in the colour as well and
        // does not depend on a light being in the right place to be seen.
        final lit = mortar ? 0.46 : 0.72 + stone * 0.28;

        cobbles[at] = (168 * shade * lit).round().clamp(0, 255);
        cobbles[at + 1] = (162 * shade * lit).round().clamp(0, 255);
        cobbles[at + 2] = (152 * shade * lit).round().clamp(0, 255);
        cobbles[at + 3] = 255;

        // Grass: a green that varies per pixel, so that at five times the
        // scale it reads as blades rather than as paint.
        final blade = perPixel[(x % 64) * 64 + (y % 64)];
        grass[at] = (58 + blade * 44).round();
        grass[at + 1] = (100 + blade * 60).round();
        grass[at + 2] = (42 + blade * 28).round();
        grass[at + 3] = 255;

        // The height the blend reads, in red: high in the mortar and low on
        // the crown of each stone, because grass grows in the gaps. This is
        // the stone field inverted, and inverting it is what decides which
        // surface fills in first.
        final level = ((1 - stone).clamp(0.0, 1.0) * 255).round();
        height[at] = level;
        height[at + 1] = level;
        height[at + 2] = level;
        height[at + 3] = 255;
      }
    }

    _cobbles = await _write(directory, 'cobbles.png', cobbles, size);
    _grass = await _write(directory, 'grass.png', grass, size);
    _height = await _write(directory, 'height.png', height, size);
  }

  Future<String?> _write(
    Directory directory,
    String name,
    Uint8List pixels,
    int size,
  ) async {
    final image = await _decode(pixels, size);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (bytes == null) return null;
    final file = File('${directory.path}/$name');
    await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    return file.path;
  }

  Future<ui.Image> _decode(Uint8List pixels, int size) {
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      size,
      size,
      ui.PixelFormat.rgba8888,
      done.complete,
    );
    return done.future;
  }
}
