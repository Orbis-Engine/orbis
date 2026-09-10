import 'package:flutter/material.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../example.dart';
import 'surface.dart' show linearOf;

/// A line round what is selected, following its shape.
///
/// What an editor shows its selection with, and the thing a box drawn over
/// the picture cannot do: a box does not know what is in front of what. Here
/// the active object — the one an inspector would be showing — stands half
/// behind a wall, and its hidden half is still outlined, fainter and dashed,
/// so it can be found without being mistaken for something in front.
///
/// Worth trying: turn the outline off and nothing about the frame changes,
/// because the renderer skips every pass of it. Widen it and the cost barely
/// moves, because the edge is found a row and then a column at a time rather
/// than by searching a disc round every pixel.
class OutlineExample extends Example {
  OutlineExample();

  @override
  String get name => 'Outline';

  @override
  String get blurb =>
      'A selection outline that follows the silhouette, and still finds an '
      'object hidden behind a wall.';

  @override
  ViewPoint get viewpoint =>
      const ViewPoint(yaw: 0.35, pitch: 0.32, distance: 11, height: 0.4);

  /// Whether anything is outlined at all.
  bool on = true;

  /// Whether the box beside the wall is selected too, as well as the one
  /// behind it.
  bool others = true;

  /// In pixels.
  double width = 3;

  /// What becomes of the part the wall hides.
  OrbisOccluded occluded = OrbisOccluded.dashed;

  /// How the frame underneath is anti-aliased. The outline is drawn after
  /// all of them, so switching this changes the objects' edges and leaves
  /// the outline exactly where it was — which is the point of drawing it
  /// last: under temporal anti-aliasing an outline fed into the history would
  /// shimmer every time the camera moved.
  AntiAliasing antiAliasing = AntiAliasing.temporal;

  static const int _floor = 1;
  static const int _wall = 2;
  static const int _behind = 3;
  static const int _beside = 4;
  static const int _sphere = 5;

  OrbisObject _box(int key, Vector3 at, Vector3 size, Color colour) =>
      OrbisObject(
        key: key,
        transform: Matrix4.identity()
          ..setTranslation(at)
          ..scaleByDouble(size.x, size.y, size.z, 1),
        colour: linearOf(colour),
      );

  @override
  OrbisScene scene(OrbisCamera camera, double seconds) => OrbisScene(
    objects: [
      _box(
        _floor,
        Vector3(0, -1.1, 0),
        Vector3(7, 0.1, 7),
        const Color(0xFF8A8F96),
      ),
      // The wall: in front of the active object, hiding its left half.
      _box(
        _wall,
        Vector3(-0.9, 0.2, 1.2),
        Vector3(1.4, 1.2, 0.12),
        const Color(0xFFB9B2A6),
      ),
      // The active object, behind the wall.
      _box(
        _behind,
        Vector3(0, 0, -0.6),
        Vector3(0.9, 0.9, 0.9),
        const Color(0xFF4F7FB8),
      ),
      // The rest of the selection, in plain view.
      _box(
        _beside,
        Vector3(2.4, -0.4, 0.6),
        Vector3(0.5, 0.6, 0.5),
        const Color(0xFFB85F4F),
      ),
      // Not selected: something for the eye to compare against.
      _box(
        _sphere,
        Vector3(-2.6, -0.5, -0.8),
        Vector3(0.5, 0.5, 0.5),
        const Color(0xFF6FA06A),
      ),
    ],
    lights: [
      OrbisLight(
        key: 1,
        kind: OrbisLightKind.directional,
        direction: Vector3(-0.4, -0.8, -0.45)..normalize(),
        colour: Vector3(1, 0.96, 0.9),
        intensity: 90000,
        castShadows: true,
      ),
    ],
    sky: OrbisSky(
      zenith: Vector3(0.30, 0.50, 0.78),
      horizon: Vector3(0.72, 0.84, 0.94),
      ambient: 24000,
    ),
    camera: camera,
    post: OrbisPostProcess(antiAliasing: antiAliasing),
    outline: on
        ? OrbisOutline(
            primary: _behind,
            keys: {if (others) _beside},
            width: width,
            occluded: occluded,
          )
        : OrbisOutline.none,
  );

  @override
  Widget settings(BuildContext context, VoidCallback changed) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Toggle(
        label: 'Outline',
        value: on,
        onChanged: (value) {
          on = value;
          changed();
        },
      ),
      Toggle(
        label: 'Select the second box too',
        value: others,
        note: 'Drawn in the deeper orange: selected, but not the active one.',
        onChanged: (value) {
          others = value;
          changed();
        },
      ),
      Setting(
        label: 'Width',
        value: width,
        min: 1,
        max: OrbisOutline.maxWidth,
        unit: ' px',
        decimals: 0,
        onChanged: (value) {
          width = value.roundToDouble();
          changed();
        },
      ),
      Choice(
        label: 'Behind the wall',
        options: [for (final style in OrbisOccluded.values) style.name],
        selected: occluded.name,
        onSelect: (value) {
          occluded = OrbisOccluded.values.byName(value);
          changed();
        },
      ),
      Choice(
        label: 'Anti-aliasing underneath',
        options: [for (final one in AntiAliasing.values) one.label],
        selected: antiAliasing.label,
        onSelect: (value) {
          antiAliasing = AntiAliasing.values.firstWhere(
            (one) => one.label == value,
          );
          changed();
        },
      ),
    ],
  );

  @override
  String get code => '''
// The outline is on the scene, not on the objects: it is about how the
// world is being looked at, and an editor changes it on every click
// without touching a single object.
OrbisScene(
  objects: objects,
  camera: camera,
  outline: OrbisOutline(
    // The active object, in the lighter orange.
    primary: behindTheWall.key,
    // Everything else selected, in the deeper one.
    keys: {besideIt.key},
    width: 3,
    // What the wall hides is still outlined — fainter, and dashed, so it
    // reads as behind rather than in front.
    occluded: OrbisOccluded.dashed,
  ),
)

// Colours are Flutter Colors — display colours — because the outline is
// drawn after tone mapping and lands on screen as exactly what was asked
// for. OrbisOutline.none, the default, draws nothing and costs nothing.
''';
}
