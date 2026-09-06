import 'package:orbis_mesh/orbis_mesh.dart';
import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  /// Whether every face points away from the middle of the shape.
  ///
  /// The one property that matters and is easy to get wrong: a face wound the
  /// other way is invisible from outside, and a shape with one of them looks
  /// like it has a hole in it.
  bool facesOutwards(Mesh mesh, {Vector3? about}) {
    final box = mesh.bounds;
    final centre = about ?? (box.min + box.max) / 2;

    for (final face in mesh.faces) {
      final outwards = mesh.centreOf(face) - centre;
      if (outwards.length < 1e-9) continue;
      if (mesh.normalOf(face).dot(outwards) <= 0) return false;
    }
    return true;
  }

  group('every shape', () {
    test('is built, and has faces with at least three corners', () {
      for (final kind in ShapeKind.values) {
        final mesh = Shape(kind: kind).build();
        expect(mesh.faces, isNotEmpty, reason: kind.name);
        for (final face in mesh.faces) {
          expect(face.vertices.length, greaterThanOrEqualTo(3),
              reason: kind.name);
        }
      }
    });

    test('names points that exist', () {
      for (final kind in ShapeKind.values) {
        final mesh = Shape(kind: kind).build();
        for (final face in mesh.faces) {
          for (final index in face.vertices) {
            expect(index, inInclusiveRange(0, mesh.positions.length - 1),
                reason: kind.name);
          }
        }
      }
    });

    test('has no face with a corner used twice', () {
      for (final kind in ShapeKind.values) {
        final mesh = Shape(kind: kind).build();
        for (final face in mesh.faces) {
          expect(face.vertices.toSet(), hasLength(face.vertices.length),
              reason: kind.name);
        }
      }
    });

    test('stands on the ground rather than half through it', () {
      for (final kind in ShapeKind.values) {
        final mesh = Shape(kind: kind, height: 2).build();
        // Somebody putting a box in a scene expects it on the floor; a shape
        // centred on its middle sinks half into it.
        expect(mesh.bounds.min.y, closeTo(0, 1e-9), reason: kind.name);
      }
    });

    test('is as big as it was asked to be', () {
      for (final kind in ShapeKind.values) {
        if (kind == ShapeKind.plane) continue;
        final mesh = Shape(kind: kind, width: 3, height: 5, depth: 7).build();
        final box = mesh.bounds;
        expect(box.max.y - box.min.y, closeTo(5, 0.5), reason: kind.name);
      }
    });

    test('survives counts nobody would choose', () {
      // A dragged slider goes through every number on the way to the one
      // somebody wanted, including nought and a hundred thousand.
      for (final kind in ShapeKind.values) {
        for (final sides in [-5, 0, 1, 2, 3, 4096]) {
          final mesh = Shape(
            kind: kind,
            sides: sides,
            rings: sides,
            steps: sides,
          ).build();
          expect(mesh.faces, isNotEmpty, reason: '${kind.name} × $sides');
          expect(mesh.positions.every((at) => at.x.isFinite), isTrue,
              reason: '${kind.name} × $sides');
        }
      }
    });
  });

  group('the box', () {
    test('is six faces over eight corners', () {
      final mesh = Shape(kind: ShapeKind.cube).build();
      expect(mesh.faces, hasLength(6));
      expect(mesh.positions, hasLength(8));
      expect(mesh.faces.every((f) => f.isQuad), isTrue);
    });

    test('faces outwards on every side', () {
      expect(facesOutwards(Shape(kind: ShapeKind.cube).build()), isTrue);
    });

    test('is the size it was given', () {
      final box = Shape(
        kind: ShapeKind.cube,
        width: 4,
        height: 2,
        depth: 6,
      ).build().bounds;

      expect(box.max.x - box.min.x, closeTo(4, 1e-9));
      expect(box.max.y - box.min.y, closeTo(2, 1e-9));
      expect(box.max.z - box.min.z, closeTo(6, 1e-9));
    });
  });

  group('the plane', () {
    test('is one face pointing up', () {
      final mesh = Shape(kind: ShapeKind.plane).build();
      expect(mesh.faces, hasLength(1));
      expect(mesh.normalOf(mesh.faces.single).y, closeTo(1, 1e-9));
    });
  });

  group('the cylinder', () {
    test('has a side per segment, and two ends', () {
      final mesh = Shape(kind: ShapeKind.cylinder, sides: 12).build();
      expect(mesh.faces, hasLength(12 + 2));
    });

    test('without ends it is a tube', () {
      final mesh =
          Shape(kind: ShapeKind.cylinder, sides: 12, capped: false).build();
      expect(mesh.faces, hasLength(12));
      // Every face is on the border, because there are no ends to close it.
      expect(mesh.openFaces, hasLength(12));
    });

    test('faces outwards', () {
      expect(
        facesOutwards(Shape(kind: ShapeKind.cylinder, sides: 16).build()),
        isTrue,
      );
    });

    test('its sides are smooth and its ends are not', () {
      final mesh = Shape(kind: ShapeKind.cylinder, sides: 8).build();
      final smooth = mesh.faces.where((f) => f.smooth).length;

      // A cylinder that shades flat looks like a nut, and ends that shade
      // smooth look like a bulge.
      expect(smooth, 8);
    });
  });

  group('the cone', () {
    test('faces outwards, cap included', () {
      expect(
        facesOutwards(Shape(kind: ShapeKind.cone, sides: 12).build()),
        isTrue,
      );
    });

    test('is a fan of triangles around one tip', () {
      final mesh = Shape(kind: ShapeKind.cone, sides: 9).build();
      expect(mesh.faces.where((f) => f.isTriangle), hasLength(9));
      expect(mesh.positions, hasLength(10));
    });

    test('without a cap it is open underneath', () {
      final mesh =
          Shape(kind: ShapeKind.cone, sides: 9, capped: false).build();
      expect(mesh.faces, hasLength(9));
    });
  });

  group('the sphere', () {
    test('has one point at each pole rather than a ring of them', () {
      final mesh = Shape(kind: ShapeKind.sphere, sides: 8, rings: 4).build();
      // A ring collapsed to a point is a fan of zero-area triangles, each
      // with a normal of nothing.
      expect(mesh.positions, hasLength(8 * 3 + 2));
    });

    test('faces outwards', () {
      expect(
        facesOutwards(Shape(kind: ShapeKind.sphere, sides: 12, rings: 8).build()),
        isTrue,
      );
    });

    test('every point is on the surface', () {
      final mesh = Shape(
        kind: ShapeKind.sphere,
        width: 2,
        height: 2,
        depth: 2,
      ).build();

      for (final at in mesh.positions) {
        final fromCentre = (at - Vector3(0, 1, 0)).length;
        expect(fromCentre, closeTo(1, 1e-9));
      }
    });
  });

  group('the stairs', () {
    test('has a step per flight', () {
      final mesh = Shape(kind: ShapeKind.stairs, steps: 5).build();
      // Six faces a step, since each is a box until somebody welds them.
      expect(mesh.faces, hasLength(5 * 6));
    });

    test('climbs by the height it was given', () {
      final mesh =
          Shape(kind: ShapeKind.stairs, steps: 4, height: 2, depth: 4).build();
      expect(mesh.bounds.max.y, closeTo(2, 1e-9));
      expect(mesh.bounds.max.z - mesh.bounds.min.z, closeTo(4, 1e-9));
    });
  });

  group('the file it is written as', () {
    test('survives a round trip', () {
      final was = Shape(kind: ShapeKind.cube, width: 3).build();
      final now = Mesh.fromJson(was.toJson())!;

      expect(now.faces, hasLength(was.faces.length));
      expect(now.positions.first.x, closeTo(was.positions.first.x, 1e-9));
    });

    test('a face naming a point that is not there is left out', () {
      final mesh = Mesh.fromJson({
        'positions': [0, 0, 0, 1, 0, 0, 0, 1, 0],
        'faces': [
          {'v': [0, 1, 2]},
          {'v': [0, 1, 99]},
        ],
      })!;

      expect(mesh.faces, hasLength(1));
    });

    test('is not read from something that is not one', () {
      expect(Mesh.fromJson('nonsense'), isNull);
      expect(Mesh.fromJson({'faces': []}), isNull);
    });

    test('a shape survives a round trip too', () {
      const was = Shape(kind: ShapeKind.stairs, steps: 12, width: 4);
      final now = Shape.fromJson(was.toJson())!;

      expect(now.kind, ShapeKind.stairs);
      expect(now.steps, 12);
      expect(now.width, 4);
    });
  });
}
