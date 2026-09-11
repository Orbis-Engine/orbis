import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart';

OrbisScene _scene(List<OrbisDecal> decals) => OrbisScene(
  objects: const [],
  camera: OrbisCamera(position: Vector3(0, 0, 5), target: Vector3.zero()),
  decals: decals,
);

void main() {
  group('a decal on the wire', () {
    test('packs every field where the renderer reads it', () {
      final decal = OrbisDecal(
        key: 7,
        position: Vector3(1, 2, 3),
        rotation: Quaternion.axisAngle(Vector3(1, 0, 0), math.pi / 2),
        size: Vector3(2, 0.5, 4),
        colour: Vector3(0.1, 0.2, 0.3),
        opacity: 0.75,
        fadeStartAngle: 0.5,
        fadeEndAngle: 1.2,
        roughness: 0.05,
        layers: {0, 2},
        sortOrder: 3,
      );
      final packed = Float32List(OrbisDecal.stride);
      decal.pack(packed, 0);

      expect(packed.sublist(0, 3), [1, 2, 3]);
      final half = math.sqrt(0.5);
      expect(packed[3], closeTo(half, 1e-6));
      expect(packed[6], closeTo(half, 1e-6));
      expect(packed.sublist(7, 10), [2, 0.5, 4]);
      expect(packed[10], closeTo(0.1, 1e-6));
      expect(packed[13], 0.75);
      expect(packed[14], 0.5);
      expect(packed[15], closeTo(1.2, 1e-6));
      // A roughness asked for is painted in full; a metalness not asked for
      // leaves the surface's own alone.
      expect(packed[16], closeTo(0.05, 1e-6));
      expect(packed[17], 1);
      expect(packed[19], 0);
      expect(packed[20], 0x05);
      expect(packed[21], 3);
    });

    test('reaches every layer unless told otherwise', () {
      final everywhere = OrbisDecal(
        key: 1,
        position: Vector3.zero(),
        size: Vector3.all(1),
      );
      expect(everywhere.layerMask, 0x7F);
      final nowhere = OrbisDecal(
        key: 1,
        position: Vector3.zero(),
        size: Vector3.all(1),
        layers: {9, -1},
      );
      expect(nowhere.layerMask, 0, reason: 'layers past six do not exist');
    });

    test('sends each picture once and points at it', () {
      const poster = OrbisTexture('/tmp/poster.png');
      final message = _scene([
        OrbisDecal(
          key: 1,
          position: Vector3.zero(),
          size: Vector3.all(1),
          texture: poster,
        ),
        OrbisDecal(key: 2, position: Vector3.zero(), size: Vector3.all(1)),
        OrbisDecal(
          key: 3,
          position: Vector3.zero(),
          size: Vector3.all(1),
          texture: poster,
        ),
      ]).toMessage(0);

      expect(message['decalPaths'], ['/tmp/poster.png']);
      expect(message['decalImages'], [0, -1, 0]);
      expect(
        (message['decalParams']! as Float32List).length,
        3 * OrbisDecal.stride,
      );
    });

    test('a scene without decals sends empty arrays, not nothing', () {
      final message = _scene(const []).toMessage(0);
      expect(message['decalParams'], isEmpty);
      expect(message['decalImages'], isEmpty);
      expect(message['decalPaths'], isEmpty);
    });

    test('copyWith keeps the decals, and can replace them', () {
      final scene = _scene([
        OrbisDecal(key: 1, position: Vector3.zero(), size: Vector3.all(1)),
      ]);
      expect(scene.copyWith().decals, hasLength(1));
      expect(scene.copyWith(decals: const []).decals, isEmpty);
    });
  });
}
