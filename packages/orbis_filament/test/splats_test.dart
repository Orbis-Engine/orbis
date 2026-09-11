import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart';

/// Gaussian splats as they cross to the renderer: the compact records a cloud
/// made in Dart is packed into, and the message that carries clouds.
///
/// The records are read on the far side by the same C++ that reads a `.splat`
/// file, so the layout here has to be that file's layout byte for byte.
void main() {
  OrbisScene sceneWith(List<OrbisSplats> splats) => OrbisScene(
    objects: const [],
    splats: splats,
    camera: OrbisCamera(position: Vector3(0, 0, 5), target: Vector3.zero()),
  );

  Uint8List two() => OrbisSplats.pack(
    positions: Float32List.fromList([1, 2, 3, -4, 5, -6]),
    scales: Float32List.fromList([0.1, 0.2, 0.3, 1, 1, 1]),
    colours: Float32List.fromList([1, 0.5, 0, 0.25, 0, 0, 0, 1]),
    rotations: Float32List.fromList([1, 0, 0, 0, 0, 0, 0, 2]),
  );

  group('packing', () {
    test('is thirty-two bytes a splat, in the .splat layout', () {
      final bytes = two();
      expect(bytes.length, 2 * OrbisSplats.recordBytes);

      final floats = Float32List.view(bytes.buffer);
      expect(floats.sublist(0, 6), [
        1,
        2,
        3,
        closeTo(0.1, 1e-6),
        closeTo(0.2, 1e-6),
        closeTo(0.3, 1e-6),
      ]);
      expect(floats.sublist(8, 11), [-4, 5, -6]);

      // Colour as bytes, alpha as the splat's peak opacity.
      expect(bytes.sublist(24, 28), [255, 128, 0, 64]);
      expect(bytes.sublist(56, 60), [0, 0, 0, 255]);
    });

    test('quantises a unit quaternion as v * 128 + 128', () {
      final bytes = two();
      // The identity: w of one saturates at 255, the rest are the middle.
      expect(bytes.sublist(28, 32), [255, 128, 128, 128]);
      // Normalised first: (0, 0, 0, 2) is a half turn about z.
      expect(bytes.sublist(60, 64), [128, 128, 128, 255]);
    });

    test('with no rotations is the identity', () {
      final bytes = OrbisSplats.pack(
        positions: Float32List(3),
        scales: Float32List.fromList([1, 1, 1]),
        colours: Float32List(4),
      );
      expect(bytes.sublist(28, 32), [255, 128, 128, 128]);
    });
  });

  group('the message', () {
    test('says nothing about splats when there are none', () {
      final message = sceneWith(const []).toMessage(1);
      expect(message.containsKey('splatKeys'), isFalse);
    });

    test('carries an in-memory cloud until the renderer has it', () {
      final cloud = OrbisSplats(key: 7, data: two(), revision: 3);
      final first = sceneWith([cloud]).toMessage(1);
      expect(first['splatKeys'], [7]);
      expect(first['splatRevisions'], [3]);
      expect(first['splatChanged'], [7]);
      expect(first['splatChangedCounts'], [2]);
      expect((first['splatData']! as Uint8List).length, 64);

      final again = sceneWith([cloud]).toMessage(1, sentSplatRevisions: {7: 3});
      expect(again['splatKeys'], [7]);
      expect(again['splatChanged'], isEmpty);
      expect((again['splatData']! as Uint8List).length, 0);

      final moved = sceneWith([cloud]).toMessage(1, sentSplatRevisions: {7: 2});
      expect(moved['splatChanged'], [7]);
    });

    test('sends a file by its path and no records', () {
      final message = sceneWith([
        OrbisSplats(key: 1, path: '/captures/garden.ply'),
      ]).toMessage(1);
      expect(message['splatPaths'], ['/captures/garden.ply']);
      expect(message['splatChanged'], isEmpty);
    });

    test('packs the transform, opacity and brightness at the stride', () {
      final message = sceneWith([
        OrbisSplats(key: 1, path: 'a.splat'),
        OrbisSplats(
          key: 2,
          path: 'b.splat',
          transform: Matrix4.translationValues(4, 5, 6),
          opacity: 0.5,
          brightness: 2,
          sorted: false,
        ),
      ]).toMessage(1);
      final params = message['splatParams']! as Float32List;
      expect(params.length, 2 * OrbisSplats.stride);
      const second = OrbisSplats.stride;
      expect(params.sublist(second + 12, second + 15), [4, 5, 6]);
      expect(params[second + 16], 0.5);
      expect(params[second + 17], 2);
      // Sorted and read to degree two, then unsorted and read to degree two.
      expect(message['splatFlags'], [5, 4]);
    });
  });

  group('the flags', () {
    test('carry the sort in the low bit and the degree above it', () {
      expect(OrbisSplats(key: 1, path: 'a.ply').flags, 1 | (2 << 1));
      expect(OrbisSplats(key: 1, path: 'a.ply', harmonics: 0).flags, 1);
      expect(
        OrbisSplats(key: 1, path: 'a.ply', harmonics: 1).flags,
        1 | (1 << 1),
      );
      expect(
        OrbisSplats(key: 1, path: 'a.ply', sorted: false, harmonics: 3).flags,
        3 << 1,
      );
    });

    test('refuse a degree no capture is trained to', () {
      expect(
        () => OrbisSplats(key: 1, path: 'a.ply', harmonics: 4),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => OrbisSplats(key: 1, path: 'a.ply', harmonics: -1),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  test('a cloud is a file or a set of records, never both', () {
    expect(
      () => OrbisSplats(key: 1, path: 'a.ply', data: Uint8List(32)),
      throwsA(isA<AssertionError>()),
    );
    expect(() => OrbisSplats(key: 1), throwsA(isA<AssertionError>()));
  });
}
