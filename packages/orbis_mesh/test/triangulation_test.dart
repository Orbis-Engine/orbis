import 'dart:math' as math;

import 'package:orbis_mesh/orbis_mesh.dart';
import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  /// An L, which is the shape of the commonest room somebody draws and the
  /// simplest thing a fan gets wrong.
  List<Vector3> ell() => [
    Vector3(0, 0, 0),
    Vector3(0, 0, 3),
    Vector3(2, 0, 3),
    Vector3(2, 0, 1),
    Vector3(4, 0, 1),
    Vector3(4, 0, 0),
  ];

  /// The area of the triangles a face is cut into.
  double areaOfPieces(List<Vector3> points, List<int> corners) {
    var total = 0.0;
    for (var i = 0; i + 2 < corners.length; i += 3) {
      final a = points[corners[i]];
      final b = points[corners[i + 1]];
      final c = points[corners[i + 2]];
      total += (b - a).cross(c - a).length / 2;
    }
    return total;
  }

  test('a triangle is itself', () {
    expect(cutUp(ell().take(3).toList(), Vector3(0, 1, 0)), [0, 1, 2]);
  });

  test('under three corners there is nothing to cut', () {
    expect(cutUp(const [], Vector3(0, 1, 0)), isEmpty);
    expect(cutUp(ell().take(2).toList(), Vector3(0, 1, 0)), isEmpty);
  });

  test('a square comes out as two triangles', () {
    final square = [
      Vector3(0, 0, 0),
      Vector3(0, 0, 1),
      Vector3(1, 0, 1),
      Vector3(1, 0, 0),
    ];
    expect(cutUp(square, Vector3(0, 1, 0)), hasLength(6));
  });

  test('a concave face is cut into pieces that cover exactly it', () {
    final points = ell();
    final corners = cutUp(points, Vector3(0, 1, 0));

    expect(corners, hasLength((points.length - 2) * 3));
    // A four-by-one strip and a two-by-two block: eight. A fan over this
    // gives more, because its triangles overlap outside the outline.
    expect(areaOfPieces(points, corners), closeTo(8, 1e-9));
  });

  test('every piece is wound the same way as the face', () {
    final points = ell();
    final corners = cutUp(points, Vector3(0, 1, 0));

    for (var i = 0; i + 2 < corners.length; i += 3) {
      final a = points[corners[i]];
      final b = points[corners[i + 1]];
      final c = points[corners[i + 2]];
      expect(
        (b - a).cross(c - a).y,
        greaterThan(0),
        reason: 'a piece facing the other way is a hole',
      );
    }
  });

  test('it works the other way round too', () {
    final points = ell().reversed.toList();
    final corners = cutUp(points, Vector3(0, -1, 0));
    expect(areaOfPieces(points, corners), closeTo(8, 1e-9));
    for (var i = 0; i + 2 < corners.length; i += 3) {
      final a = points[corners[i]];
      final b = points[corners[i + 1]];
      final c = points[corners[i + 2]];
      expect((b - a).cross(c - a).y, lessThan(0));
    }
  });

  test('a keyhole outline is cut without overlapping', () {
    // What a loop cut leaves: round the outside, in through a slit, round the
    // inside, and back out. Very concave, and the case a fan is worst at.
    final mesh = Mesh(
      positions: [
        Vector3(0, 0, 0),
        Vector3(0, 0, 4),
        Vector3(4, 0, 4),
        Vector3(4, 0, 0),
      ],
      faces: [
        Face([0, 1, 2, 3]),
      ],
    );
    mesh.cutFace(mesh.faces.single, [
      Vector3(1, 0, 1),
      Vector3(1, 0, 3),
      Vector3(3, 0, 3),
      Vector3(3, 0, 1),
      Vector3(1, 0, 1),
    ]);

    final ring = mesh.faces.first;
    final corners = cutUp(mesh.pointsOf(ring), mesh.normalOf(ring));
    expect(
      areaOfPieces(mesh.pointsOf(ring), corners),
      closeTo(16 - 4, 1e-6),
      reason: 'the square less the hole, and nothing counted twice',
    );
  });

  test('a face that crosses itself still produces triangles', () {
    // A figure of eight has no ears at all. The answer is wrong — there is no
    // right one — but it is visible, and it is not a spin or a crash.
    final crossed = [
      Vector3(0, 0, 0),
      Vector3(2, 0, 2),
      Vector3(2, 0, 0),
      Vector3(0, 0, 2),
    ];
    final corners = cutUp(crossed, Vector3(0, 1, 0));
    expect(corners, isNotEmpty);
    expect(corners.length % 3, 0);
  });

  test('a face with no area does not spin', () {
    final flat = [
      Vector3(0, 0, 0),
      Vector3(1, 0, 0),
      Vector3(2, 0, 0),
      Vector3(3, 0, 0),
    ];
    expect(cutUp(flat, Vector3(0, 1, 0)).length % 3, 0);
  });

  test('a drawn room is drawn as the room it is', () {
    final room = PolyShape(points: ell(), height: 2).build();
    final tris = room.triangulate();

    // The two caps are six corners each and cut into four; the six walls are
    // quads and cut into two.
    expect(tris.triangleCount, 4 + 4 + 6 * 2);

    // And the whole surface adds up to the walls plus both caps.
    var total = 0.0;
    for (var i = 0; i < tris.triangleCount; i++) {
      Vector3 corner(int at) => Vector3(
        tris.positions[tris.indices[at] * 3],
        tris.positions[tris.indices[at] * 3 + 1],
        tris.positions[tris.indices[at] * 3 + 2],
      );
      final a = corner(i * 3);
      final b = corner(i * 3 + 1);
      final c = corner(i * 3 + 2);
      total += (b - a).cross(c - a).length / 2;
    }
    // Eight a cap, and the walls: 3 + 2 + 2 + 2 + 1 + 4 metres round, two
    // high.
    expect(total, closeTo(8 * 2 + 14 * 2, 1e-6));
  });

  test('the pieces still index the corners the face has', () {
    final points = ell();
    for (final corner in cutUp(points, Vector3(0, 1, 0))) {
      expect(corner, inInclusiveRange(0, points.length - 1));
    }
    expect(math.min(0, 0), 0);
  });
}
