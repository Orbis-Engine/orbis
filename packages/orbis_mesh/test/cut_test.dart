import 'package:orbis_mesh/orbis_mesh.dart';
import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  /// One square face on the ground, two metres across, facing up.
  Mesh quad() => Mesh(
        positions: [
          Vector3(0, 0, 0),
          Vector3(0, 0, 2),
          Vector3(2, 0, 2),
          Vector3(2, 0, 0),
        ],
        faces: [Face([0, 1, 2, 3])],
      );

  Mesh cube() => Shape.of(ShapeKind.cube).build();

  group('where a point falls', () {
    test('on a corner, on an edge, or in the middle', () {
      final mesh = quad();
      final face = mesh.faces.single;

      expect(mesh.whereOn(face, Vector3(0, 0, 0)), isA<AtCorner>());
      expect((mesh.whereOn(face, Vector3(0, 0, 0)) as AtCorner).corner, 0);
      expect(mesh.whereOn(face, Vector3(1, 0, 0)), isA<AlongEdge>());
      expect(mesh.whereOn(face, Vector3(1, 0, 1)), isA<InsideFace>());
    });

    test('an edge point says which edge and how far along', () {
      final mesh = quad();
      final where = mesh.whereOn(mesh.faces.single, Vector3(0, 0, 0.5))
          as AlongEdge;
      expect(where.corner, 0, reason: 'the edge leaving corner nought');
      expect(where.along, closeTo(0.25, 1e-9));
    });

    test('near enough counts as on', () {
      final mesh = quad();
      // Somebody aiming at an edge and missing by a centimetre means the
      // edge; a cut that landed just inside would leave a sliver.
      expect(mesh.whereOn(mesh.faces.single, Vector3(0.01, 0, 1)),
          isA<AlongEdge>());
      expect(mesh.whereOn(mesh.faces.single, Vector3(0.5, 0, 1)),
          isA<InsideFace>());
    });
  });

  group('cutting across', () {
    test('edge to edge makes two faces out of one', () {
      final mesh = quad();
      final made = mesh.cutFace(mesh.faces.single, [
        Vector3(0, 0, 1),
        Vector3(2, 0, 1),
      ]);

      expect(made, hasLength(2));
      expect(mesh.faceCount, 2);
      expect(mesh.vertexCount, 6, reason: 'a new corner on each edge');
    });

    test('the two halves cover the whole of what they replaced', () {
      final mesh = quad();
      final was = mesh.areaOf(mesh.faces.single);
      mesh.cutFace(mesh.faces.single, [Vector3(0, 0, 1), Vector3(2, 0, 1)]);

      final now = mesh.faces.fold(0.0, (sum, face) => sum + mesh.areaOf(face));
      expect(now, closeTo(was, 1e-9), reason: 'a cut divides, it does not eat');
    });

    test('both halves still face the way the face did', () {
      final mesh = quad();
      mesh.cutFace(mesh.faces.single, [Vector3(0, 0, 1), Vector3(2, 0, 1)]);
      for (final face in mesh.faces) {
        expect(mesh.normalOf(face).y, closeTo(1, 1e-9));
      }
    });

    test('corner to corner needs no new vertices', () {
      final mesh = quad();
      final made = mesh.cutFace(mesh.faces.single, [
        Vector3(0, 0, 0),
        Vector3(2, 0, 2),
      ]);

      expect(made, hasLength(2));
      expect(mesh.vertexCount, 4, reason: 'both ends were already corners');
      for (final face in made) {
        expect(face.vertices, hasLength(3), reason: 'two triangles');
      }
    });

    test('a path through the middle keeps its bends', () {
      final mesh = quad();
      final made = mesh.cutFace(mesh.faces.single, [
        Vector3(0, 0, 1),
        Vector3(1, 0, 1.5),
        Vector3(1, 0, 0.5),
        Vector3(2, 0, 1),
      ]);

      expect(made, hasLength(2));
      // Two ends on edges plus two bends, and the bends belong to both halves.
      expect(mesh.vertexCount, 8);
      expect(made.first.vertices.length + made.last.vertices.length, 12,
          reason: 'four corners each side, shared along the cut');
    });

    test('the bends are shared, not duplicated', () {
      final mesh = quad();
      final made = mesh.cutFace(mesh.faces.single, [
        Vector3(0, 0, 1),
        Vector3(1, 0, 1.2),
        Vector3(2, 0, 1),
      ]);
      final shared =
          made.first.vertices.toSet().intersection(made.last.vertices.toSet());
      expect(shared, hasLength(3),
          reason: 'both ends and the bend, or the cut is a crack');
    });

    test('a path that starts inside cuts nothing', () {
      final mesh = quad();
      final made = mesh.cutFace(mesh.faces.single, [
        Vector3(1, 0, 1),
        Vector3(2, 0, 1),
      ]);
      expect(made, isEmpty);
      expect(mesh.faceCount, 1, reason: 'refused, and nothing changed');
    });

    test('a path from an edge back to the same point cuts nothing', () {
      final mesh = quad();
      expect(
        mesh.cutFace(mesh.faces.single, [
          Vector3(0, 0, 1),
          Vector3(0, 0, 1.0001),
        ]),
        isEmpty,
      );
    });

    test('the new faces keep what the old one wore', () {
      final mesh = quad();
      mesh.faces.single
        ..material = 3
        ..smooth = true
        ..uv = FaceUv(offset: Vector2(0.5, 0));

      final made = mesh.cutFace(mesh.faces.single, [
        Vector3(0, 0, 1),
        Vector3(2, 0, 1),
      ]);

      for (final face in made) {
        expect(face.material, 3);
        expect(face.smooth, isTrue);
        expect(face.uv.offset.x, 0.5, reason: 'the rule carries over');
      }
    });

    test('drawn coordinates do not carry over, because their corners are gone',
        () {
      final mesh = quad();
      mesh.faces.single.uv = FaceUv(manual: [
        Vector2(0, 0),
        Vector2(0, 1),
        Vector2(1, 1),
        Vector2(1, 0),
      ]);

      final made = mesh.cutFace(mesh.faces.single, [
        Vector3(0, 0, 1),
        Vector3(2, 0, 1),
      ]);
      for (final face in made) {
        expect(face.uv.isManual, isFalse);
      }
    });

    test('the new faces sit where the old one was in the list', () {
      final mesh = cube();
      final second = mesh.faces[1];
      final points = mesh.pointsOf(second);
      // A cut corner to corner, which needs no positions worked out.
      mesh.cutFace(second, [points[0], points[2]]);

      expect(mesh.faceCount, 7);
      // The faces either side of it are still either side of it.
      expect(mesh.faces[0], isNotNull);
      expect(mesh.faces[3], isNotNull);
    });

    test('a face the mesh does not have is refused', () {
      final mesh = quad();
      final stranger = Face([0, 1, 2]);
      expect(mesh.cutFace(stranger, [Vector3.zero(), Vector3(1, 0, 0)]),
          isEmpty);
    });
  });

  group('cutting a loop inside', () {
    List<Vector3> loop() => [
          Vector3(0.5, 0, 0.5),
          Vector3(0.5, 0, 1.5),
          Vector3(1.5, 0, 1.5),
          Vector3(1.5, 0, 0.5),
          Vector3(0.5, 0, 0.5),
        ];

    test('the loop becomes a face and the rest surrounds it', () {
      final mesh = quad();
      final made = mesh.cutFace(mesh.faces.single, loop());

      expect(made, hasLength(2));
      expect(mesh.faceCount, 2);
      final inner = made.last;
      expect(inner.vertices, hasLength(4));
      expect(mesh.areaOf(inner), closeTo(1, 1e-9));
    });

    test('the inner face points the same way whichever way it was drawn', () {
      for (final drawn in [loop(), loop().reversed.toList()]) {
        final mesh = quad();
        final made = mesh.cutFace(mesh.faces.single, drawn);
        expect(mesh.normalOf(made.last).y, closeTo(1, 1e-9));
      }
    });

    test('what is left has the loop taken out of it', () {
      final mesh = quad();
      final made = mesh.cutFace(mesh.faces.single, loop());
      final ring = made.first;

      // Four outer corners, four inner, and each end of the slit said twice.
      expect(ring.vertices, hasLength(10));
      // Area is the square less the loop, which is what "taken out" means.
      expect(mesh.areaOf(ring), closeTo(4 - 1, 1e-6));
    });

    test('the ring and the inner face share no corners', () {
      final mesh = quad();
      final made = mesh.cutFace(mesh.faces.single, loop());
      expect(
        made.first.vertices.toSet().intersection(made.last.vertices.toSet()),
        isEmpty,
        reason: 'they meet along the slit, they are not joined there',
      );
    });

    test('a loop of two points is not a loop', () {
      final mesh = quad();
      expect(
        mesh.cutFace(mesh.faces.single, [
          Vector3(1, 0, 1),
          Vector3(1, 0, 1),
        ]),
        isEmpty,
      );
    });
  });

  group('the helpers', () {
    test('a point inside a concave outline is found', () {
      // An L, where a bounding box would say yes to the corner that is out.
      final outline = [
        Vector2(0, 0),
        Vector2(2, 0),
        Vector2(2, 1),
        Vector2(1, 1),
        Vector2(1, 2),
        Vector2(0, 2),
      ];
      expect(pointInsideOutline(outline, Vector2(0.5, 0.5)), isTrue);
      expect(pointInsideOutline(outline, Vector2(1.5, 1.5)), isFalse);
      expect(pointInsideOutline(outline, Vector2(3, 3)), isFalse);
    });

    test('flattening keeps the shape of a face', () {
      final mesh = quad();
      final face = mesh.faces.single;
      final flat = flattenFace(mesh.pointsOf(face), mesh.normalOf(face));
      expect(flat.flat, hasLength(4));
      // A two-metre square is a two-metre square whichever plane it is on.
      final xs = [for (final at in flat.flat) at.x];
      xs.sort();
      expect(xs.last - xs.first, closeTo(2, 1e-9));
    });

    test('the sign of a loop area says which way it goes', () {
      final up = Vector3(0, 1, 0);
      final square = [
        Vector3(0, 0, 0),
        Vector3(0, 0, 1),
        Vector3(1, 0, 1),
        Vector3(1, 0, 0),
      ];
      expect(signedLoopArea(square, up), greaterThan(0));
      expect(signedLoopArea(square.reversed.toList(), up), lessThan(0));
    });
  });
}
