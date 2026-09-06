import 'package:orbis_mesh/orbis_mesh.dart';
import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  Mesh cube() => Shape.of(ShapeKind.cube).build();
  Face topOf(Mesh mesh) =>
      mesh.faces.firstWhere((f) => mesh.normalOf(f).y > 0.9);

  group('growing and shrinking', () {
    test('growing takes in the neighbours', () {
      final mesh = cube();
      final grown = mesh.grow([topOf(mesh)]);

      // The top and the four sides it touches; not the bottom.
      expect(grown, hasLength(5));
    });

    test('an angle keeps it on the flat', () {
      final mesh = Shape.of(ShapeKind.plane)
          .copyWith(widthCuts: 3, heightCuts: 3)
          .build();
      final middle = mesh.faces[5];

      // Every face of a plane points the same way, so nothing stops it.
      expect(mesh.grow([middle], withinAngle: 5).length, greaterThan(1));
    });

    test('an angle stops it turning a corner', () {
      final mesh = cube();

      // Ninety degrees to every neighbour, so nothing within five is taken.
      expect(mesh.grow([topOf(mesh)], withinAngle: 5), hasLength(1));
    });

    test('shrinking drops the ones on the edge', () {
      final mesh = Shape.of(ShapeKind.plane)
          .copyWith(widthCuts: 2, heightCuts: 2)
          .build();

      // Three by three; only the middle one has neighbours all round.
      expect(mesh.shrink(mesh.faces), hasLength(1));
    });

    test('shrinking one face leaves nothing', () {
      final mesh = cube();
      expect(mesh.shrink([topOf(mesh)]), isEmpty);
    });
  });

  group('loops and rings', () {
    test('a ring goes round a cylinder', () {
      final mesh =
          Shape.of(ShapeKind.cylinder).copyWith(sides: 8, capped: false).build();
      final face = mesh.faces.first;
      final edge = edgeOf(face.vertices[0], face.vertices[1]);

      // Either the eight edges round the top or the eight round the bottom.
      final ring = mesh.edgeRing(edge);
      expect(ring.length, anyOf(8, 2));
    });

    test('a face loop goes all the way round', () {
      final mesh =
          Shape.of(ShapeKind.cylinder).copyWith(sides: 8, capped: false).build();

      expect(mesh.faceLoop(mesh.faces.first), hasLength(8));
    });

    test('a loop stops at a triangle rather than wandering off', () {
      final mesh = Shape.of(ShapeKind.cone).copyWith(sides: 8).build();
      final side = mesh.faces.first;
      final edge = edgeOf(side.vertices[0], side.vertices[1]);

      // Nothing to cross: a cone's sides are triangles.
      expect(mesh.edgeRing(edge), hasLength(1));
    });
  });

  group('vertices', () {
    test('collapsing brings them together and welds them', () {
      final mesh = cube();
      final top = topOf(mesh);
      final was = mesh.positions.length;

      mesh.collapse(top.vertices);

      // Four corners became one, so the top face is gone with them.
      expect(mesh.positions.length, lessThan(was));
      expect(mesh.faces.contains(top), isFalse);
    });

    test('collapsing to the first keeps that one where it was', () {
      final mesh = cube();
      final top = topOf(mesh);
      final first = mesh.positions[top.vertices.first].clone();

      mesh.collapse(top.vertices, toFirst: true);

      expect(mesh.positions.any((at) => (at - first).length < 1e-9), isTrue);
    });

    test('splitting gives each face its own corner', () {
      final mesh = cube();
      final was = mesh.positions.length;

      // A box's corner is used by three faces.
      final made = mesh.split([0]);

      expect(made, 2);
      expect(mesh.positions, hasLength(was + 2));
    });

    test('splitting a corner only one face uses does nothing', () {
      final mesh =
          Shape.of(ShapeKind.plane).copyWith(widthCuts: 0, heightCuts: 0).build();
      expect(mesh.split([0]), 0);
    });
  });

  group('filling a hole', () {
    test('closes a face that was deleted', () {
      final mesh = cube();
      mesh.deleteFaces([topOf(mesh)]);
      expect(mesh.openEdges, hasLength(4));

      final made = mesh.fillHole(const []);

      expect(made, hasLength(1));
      expect(mesh.openEdges, isEmpty);
    });

    test('the patch faces the way its neighbours do', () {
      final mesh = cube();
      mesh.deleteFaces([topOf(mesh)]);

      final patch = mesh.fillHole(const []).single;

      // A patch facing the wrong way is a hole that looks like it is still
      // there.
      expect(mesh.normalOf(patch).y, closeTo(1, 1e-9));
    });

    test('a closed shape has nothing to fill', () {
      expect(cube().fillHole(const []), isEmpty);
    });
  });

  group('bevelling', () {
    test('puts a face where the edge was', () {
      final mesh = cube();
      final top = topOf(mesh);
      final edge = edgeOf(top.vertices[0], top.vertices[1]);

      final made = mesh.bevel([edge], 0.2);

      expect(made, hasLength(1));
      expect(mesh.faces, hasLength(7));
    });

    test('an open edge has nothing to bevel between', () {
      final mesh =
          Shape.of(ShapeKind.plane).copyWith(widthCuts: 0, heightCuts: 0).build();
      final edge = edgeOf(mesh.faces.first.vertices[0],
          mesh.faces.first.vertices[1]);

      expect(mesh.bevel([edge], 0.2), isEmpty);
    });
  });

  group('bridging', () {
    test('puts a face between two open edges', () {
      final mesh = Mesh(positions: [
        Vector3(0, 0, 0),
        Vector3(1, 0, 0),
        Vector3(0, 0, 2),
        Vector3(1, 0, 2),
      ]);

      final made = mesh.bridge(edgeOf(0, 1), edgeOf(2, 3));

      expect(made, isNotNull);
      expect(mesh.areaOf(made!), closeTo(2, 1e-9));
    });

    test('does not make a bow tie of it', () {
      final mesh = Mesh(positions: [
        Vector3(0, 0, 0),
        Vector3(1, 0, 0),
        Vector3(1, 0, 2),
        Vector3(0, 0, 2),
      ]);

      // The two edges run in opposite directions; joining them corner to
      // corner would cross the face over itself and halve its area.
      final made = mesh.bridge(edgeOf(0, 1), edgeOf(2, 3))!;
      expect(mesh.areaOf(made), closeTo(2, 1e-9));
    });
  });

  group('subdividing an edge', () {
    test('adds a point and puts it in both faces', () {
      final mesh = cube();
      final top = topOf(mesh);
      final edge = edgeOf(top.vertices[0], top.vertices[1]);

      final made = mesh.subdivideEdges([edge]);

      expect(made, hasLength(1));
      // Both faces along the edge grew a corner, so neither is left with a
      // point in the middle of its neighbour's edge.
      for (final face in mesh.facesOn(edgeOf(top.vertices[0], made.first))) {
        expect(face.vertices, contains(made.first));
      }
    });

    test('several cuts at once', () {
      final mesh = cube();
      final top = topOf(mesh);
      final edge = edgeOf(top.vertices[0], top.vertices[1]);

      expect(mesh.subdivideEdges([edge], into: 3), hasLength(3));
      expect(top.vertices, hasLength(7));
    });
  });

  group('detaching and duplicating', () {
    test('detaching takes the faces out and hands them back', () {
      final mesh = cube();
      final taken = mesh.detach([topOf(mesh)]);

      expect(mesh.faces, hasLength(5));
      expect(taken.faces, hasLength(1));
      expect(taken.positions, hasLength(4));
    });

    test('duplicating leaves the original alone', () {
      final mesh = cube();
      final copy = mesh.duplicateFaces([topOf(mesh)]);

      expect(mesh.faces, hasLength(6));
      expect(copy.faces, hasLength(1));
    });
  });

  group('merging faces', () {
    test('two side by side become one', () {
      final mesh = Shape.of(ShapeKind.plane)
          .copyWith(widthCuts: 1, heightCuts: 0)
          .build();
      final was = mesh.areaOf(mesh.faces[0]) + mesh.areaOf(mesh.faces[1]);

      final made = mesh.mergeFaces(mesh.faces.toList());

      expect(made, isNotNull);
      expect(mesh.faces, hasLength(1));
      expect(mesh.areaOf(made!), closeTo(was, 1e-9));
    });

    test('the merged face points the way the pieces did', () {
      final mesh = Shape.of(ShapeKind.plane)
          .copyWith(widthCuts: 1, heightCuts: 0)
          .build();

      final made = mesh.mergeFaces(mesh.faces.toList())!;
      expect(mesh.normalOf(made).y, closeTo(1, 1e-9));
    });

    test('one face cannot be merged with itself', () {
      final mesh = cube();
      expect(mesh.mergeFaces([topOf(mesh)]), isNull);
    });
  });

  group('triangulating', () {
    test('a quad becomes two triangles', () {
      final mesh = cube();
      final made = mesh.triangulateFaces([topOf(mesh)]);

      expect(made, hasLength(2));
      expect(mesh.faces, hasLength(7));
      expect(made.every((f) => f.isTriangle), isTrue);
    });

    test('a triangle is left as it is', () {
      final mesh = Shape.of(ShapeKind.cone).copyWith(sides: 5).build();
      final side = mesh.faces.first;

      expect(mesh.triangulateFaces([side]), [side]);
    });
  });

  group('conforming normals', () {
    test('turns the odd one back the right way', () {
      final mesh = cube();
      mesh.flipFaces([topOf(mesh)]);

      expect(mesh.conformNormals(), 1);
      expect(mesh.normalOf(topOf(mesh)).y, closeTo(1, 1e-9));
    });

    test('leaves a shape that is already consistent alone', () {
      expect(cube().conformNormals(), 0);
    });

    test('a shape that is mostly inside out is turned inside out', () {
      final mesh = cube();
      // Five of six flipped: the majority is what it conforms to.
      mesh.flipFaces(mesh.faces.take(5));

      expect(mesh.conformNormals(), 1);
    });
  });

  group('the pivot', () {
    test('moving it to a face puts that face at the origin', () {
      final mesh = cube();
      final top = topOf(mesh);

      final moved = mesh.centrePivotOn(top.vertices);

      expect(moved.y, closeTo(1, 1e-9));
      expect(mesh.centreOf(top).y, closeTo(0, 1e-9));
    });

    test('with nothing selected it goes to the middle', () {
      final mesh = cube();
      mesh.centrePivotOn(const []);

      final box = mesh.bounds;
      expect((box.min + box.max).length, closeTo(0, 1e-9));
    });
  });

  group('mirroring', () {
    test('a copy on the other side, facing the right way', () {
      final mesh = cube();
      final copy = mesh.mirrored(x: true);

      expect(copy.faces, hasLength(6));
      // Reflecting turns the winding inside out; a mirror that forgets is a
      // shape you can only see from inside.
      final top = copy.faces.firstWhere((f) => copy.centreOf(f).y > 0.9);
      expect(copy.normalOf(top).y, closeTo(1, 1e-9));
    });

    test('across two axes is not inside out', () {
      final copy = cube().mirrored(x: true, z: true);
      final top = copy.faces.firstWhere((f) => copy.centreOf(f).y > 0.9);
      expect(copy.normalOf(top).y, closeTo(1, 1e-9));
    });

    test('across nothing is just a copy', () {
      final mesh = cube();
      final copy = mesh.mirrored();
      expect(copy.positions.first.x, mesh.positions.first.x);
    });
  });
}
