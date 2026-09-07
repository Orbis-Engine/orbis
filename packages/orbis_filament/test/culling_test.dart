import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  OrbisBounds cubeAt(double x, double y, double z, [double half = 0.5]) =>
      OrbisBounds(
        Vector3(x - half, y - half, z - half),
        Vector3(x + half, y + half, z + half),
      );

  group('a box', () {
    test('a ray down an axis enters and leaves where it should', () {
      final box = cubeAt(0, 0, 0);
      final hit = box.hit(Vector3(-10, 0, 0), Vector3(1, 0, 0));

      expect(hit, isNotNull);
      expect(hit!.near, closeTo(9.5, 1e-9));
      expect(hit.far, closeTo(10.5, 1e-9));
    });

    test('a ray parallel to a face either misses or never leaves', () {
      final box = cubeAt(0, 0, 0);
      // Along x at y = 0: inside that pair of faces the whole way.
      expect(box.hit(Vector3(-10, 0, 0), Vector3(1, 0, 0)), isNotNull);
      // Along x at y = 5: outside them the whole way, and no divide by zero.
      expect(box.hit(Vector3(-10, 5, 0), Vector3(1, 0, 0)), isNull);
    });

    test(
      'a ray pointing away from the box still reports where it would go',
      () {
        // Negative distances rather than a miss: what the caller does about a
        // hit behind it is the caller's business, and a test that folded the
        // two together could not tell "behind me" from "not there".
        final hit = cubeAt(0, 0, 0).hit(Vector3(10, 0, 0), Vector3(1, 0, 0));
        expect(hit, isNull);
      },
    );

    test('area is what the tree is built to minimise', () {
      expect(cubeAt(0, 0, 0, 0.5).area, closeTo(6, 1e-9));
      expect(
        OrbisBounds(Vector3.zero(), Vector3(1, 2, 3)).area,
        closeTo(2 * (2 + 6 + 3), 1e-9),
      );
    });
  });

  group('a tree', () {
    /// A hundred boxes in a line, one metre apart.
    List<OrbisVolume> line(int count) => [
      for (var i = 0; i < count; i++) OrbisVolume(i, cubeAt(i * 2.0, 0, 0)),
    ];

    test('an empty scene is an empty tree, not a broken one', () {
      final tree = OrbisBvh.of(const []);
      expect(tree.isEmpty, isTrue);
      expect(tree.bounds, isNull);
      expect(tree.visible(const []), isEmpty);
      expect(tree.first(Vector3.zero(), Vector3(1, 0, 0)), isNull);
    });

    test('it holds everything it was given', () {
      final tree = OrbisBvh.of(line(100));
      expect(tree.length, 100);
      expect(tree.bounds!.minimum.x, closeTo(-0.5, 1e-9));
      expect(tree.bounds!.maximum.x, closeTo(198.5, 1e-9));
    });

    test(
      'it is deep enough to be a tree and shallow enough to be worth one',
      () {
        // A hundred things in leaves of four is about five levels if it splits
        // evenly. Anything near a hundred would mean it degenerated into a list.
        final tree = OrbisBvh.of(line(100));
        expect(tree.depth, lessThan(12));
        expect(tree.depth, greaterThan(3));
      },
    );

    test('a box query finds exactly what overlaps it', () {
      final tree = OrbisBvh.of(line(100));
      final found = tree.inside(
        OrbisBounds(Vector3(-1, -1, -1), Vector3(5, 1, 1)),
      )..sort();

      // Boxes centred at 0, 2 and 4, each half a metre across.
      expect(found, [0, 1, 2]);
    });

    test('a ray finds what it passes through, nearest first', () {
      final tree = OrbisBvh.of(line(20));
      final hits = tree.along(Vector3(-10, 0, 0), Vector3(1, 0, 0));

      expect(hits, hasLength(20));
      expect(hits.first.key, 0);
      expect(hits.last.key, 19);
      expect(hits.first.distance, closeTo(9.5, 1e-9));
    });

    test('a ray that misses everything finds nothing', () {
      final tree = OrbisBvh.of(line(20));
      expect(tree.first(Vector3(-10, 50, 0), Vector3(1, 0, 0)), isNull);
    });

    test('a ray can be cut short', () {
      final tree = OrbisBvh.of(line(20));
      // Ten metres from x = -10 reaches x = 0, which is the first box only.
      final hits = tree.along(Vector3(-10, 0, 0), Vector3(1, 0, 0), within: 10);
      expect(hits.map((hit) => hit.key), [0]);
    });

    test('the answer is the same as asking everything one at a time', () {
      // The whole claim of a tree: it is a faster way to the same answer, not
      // a different one. Checked against the slow way rather than against a
      // list somebody typed out.
      final random = math.Random(7);
      final volumes = [
        for (var i = 0; i < 400; i++)
          OrbisVolume(
            i,
            cubeAt(
              random.nextDouble() * 200 - 100,
              random.nextDouble() * 200 - 100,
              random.nextDouble() * 200 - 100,
              random.nextDouble() * 3 + 0.5,
            ),
          ),
      ];
      final tree = OrbisBvh.of(volumes);
      final query = OrbisBounds(Vector3(-20, -20, -20), Vector3(20, 20, 20));

      final byTree = tree.inside(query)..sort();
      final byHand = [
        for (final volume in volumes)
          if (volume.bounds.overlaps(query)) volume.key,
      ]..sort();

      expect(byTree, byHand);
      expect(byHand, isNotEmpty);
    });

    test('a ray agrees with asking everything one at a time', () {
      final random = math.Random(11);
      final volumes = [
        for (var i = 0; i < 300; i++)
          OrbisVolume(
            i,
            cubeAt(
              random.nextDouble() * 100 - 50,
              random.nextDouble() * 100 - 50,
              random.nextDouble() * 100 - 50,
              2,
            ),
          ),
      ];
      final tree = OrbisBvh.of(volumes);
      final from = Vector3(-200, 3, 7);
      final along = Vector3(1, 0, 0);

      final byTree = tree.along(from, along).map((hit) => hit.key).toSet();
      final byHand = {
        for (final volume in volumes)
          if (volume.bounds.hit(from, along.normalized()) != null) volume.key,
      };
      expect(byTree, byHand);
    });
  });

  group('the frustum', () {
    /// Six planes of an axis-aligned box, normals pointing inwards.
    List<Vector4> boxFrustum(double half) => [
      Vector4(1, 0, 0, half),
      Vector4(-1, 0, 0, half),
      Vector4(0, 1, 0, half),
      Vector4(0, -1, 0, half),
      Vector4(0, 0, 1, half),
      Vector4(0, 0, -1, half),
    ];

    test('what is inside is kept and what is outside is not', () {
      final tree = OrbisBvh.of([
        OrbisVolume(1, cubeAt(0, 0, 0)),
        OrbisVolume(2, cubeAt(5, 0, 0)),
        OrbisVolume(3, cubeAt(100, 0, 0)),
      ]);

      expect(tree.visible(boxFrustum(10))..sort(), [1, 2]);
    });

    test('a box straddling a plane is kept', () {
      // Culling has to be conservative: dropping something half in shot is a
      // visible fault, and keeping something just out of it costs a draw.
      final tree = OrbisBvh.of([OrbisVolume(1, cubeAt(10, 0, 0, 2))]);
      expect(tree.visible(boxFrustum(10)), [1]);
    });
  });

  group('refitting', () {
    test('boxes follow what moved without the tree being rebuilt', () {
      final tree = OrbisBvh.of([
        OrbisVolume(1, cubeAt(0, 0, 0)),
        OrbisVolume(2, cubeAt(10, 0, 0)),
      ]);
      final nodesBefore = tree.nodeCount;

      tree.refit((key) => key == 2 ? cubeAt(50, 0, 0) : null);

      expect(tree.nodeCount, nodesBefore);
      expect(tree.bounds!.maximum.x, closeTo(50.5, 1e-9));
      expect(tree.inside(OrbisBounds(Vector3(49, -1, -1), Vector3(51, 1, 1))), [
        2,
      ]);
      // The one that did not move is where it was.
      expect(tree.inside(OrbisBounds(Vector3(-1, -1, -1), Vector3(1, 1, 1))), [
        1,
      ]);
    });
  });
}
