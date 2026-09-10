import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart';

/// The outline as it leaves Dart: which keys, in what order, and the row of
/// settings the renderer reads by position.
void main() {
  OrbisScene sceneWith(OrbisOutline? outline) => OrbisScene(
    objects: [
      OrbisObject(
        key: 1,
        transform: Matrix4.identity(),
        colour: Vector3.all(1),
      ),
      OrbisObject(
        key: 2,
        transform: Matrix4.identity(),
        colour: Vector3.all(1),
      ),
    ],
    camera: OrbisCamera(position: Vector3(0, 0, 5), target: Vector3.zero()),
    outline: outline,
  );

  group('nothing outlined', () {
    test('is what a scene has until somebody says otherwise', () {
      final scene = sceneWith(null);
      expect(scene.outline.isEmpty, isTrue);
      final message = scene.toMessage(0);
      expect(message['outlineKeys'], isA<Int64List>());
      expect(message['outlineKeys'] as Int64List, isEmpty);
    });

    test('still sends a whole row of settings, so the plugin never reads '
        'one short', () {
      final params = sceneWith(null).toMessage(0)['outlineParams'];
      expect(params, isA<Float32List>());
      expect((params as Float32List).length, OrbisOutline.stride);
      // No active object: nought at the front are active.
      expect(params[12], 0);
    });
  });

  group('the keys', () {
    test('put the active object first, and only once', () {
      const outline = OrbisOutline(keys: {3, 7, 9}, primary: 7);
      expect(outline.packedKeys, [7, 3, 9]);
      expect(outline.packed[12], 1);
    });

    test('outline an active object that is not in the set', () {
      const outline = OrbisOutline(primary: 4);
      expect(outline.isEmpty, isFalse);
      expect(outline.packedKeys, [4]);
      expect(outline.packed[12], 1);
    });

    test('have no active object unless one is named', () {
      const outline = OrbisOutline(keys: {5, 6});
      expect(outline.packedKeys, [5, 6]);
      expect(outline.packed[12], 0);
    });
  });

  group('the settings', () {
    test('are packed in the order the renderer reads them', () {
      const outline = OrbisOutline(
        keys: {1},
        colour: Color(0xFF00FF00),
        primaryColour: Color(0x80FF0000),
        width: 3,
        occluded: OrbisOccluded.faint,
        occludedOpacity: 0.25,
        dash: 5,
      );
      final packed = outline.packed;
      expect(packed.sublist(0, 4), [0, 1, 0, 1]);
      expect(packed[4], 1);
      expect(packed[5], 0);
      expect(packed[6], 0);
      expect(packed[7], closeTo(128 / 255, 1e-6));
      expect(packed[8], 3);
      expect(packed[9], OrbisOccluded.faint.index);
      expect(packed[10], 0.25);
      expect(packed[11], 5);
    });

    test('hold the width to what the renderer can draw', () {
      expect(const OrbisOutline(width: 400).packed[8], OrbisOutline.maxWidth);
      expect(const OrbisOutline(width: -2).packed[8], 0);
    });

    test('number the hidden styles as the renderer does', () {
      // Shown, faint, dashed, hidden: 0 to 3 in OrbisOutline.h. A reordering
      // here would draw a hidden edge in the wrong style with no error.
      expect(OrbisOccluded.values.map((one) => one.name), [
        'shown',
        'faint',
        'dashed',
        'hidden',
      ]);
    });
  });

  test('survives copyWith on the scene, and can be replaced by it', () {
    final scene = sceneWith(const OrbisOutline(keys: {1}));
    expect(scene.copyWith(sky: OrbisSky()).outline.keys, {1});
    final replaced = scene.copyWith(outline: const OrbisOutline(primary: 2));
    expect(replaced.outline.packedKeys, [2]);
  });

  test('copyWith can take the active object away', () {
    const outline = OrbisOutline(keys: {1, 2}, primary: 2);
    expect(outline.copyWith(clearPrimary: true).primary, isNull);
    expect(outline.copyWith(width: 4).primary, 2);
  });
}
