import 'package:orbis_mesh/orbis_mesh.dart';
import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  Mesh cube() => Shape(kind: ShapeKind.cube).build();

  /// The face pointing up, which is the one worth extruding in a test.
  Face topOf(Mesh mesh) =>
      mesh.faces.firstWhere((f) => mesh.normalOf(f).y > 0.9);

  group('extruding', () {
    test('makes a wall for every edge of the face', () {
      final mesh = cube();
      final top = topOf(mesh);

      mesh.extrude([top], 1);

      // Six faces to begin with, four more round the sides of the extrusion.
      expect(mesh.faces, hasLength(10));
    });

    test('moves the face rather than leaving it behind', () {
      final mesh = cube();
      final top = topOf(mesh);

      mesh.extrude([top], 2);

      // The face itself is the one that moved, so it kept its material and
      // whatever else was on it.
      expect(mesh.centreOf(top).y, closeTo(3, 1e-9));
      expect(mesh.bounds.max.y, closeTo(3, 1e-9));
    });

    test('the new geometry still faces outwards', () {
      final mesh = cube();
      mesh.extrude([topOf(mesh)], 1);

      final centre = (mesh.bounds.min + mesh.bounds.max) / 2;
      for (final face in mesh.faces) {
        final outwards = mesh.centreOf(face) - centre;
        if (outwards.length < 1e-6) continue;
        expect(mesh.normalOf(face).dot(outwards), greaterThan(0));
      }
    });

    test('inwards makes a hole rather than turning the shape inside out', () {
      final mesh = cube();
      final top = topOf(mesh);

      mesh.extrude([top], -0.5);

      expect(mesh.centreOf(top).y, closeTo(0.5, 1e-9));
      expect(mesh.bounds.max.y, closeTo(1, 1e-9));
    });

    test('does not drag the neighbours', () {
      final mesh = cube();
      final bottom = mesh.faces.firstWhere((f) => mesh.normalOf(f).y < -0.9);
      final was = mesh.centreOf(bottom).clone();

      mesh.extrude([topOf(mesh)], 3);

      // Pulling one face copies its corners rather than moving the ones its
      // neighbours are also using.
      expect(mesh.centreOf(bottom).y, closeTo(was.y, 1e-9));
    });

    test('two faces at once are two separate extrusions', () {
      final mesh = cube();
      final top = topOf(mesh);
      final bottom = mesh.faces.firstWhere((f) => mesh.normalOf(f).y < -0.9);

      mesh.extrude([top, bottom], 1);

      expect(mesh.faces, hasLength(14));
      expect(mesh.bounds.max.y, closeTo(2, 1e-9));
      expect(mesh.bounds.min.y, closeTo(-1, 1e-9));
    });

    test('says which faces ended up outside', () {
      final mesh = cube();
      final top = topOf(mesh);

      final after = mesh.extrude([top], 1);

      // Which is what somebody wants selected, because they are usually about
      // to do it again.
      expect(after, [top]);
    });

    test('a face that is not in the mesh is ignored', () {
      final mesh = cube();
      expect(
        mesh.extrude([
          Face([0, 1, 2]),
        ], 1),
        isEmpty,
      );
      expect(mesh.faces, hasLength(6));
    });

    test('nothing extruded changes nothing', () {
      final mesh = cube();
      mesh.extrude([], 5);
      expect(mesh.faces, hasLength(6));
      expect(mesh.positions, hasLength(8));
    });
  });

  group('insetting', () {
    test('leaves a border and keeps the outer edge where it was', () {
      final mesh = cube();
      final top = topOf(mesh);
      final wasWide = mesh.bounds.max.x;

      mesh.inset([top], 0.2);

      expect(mesh.faces, hasLength(10));
      // The shape did not shrink; only the face inside it did.
      expect(mesh.bounds.max.x, closeTo(wasWide, 1e-9));
      expect(mesh.areaOf(top), lessThan(1));
    });

    test('a face smaller than the inset collapses rather than inverting', () {
      final mesh = cube();
      final top = topOf(mesh);

      mesh.inset([top], 10);

      // Scaling past the middle would turn it inside out; this stops there.
      expect(mesh.areaOf(top), closeTo(0, 1e-9));
      expect(mesh.positions.every((at) => at.x.isFinite), isTrue);
    });

    test('then extruding is how a window is made', () {
      final mesh = cube();
      final side = mesh.faces.firstWhere((f) => mesh.normalOf(f).x > 0.9);

      mesh.inset([side], 0.2);
      mesh.extrude([side], -0.5);

      expect(mesh.faces, hasLength(6 + 4 + 4));
      expect(mesh.centreOf(side).x, closeTo(0, 1e-9));
    });
  });

  group('subdividing', () {
    test('turns one quad into four', () {
      final mesh = cube();
      final top = topOf(mesh);

      final made = mesh.subdivide([top]);

      expect(made, hasLength(4));
      expect(mesh.faces, hasLength(9));
      expect(mesh.faces.contains(top), isFalse);
    });

    test('a triangle becomes three quads', () {
      final mesh = Shape(kind: ShapeKind.cone, sides: 3).build();
      final side = mesh.faces.first;

      expect(mesh.subdivide([side]), hasLength(3));
    });

    test('the pieces cover what the face covered', () {
      final mesh = cube();
      final top = topOf(mesh);
      final was = mesh.areaOf(top);

      final made = mesh.subdivide([top]);
      final now = made.fold<double>(0, (sum, f) => sum + mesh.areaOf(f));

      expect(now, closeTo(was, 1e-9));
    });
  });

  group('welding', () {
    test('joins points in the same place', () {
      final mesh = Shape(kind: ShapeKind.stairs, steps: 3).build();
      final was = mesh.positions.length;

      final went = mesh.weld();

      // Three boxes stacked share corners; welding is what makes them one
      // solid rather than three that happen to touch.
      expect(went, greaterThan(0));
      expect(mesh.positions, hasLength(was - went));
    });

    test('leaves a shape that has no duplicates alone', () {
      final mesh = cube();
      expect(mesh.weld(), 0);
      expect(mesh.positions, hasLength(8));
    });

    test('a face left with two corners is dropped', () {
      final mesh = Mesh(
        positions: [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1.00001, 0, 0)],
      )..addFace([0, 1, 2]);

      mesh.weld(within: 0.01);

      // Two of its corners welded together, and an edge of no length is not a
      // face any more.
      expect(mesh.faces, isEmpty);
    });

    test('every face still names a point that exists', () {
      final mesh = Shape(kind: ShapeKind.stairs, steps: 6).build()..weld();

      for (final face in mesh.faces) {
        for (final index in face.vertices) {
          expect(index, inInclusiveRange(0, mesh.positions.length - 1));
        }
      }
    });
  });

  group('tidying up', () {
    test('compacting throws away points nothing uses', () {
      final mesh = cube();
      mesh.addVertex(Vector3(9, 9, 9));

      expect(mesh.compact(), 1);
      expect(mesh.positions, hasLength(8));
    });

    test('and leaves the faces pointing at the right ones', () {
      final mesh = cube();
      final top = topOf(mesh);
      final was = mesh.centreOf(top).clone();

      mesh.positions.insert(0, Vector3(9, 9, 9));
      for (final face in mesh.faces) {
        for (var i = 0; i < face.vertices.length; i++) {
          face.vertices[i] += 1;
        }
      }
      mesh.compact();

      expect(mesh.centreOf(top).y, closeTo(was.y, 1e-9));
    });

    test('deleting a face leaves its points for whatever else uses them', () {
      final mesh = cube();
      mesh.deleteFaces([topOf(mesh)]);

      expect(mesh.faces, hasLength(5));
      expect(mesh.positions, hasLength(8));
      expect(mesh.compact(), 0);
    });
  });

  group('what is open', () {
    test('a closed shape has no border', () {
      expect(cube().openFaces, isEmpty);
    });

    test('a shape with a face taken out does', () {
      final mesh = cube();
      mesh.deleteFaces([topOf(mesh)]);

      // The four sides round the hole, which is what "select the border"
      // should give somebody.
      expect(mesh.openFaces, hasLength(4));
    });

    test('a plane is all border', () {
      final mesh = Shape(
        kind: ShapeKind.plane,
        widthCuts: 0,
        heightCuts: 0,
      ).build();
      expect(mesh.openFaces, hasLength(1));
    });
  });

  group('flipping', () {
    test('turns a shape inside out', () {
      final mesh = cube();
      final top = topOf(mesh);
      expect(mesh.normalOf(top).y, closeTo(1, 1e-9));

      mesh.flip();

      expect(mesh.normalOf(top).y, closeTo(-1, 1e-9));
    });

    test('one face at a time, too', () {
      final mesh = cube();
      final top = topOf(mesh);

      mesh.flipFaces([top]);

      expect(mesh.normalOf(top).y, closeTo(-1, 1e-9));
      expect(mesh.faces.where((f) => mesh.normalOf(f).y > 0.9), isEmpty);
    });
  });
}
