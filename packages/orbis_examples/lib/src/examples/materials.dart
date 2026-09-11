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

/// What things are made of.
///
/// The numbers here describe the material rather than the look: metalness is
/// what the surface *is*, roughness is how scattered its reflections are, and
/// a value that is right for copper is right for copper under every light in
/// every scene. That is the whole reason to spell a surface out this way
/// instead of exposing a colour and a shininess slider.
///
/// The grid is the proof. Metalness goes across it and roughness goes down,
/// nothing else changes, and every square in it is a real material somebody
/// could name.
class MaterialsExample extends Example {
  MaterialsExample() {
    _draw();
  }

  @override
  String get name => 'Materials';

  @override
  String get blurb =>
      'Metalness and roughness across a grid, five ways of blending, and '
      'textures written at startup so there is nothing to download.';

  @override
  ViewPoint get viewpoint =>
      const ViewPoint(distance: 17, pitch: 0.30, yaw: 0.5);

  /// Where the generated images went, once they are there to be read.
  String? _albedo;
  String? _normals;
  String? _packed;
  String? _cutout;

  bool textured = true;
  double tiling = 3;
  double reflectance = 0.5;
  double normalScale = 1;
  OrbisBlend blend = OrbisBlend.transparent;
  double alpha = 0.45;

  /// Writes the three maps to disk, once, at startup.
  ///
  /// Generated rather than shipped so the example has nothing to fetch and
  /// nothing to keep in the repository — and because a checker and a bump
  /// field say more about what a map does than a photograph would.
  Future<void> _draw() async {
    final directory = Directory(
      '${Directory.systemTemp.path}/orbis_gallery_materials',
    );
    await directory.create(recursive: true);

    const size = 256;
    final albedo = Uint8List(size * size * 4);
    final normals = Uint8List(size * size * 4);
    final packed = Uint8List(size * size * 4);
    final cutout = Uint8List(size * size * 4);

    double height(double x, double y) =>
        math.sin(x * math.pi * 4) * math.sin(y * math.pi * 4) * 0.5;

    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final at = (y * size + x) * 4;
        final u = x / size;
        final v = y / size;

        // A checker with a grout line, so tiling is obvious and so is the
        // filter setting when it is turned down to sharp.
        final square = ((x ~/ 32) + (y ~/ 32)).isEven;
        final grout = (x % 32 < 2) || (y % 32 < 2);
        final tone = grout ? 46 : (square ? 214 : 132);
        albedo[at] = tone;
        albedo[at + 1] = grout ? 42 : (square ? 206 : 120);
        albedo[at + 2] = grout ? 40 : (square ? 190 : 112);
        albedo[at + 3] = 255;

        // A height field turned into a normal by taking its slope. Flat is
        // the pale lilac that packs to nought, which is what a normal map
        // looks like when nothing is happening.
        const step = 1 / size;
        final slopeX = (height(u + step, v) - height(u - step, v)) / (2 * step);
        final slopeY = (height(u, v + step) - height(u, v - step)) / (2 * step);
        final length = math.sqrt(slopeX * slopeX + slopeY * slopeY + 1);
        normals[at] = (((-slopeX / length) * 0.5 + 0.5) * 255).round();
        normals[at + 1] = (((-slopeY / length) * 0.5 + 0.5) * 255).round();
        normals[at + 2] = ((((1 / length) * 0.5) + 0.5) * 255).round();
        normals[at + 3] = 255;

        // glTF's packing, which is what every exporter writes: occlusion in
        // red, roughness in green, metalness in blue. The grout is rougher
        // and never metal; the tiles are smoother and half of them are.
        packed[at] = grout ? 150 : 255;
        packed[at + 1] = grout ? 255 : (square ? 90 : 170);
        packed[at + 2] = square && !grout ? 255 : 0;
        packed[at + 3] = 255;

        // A pattern that lives in the alpha channel, which is the only thing
        // masking looks at. Rings of holes: solid where the alpha is high,
        // gone where it is low, and nothing in between however the threshold
        // is set.
        final ring =
            math.sqrt(
              math.pow((u % 0.25) - 0.125, 2) + math.pow((v % 0.25) - 0.125, 2),
            ) /
            0.125;
        cutout[at] = 230;
        cutout[at + 1] = 226;
        cutout[at + 2] = 214;
        cutout[at + 3] = (ring.clamp(0.0, 1.0) * 255).round();
      }
    }

    _albedo = await _write(directory, 'albedo.png', albedo, size, srgb: true);
    _normals = await _write(directory, 'normals.png', normals, size);
    _packed = await _write(directory, 'packed.png', packed, size);
    _cutout = await _write(directory, 'cutout.png', cutout, size, srgb: true);
  }

  Future<String?> _write(
    Directory directory,
    String name,
    Uint8List pixels,
    int size, {
    bool srgb = false,
  }) async {
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

  /// The five squares across the bottom, and what each of them is for.
  static const List<(OrbisBlend, String, Color)> _blends = [
    (OrbisBlend.opaque, 'Opaque', Color(0xFFB9C2CC)),
    (OrbisBlend.transparent, 'Glass', Color(0xFF7FC7E8)),
    (OrbisBlend.fade, 'Fade', Color(0xFFD98FA8)),
    (OrbisBlend.masked, 'Masked', Color(0xFF9CD97F)),
    (OrbisBlend.add, 'Additive', Color(0xFFE8A24F)),
  ];

  @override
  OrbisScene scene(OrbisCamera camera, double seconds) {
    final materials = <OrbisMaterial>[];
    final objects = <OrbisObject>[];

    // The floor, and the only thing wearing all three maps at once.
    materials.add(
      OrbisMaterial(
        key: 1,
        baseColour: Vector4(1, 1, 1, 1),
        roughness: 0.8,
        metallic: 0.0,
        reflectance: reflectance,
        normalScale: normalScale,
        tiling: Vector2(tiling, tiling),
        baseColourMap: textured && _albedo != null
            ? OrbisTexture(_albedo!)
            : null,
        normalMap: textured && _normals != null
            ? OrbisTexture(_normals!, srgb: false)
            : null,
        metallicRoughnessMap: textured && _packed != null
            ? OrbisTexture(_packed!, srgb: false)
            : null,
        occlusionMap: textured && _packed != null
            ? OrbisTexture(_packed!, srgb: false)
            : null,
      ),
    );
    objects.add(
      OrbisObject(
        key: 1,
        material: 1,
        transform: Matrix4.identity()
          ..setTranslation(Vector3(0, -1.6, 0))
          ..multiply(Matrix4.diagonal3(Vector3(16, 0.05, 16))),
        colour: Vector3(1, 1, 1),
      ),
    );

    // The grid: metalness across, roughness down, and nothing else moving.
    const across = 5;
    const down = 4;
    for (var column = 0; column < across; column++) {
      for (var row = 0; row < down; row++) {
        final key = 100 + row * across + column;
        materials.add(
          OrbisMaterial(
            key: key,
            baseColour: Vector4(0.72, 0.45, 0.20, 1),
            metallic: column / (across - 1),
            // Never quite nought: a highlight smaller than a pixel flickers,
            // which reads as the renderer being broken rather than the surface
            // being smooth.
            roughness: 0.05 + row / (down - 1) * 0.85,
            reflectance: reflectance,
          ),
        );
        objects.add(
          OrbisObject(
            key: key,
            material: key,
            transform: Matrix4.identity()
              ..setTranslation(
                Vector3(
                  (column - (across - 1) / 2) * 2.2,
                  1.6 - row * 1.5,
                  -2.5,
                ),
              )
              ..multiply(Matrix4.diagonal3(Vector3(0.85, 0.6, 0.85))),
            colour: Vector3(1, 1, 1),
          ),
        );
      }
    }

    // The blend modes, in a row where each has something behind it to be
    // seen through, faded into, punched out of or added to.
    for (var i = 0; i < _blends.length; i++) {
      final (mode, _, colour) = _blends[i];
      final at = Vector3((i - 2) * 2.6, -0.7, 3.6);
      final linear = linearOf(colour);

      objects.add(
        OrbisObject(
          key: 300 + i,
          transform: Matrix4.identity()
            ..setTranslation(at + Vector3(0, 0, -1.4))
            ..multiply(Matrix4.diagonal3(Vector3(0.5, 0.5, 0.5))),
          colour: linearOf(const Color(0xFF39414B)),
        ),
      );

      materials.add(
        OrbisMaterial(
          key: 400 + i,
          blend: mode,
          baseColour: Vector4(
            linear.x,
            linear.y,
            linear.z,
            mode == OrbisBlend.opaque || mode == OrbisBlend.masked
                ? 1.0
                : alpha,
          ),
          roughness: 0.15,
          metallic: 0.0,
          reflectance: reflectance,
          // Additive surfaces are the usual exception: writing depth makes them
          // hide each other in whatever order they happened to be drawn.
          depthWrite: mode != OrbisBlend.add,
          emissiveIntensity: mode == OrbisBlend.add ? 2.0 : 0.0,
          emissive: mode == OrbisBlend.add ? linear : null,
          // Masking looks at nothing but alpha, so the square that shows it off
          // wears a map whose alpha is a pattern. Every pixel is either fully
          // there or gone: unlike the two fading modes beside it, this one
          // still writes depth and still sorts, which is why leaves and
          // chain-link are done this way rather than with transparency.
          maskThreshold: 0.5,
          tiling: mode == OrbisBlend.masked ? Vector2(2, 2) : Vector2(1, 1),
          baseColourMap: mode == OrbisBlend.masked && _cutout != null
              ? OrbisTexture(_cutout!)
              : null,
        ),
      );
      objects.add(
        OrbisObject(
          key: 400 + i,
          material: 400 + i,
          transform: Matrix4.identity()
            ..setTranslation(at)
            ..multiply(Matrix4.rotationY(seconds * 0.4))
            ..multiply(Matrix4.diagonal3(Vector3(1.0, 1.4, 1.0))),
          colour: Vector3(1, 1, 1),
        ),
      );
    }

    return OrbisScene(
      objects: objects,
      materials: materials,
      camera: camera,
      lights: [
        OrbisLight(
          key: 900,
          kind: OrbisLightKind.directional,
          direction: Vector3(-0.45, -1, -0.4),
          intensity: 82000,
        ),
        OrbisLight(
          key: 901,
          kind: OrbisLightKind.point,
          position: Vector3(-5, 3.5, 5),
          intensity: 14000,
          colour: Vector3(0.7, 0.82, 1),
          castShadows: false,
        ),
      ],
      sky: OrbisSky(colour: Vector3(0.12, 0.15, 0.21), ambient: 26000),
      post: OrbisPostProcess(bloom: OrbisBloom(enabled: true, strength: 0.18)),
    );
  }

  @override
  Widget settings(BuildContext context, VoidCallback changed) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Toggle(
          label: 'Textures',
          value: textured,
          onChanged: (value) {
            textured = value;
            changed();
          },
        ),
        if (textured) ...[
          Setting(
            label: 'Tiling',
            value: tiling,
            min: 1,
            max: 12,
            decimals: 1,
            onChanged: (value) {
              tiling = value;
              changed();
            },
          ),
          Setting(
            label: 'Normal strength',
            value: normalScale,
            min: 0,
            max: 3,
            decimals: 2,
            onChanged: (value) {
              normalScale = value;
              changed();
            },
          ),
        ],
        Setting(
          label: 'Reflectance',
          value: reflectance,
          min: 0,
          max: 1,
          decimals: 2,
          onChanged: (value) {
            reflectance = value;
            changed();
          },
        ),
        Setting(
          label: 'Alpha',
          value: alpha,
          min: 0,
          max: 1,
          decimals: 2,
          onChanged: (value) {
            alpha = value;
            changed();
          },
        ),
      ],
    );
  }

  @override
  String get code => '''
// A material describes what a surface is, not what it looks like.
final brass = OrbisMaterial(
  key: 7,
  baseColour: Vector4(0.72, 0.45, 0.20, 1),
  metallic: 1.0,
  roughness: 0.25,
);

// Maps multiply into the numbers beside them, so a texture and a slider are
// the same control. Tiling is applied by the shader — there is no automatic
// repeat behind your back.
final floor = OrbisMaterial(
  key: 8,
  tiling: Vector2(3, 3),
  baseColourMap: OrbisTexture('/path/albedo.png'),
  normalMap: OrbisTexture('/path/normals.png', srgb: false),
  metallicRoughnessMap: OrbisTexture('/path/packed.png', srgb: false),
);

// Blending is the one property that cannot change without recompiling the
// shader, so it selects which compiled surface the object is drawn with.
final glass = OrbisMaterial(
  key: 9,
  blend: OrbisBlend.transparent,
  baseColour: Vector4(0.5, 0.78, 0.9, 0.45),
  roughness: 0.15,
);

// Objects name a material by its key; the renderer keeps one instance behind
// however many are made of it.
OrbisScene(
  objects: [OrbisObject(key: 1, material: 7, transform: ..., colour: ...)],
  materials: [brass, floor, glass],
  camera: camera,
);
''';
}
