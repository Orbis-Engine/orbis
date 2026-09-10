import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../example.dart';
import 'surface.dart' show linearOf;

/// Surface detail thrown onto whatever is in the way.
///
/// A poster on a wall, a scorch and a puddle on the floor, a hazard stripe
/// along the foot of the wall, and a splash of paint across a crate. None of
/// them is geometry: each is a box, and every lit surface inside the box is
/// painted before it is lit — which is why the crate's shadow falls across
/// the scorch rather than the scorch sitting on top of the shadow, and why
/// the puddle catches the sun where the dry floor round it does not.
///
/// The three switches are the three things a decal has to get right beyond
/// drawing at all. Turn the angle fade off and the hazard stripe, whose box
/// straddles the corner, runs down the wall as streaks — every point on a
/// surface edge-on to the projector lands on the same row of the picture.
/// Turn the crate's exclusion off and the paint lands on its lid as well as
/// the floor round it.
class DecalsExample extends Example {
  DecalsExample() {
    _draw();
  }

  @override
  String get name => 'Decals';

  @override
  String get blurb =>
      'Posters, scorches, a puddle and road paint projected onto a floor and '
      'a wall, lit and shadowed with the surface under them.';

  @override
  ViewPoint get viewpoint =>
      const ViewPoint(yaw: 0.35, pitch: 0.55, distance: 10, height: 0.8);

  /// Whether any are painted, so the difference can be measured.
  bool on = true;

  /// Whether a surface turned away from a decal's projector fades it out.
  bool angleFade = true;

  /// Whether the paint splash leaves the crate, which is on layer one, alone.
  bool spareTheCrate = true;

  /// How strongly they are all painted.
  double opacity = 1;

  /// Only this one of [_decals], for measuring one box at a time. Null for
  /// all of them.
  int? only;

  String? _poster;
  String? _scorch;
  String? _puddle;
  String? _stripes;
  String? _splash;

  static const int _floor = 1;
  static const int _wall = 2;
  static const int _crate = 3;

  /// Paints the five pictures once, at startup, into the temporary folder.
  ///
  /// Generated rather than shipped so there is nothing to download, and
  /// because what matters about each is its alpha: where a picture is solid,
  /// where it is soft, and where it is not there at all.
  Future<void> _draw() async {
    final directory = Directory(
      '${Directory.systemTemp.path}/orbis_gallery_decals',
    );
    await directory.create(recursive: true);
    const size = 256;

    double smooth(double edge0, double edge1, double x) {
      final t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
      return t * t * (3 - 2 * t);
    }

    Future<String?> paint(
      String name,
      (int, int, int, int) Function(double u, double v) at,
    ) async {
      final pixels = Uint8List(size * size * 4);
      for (var y = 0; y < size; y++) {
        for (var x = 0; x < size; x++) {
          final (r, g, b, a) = at((x + 0.5) / size, (y + 0.5) / size);
          final i = (y * size + x) * 4;
          pixels[i] = r;
          pixels[i + 1] = g;
          pixels[i + 2] = b;
          pixels[i + 3] = a;
        }
      }
      return _write(directory, name, pixels, size);
    }

    // A poster: a border, a sky, a sun and some hills. Solid everywhere, so
    // it covers the wall completely inside its box.
    _poster = await paint('poster.png', (u, v) {
      if (u < 0.05 || u > 0.95 || v < 0.04 || v > 0.96) {
        return (240, 236, 222, 255);
      }
      final sun = math.sqrt(math.pow(u - 0.66, 2) + math.pow(v - 0.32, 2));
      if (sun < 0.12) return (250, 196, 60, 255);
      final hill = 0.62 + 0.08 * math.sin(u * 9);
      if (v > hill) return (46, 120, 88, 255);
      return (70 + (v * 90).round(), 130 + (v * 60).round(), 200, 255);
    });

    // A scorch: black at the heart, soft and ragged at the edge. Almost all
    // of it is partly transparent, which is what premultiplying is for.
    _scorch = await paint('scorch.png', (u, v) {
      final dx = u - 0.5, dy = v - 0.5;
      final r = math.sqrt(dx * dx + dy * dy) * 2;
      final ragged = 0.08 * math.sin(math.atan2(dy, dx) * 7);
      final a = 1 - smooth(0.35 + ragged, 0.95 + ragged, r);
      return (18, 14, 10, (a * 235).round());
    });

    // A puddle: a white mask with a soft rim. The colour and the roughness
    // come from the decal, not the picture.
    _puddle = await paint('puddle.png', (u, v) {
      final dx = (u - 0.5) * 2, dy = (v - 0.5) * 2;
      final r = math.sqrt(dx * dx + dy * dy) + 0.06 * math.sin(u * 17 + v * 5);
      return (255, 255, 255, ((1 - smooth(0.7, 0.95, r)) * 255).round());
    });

    // Hazard stripes, the kind painted along a loading bay's wall.
    _stripes = await paint('stripes.png', (u, v) {
      final band = ((u * 6 + v * 2) % 1) < 0.5;
      return band ? (236, 184, 30, 255) : (24, 22, 20, 255);
    });

    // A splash of paint: a star, solid inside and gone outside.
    _splash = await paint('splash.png', (u, v) {
      final dx = u - 0.5, dy = v - 0.5;
      final r = math.sqrt(dx * dx + dy * dy) * 2;
      final spikes = 0.62 + 0.25 * math.cos(math.atan2(dy, dx) * 5);
      final a = 1 - smooth(spikes - 0.04, spikes + 0.02, r);
      return (214, 48, 150, (a * 255).round());
    });
  }

  Future<String?> _write(
    Directory directory,
    String name,
    Uint8List pixels,
    int size,
  ) async {
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      size,
      size,
      ui.PixelFormat.rgba8888,
      done.complete,
    );
    final image = await done.future;
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (bytes == null) return null;
    final file = File('${directory.path}/$name');
    await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    return file.path;
  }

  /// A box the built-in cube makes, given its full size rather than the
  /// cube's half-extent.
  OrbisObject _box(
    int key,
    Vector3 at,
    Vector3 size,
    Color colour, {
    int layer = 0,
  }) => OrbisObject(
    key: key,
    transform: Matrix4.identity()
      ..setTranslation(at)
      ..scaleByDouble(size.x / 2, size.y / 2, size.z / 2, 1),
    colour: linearOf(colour),
    castShadows: true,
    layer: layer,
  );

  OrbisTexture? _picture(String? path) =>
      path == null ? null : OrbisTexture(path);

  /// Every decal in the scene, in the order [only] counts them.
  List<OrbisDecal> get _decals {
    final fadeStart = angleFade
        ? OrbisDecal.defaultFadeStart
        : OrbisDecal.noFade;
    final fadeEnd = angleFade ? OrbisDecal.defaultFadeEnd : OrbisDecal.noFade;
    // A quarter turn about x throws a decal along minus z: onto the wall,
    // which faces the camera.
    final ontoWall = Quaternion.axisAngle(Vector3(1, 0, 0), math.pi / 2);

    return [
      OrbisDecal(
        key: 101,
        position: Vector3(-1.6, 2.1, -2.9),
        rotation: ontoWall,
        size: Vector3(1.6, 0.4, 2.2),
        texture: _picture(_poster),
        opacity: opacity,
        fadeStartAngle: fadeStart,
        fadeEndAngle: fadeEnd,
      ),
      OrbisDecal(
        key: 102,
        position: Vector3(-1.3, 0, 1.0),
        size: Vector3(2.0, 0.4, 2.0),
        texture: _picture(_scorch),
        opacity: opacity,
        fadeStartAngle: fadeStart,
        fadeEndAngle: fadeEnd,
        // Charred wood is rough; a scorch on a polished floor kills its
        // shine as well as darkening it.
        roughness: 0.95,
      ),
      OrbisDecal(
        key: 103,
        position: Vector3(0.6, 0, 2.2),
        size: Vector3(2.6, 0.3, 1.5),
        texture: _picture(_puddle),
        colour: Vector3(0.05, 0.06, 0.07),
        opacity: opacity * 0.85,
        fadeStartAngle: fadeStart,
        fadeEndAngle: fadeEnd,
        // A puddle is mostly this: water is nearly a mirror.
        roughness: 0.04,
      ),
      // Straddling the corner: the box reaches down into the floor and up
      // the wall. Thrown downwards, it belongs on the floor — the wall is
      // edge-on to it, which is what the angle fade is for.
      OrbisDecal(
        key: 104,
        position: Vector3(1.2, 0.3, -2.5),
        size: Vector3(3.2, 1.2, 1.0),
        texture: _picture(_stripes),
        opacity: opacity,
        fadeStartAngle: fadeStart,
        fadeEndAngle: fadeEnd,
        // Over the floor paint that might be under it.
        sortOrder: 1,
      ),
      // Across the crate, which is on layer one.
      OrbisDecal(
        key: 105,
        position: Vector3(2.4, 0.6, 0.4),
        size: Vector3(2.6, 1.6, 2.6),
        texture: _picture(_splash),
        opacity: opacity,
        fadeStartAngle: fadeStart,
        fadeEndAngle: fadeEnd,
        layers: spareTheCrate ? {0} : null,
      ),
    ];
  }

  @override
  OrbisScene scene(OrbisCamera camera, double seconds) {
    final all = _decals;
    final shown = !on
        ? const <OrbisDecal>[]
        : only == null
        ? all
        : [all[only!.clamp(0, all.length - 1)]];

    return OrbisScene(
      objects: [
        _box(
          _floor,
          Vector3(0, -0.05, 0),
          Vector3(12, 0.1, 12),
          const Color(0xFFB8B2A6),
        ),
        _box(
          _wall,
          Vector3(0, 2, -3),
          Vector3(12, 4, 0.2),
          const Color(0xFFD6D0C4),
        ),
        _box(
          _crate,
          Vector3(2.4, 0.5, 0.4),
          Vector3(1, 1, 1),
          const Color(0xFF9C7A52),
          layer: 1,
        ),
      ],
      decals: shown,
      lights: [
        // Low and from the side, so the crate's shadow falls across the
        // splash and the puddle has a sun to reflect.
        OrbisLight(
          key: 1,
          kind: OrbisLightKind.directional,
          intensity: 90000,
          direction: Vector3(-0.55, -0.6, -0.58),
          colour: linearOf(const Color(0xFFFFF1DD)),
        ),
      ],
      sky: OrbisSky(colour: linearOf(const Color(0xFF8FA6C0)), ambient: 18000),
      camera: camera,
    );
  }

  @override
  Widget settings(BuildContext context, VoidCallback changed) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Toggle(
        label: 'Decals',
        value: on,
        onChanged: (value) {
          on = value;
          changed();
        },
      ),
      Toggle(
        label: 'Angle fade',
        value: angleFade,
        note: angleFade
            ? 'The hazard stripe stays on the floor.'
            : 'The stripe runs down the wall it straddles.',
        onChanged: (value) {
          angleFade = value;
          changed();
        },
      ),
      Toggle(
        label: 'Spare the crate',
        value: spareTheCrate,
        note: spareTheCrate
            ? 'The paint names layer nought; the crate is on layer one.'
            : 'The paint reaches every layer, the crate included.',
        onChanged: (value) {
          spareTheCrate = value;
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
    ],
  );

  @override
  String get code => '''
// A poster: a box whose own y is the way it is thrown. A quarter turn about
// x throws it along minus z, onto a wall facing the camera. The box's x and
// z are the picture's width and height; its y is how deep it reaches.
OrbisDecal(
  key: 101,
  position: Vector3(-1.6, 2.1, -2.9),
  rotation: Quaternion.axisAngle(Vector3(1, 0, 0), math.pi / 2),
  size: Vector3(1.6, 0.4, 2.2),
  texture: OrbisTexture('/path/poster.png'),
)

// A puddle: mostly a colour and a roughness. Painted before the floor is
// lit, so it reflects the sun where the dry floor round it does not.
OrbisDecal(
  key: 103,
  position: Vector3(0.6, 0, 2.2),
  size: Vector3(2.6, 0.3, 1.5),
  texture: OrbisTexture('/path/puddle.png'),
  colour: Vector3(0.05, 0.06, 0.07),
  roughness: 0.04,
)

// Paint that leaves anything on layer one alone.
OrbisDecal(
  key: 105,
  position: Vector3(2.4, 0.6, 0.4),
  size: Vector3(2.6, 1.6, 2.6),
  texture: OrbisTexture('/path/splash.png'),
  layers: {0},
)

// Past thirty-two in one scene, the rest are reported rather than painted.
''';
}
