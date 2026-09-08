import 'dart:math' as math;

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
        final mesh = Shape.of(kind).build();
        expect(mesh.faces, isNotEmpty, reason: kind.name);
        for (final face in mesh.faces) {
          expect(
            face.vertices.length,
            greaterThanOrEqualTo(3),
            reason: kind.name,
          );
        }
      }
    });

    test('names points that exist', () {
      for (final kind in ShapeKind.values) {
        final mesh = Shape.of(kind).build();
        for (final face in mesh.faces) {
          for (final index in face.vertices) {
            expect(
              index,
              inInclusiveRange(0, mesh.positions.length - 1),
              reason: kind.name,
            );
          }
        }
      }
    });

    test('has no face with a corner used twice', () {
      for (final kind in ShapeKind.values) {
        final mesh = Shape.of(kind).build();
        for (final face in mesh.faces) {
          expect(
            face.vertices.toSet(),
            hasLength(face.vertices.length),
            reason: kind.name,
          );
        }
      }
    });

    test('stands on the ground rather than half through it', () {
      for (final kind in ShapeKind.values) {
        final mesh = Shape.of(kind).copyWith(height: 2).build();
        // Somebody putting a box in a scene expects it on the floor; a shape
        // centred on its middle sinks half into it.
        expect(mesh.bounds.min.y, closeTo(0, 1e-9), reason: kind.name);
      }
    });

    test('is as big as it was asked to be', () {
      for (final kind in ShapeKind.values) {
        // A plane and a sprite are flat, and a torus is as tall as its tube
        // rather than as tall as its box — the tube radius is its own
        // measurement, which is what makes a thin ring possible.
        if (kind == ShapeKind.plane ||
            kind == ShapeKind.sprite ||
            kind == ShapeKind.torus) {
          continue;
        }
        final mesh = Shape.of(
          kind,
        ).copyWith(width: 3, height: 5, depth: 7).build();
        final box = mesh.bounds;
        expect(box.max.y - box.min.y, closeTo(5, 0.6), reason: kind.name);
      }
    });

    test('survives counts nobody would choose', () {
      // A dragged slider goes through every number on the way to the one
      // somebody wanted, including nought and a hundred thousand.
      for (final kind in ShapeKind.values) {
        for (final sides in [-5, 0, 1, 2, 3, 4096]) {
          final mesh = Shape.of(kind)
              .copyWith(
                sides: sides,
                rings: sides,
                columns: sides,
                steps: sides,
                subdivisions: sides,
                widthCuts: sides,
                heightCuts: sides,
              )
              .build();
          expect(mesh.faces, isNotEmpty, reason: '${kind.name} × $sides');
          expect(
            mesh.positions.every((at) => at.x.isFinite),
            isTrue,
            reason: '${kind.name} × $sides',
          );
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
    test('is a grid, so there are edges to pull on later', () {
      final mesh = Shape(
        kind: ShapeKind.plane,
        widthCuts: 2,
        heightCuts: 3,
      ).build();

      // Three columns by four rows, from two cuts across and three along.
      expect(mesh.faces, hasLength(12));
      expect(mesh.positions, hasLength(4 * 5));
    });

    test('every face points up', () {
      final mesh = Shape(kind: ShapeKind.plane, widthCuts: 2).build();
      for (final face in mesh.faces) {
        expect(mesh.normalOf(face).y, closeTo(1, 1e-9));
      }
    });

    test('with no cuts it is one quad', () {
      final mesh = Shape(
        kind: ShapeKind.plane,
        widthCuts: 0,
        heightCuts: 0,
      ).build();
      expect(mesh.faces, hasLength(1));
    });

    test('a sprite is a plane one unit square', () {
      final mesh = Shape(kind: ShapeKind.sprite, width: 9, depth: 9).build();
      final box = mesh.bounds;

      expect(mesh.faces, hasLength(1));
      expect(box.max.x - box.min.x, closeTo(1, 1e-9));
    });
  });

  group('the prism', () {
    test('is a box with a roof', () {
      final mesh = Shape(kind: ShapeKind.prism).build();

      // A bottom, two slopes and two gables.
      expect(mesh.faces, hasLength(5));
      expect(mesh.positions, hasLength(6));
      expect(facesOutwards(mesh), isTrue);
    });
  });

  group('the pipe', () {
    test('has an outside, an inside and two rims', () {
      final mesh = Shape(kind: ShapeKind.pipe, sides: 8).build();

      // Eight outside, eight inside, eight top and eight bottom.
      expect(mesh.faces, hasLength(32));
    });

    test('the inside faces inwards', () {
      final mesh = Shape(kind: ShapeKind.pipe, sides: 12).build();

      // A pipe whose bore faces outwards is a pipe you cannot see through.
      var inward = 0;
      for (final face in mesh.faces) {
        final centre = mesh.centreOf(face);
        final radial = Vector3(centre.x, 0, centre.z);
        if (radial.length < 1e-6) continue;
        // Normalised: an unnormalised dot is scaled by how far out the face
        // is, and the bore of a thin pipe is close to the middle.
        if (mesh.normalOf(face).dot(radial.normalized()) < -0.5) inward++;
      }
      expect(inward, 12);
    });

    test('a wall thicker than the pipe does not turn it inside out', () {
      final mesh = Shape(kind: ShapeKind.pipe, sides: 8, thickness: 99).build();
      expect(mesh.positions.every((at) => at.x.isFinite), isTrue);
      expect(mesh.faces, isNotEmpty);
    });

    test('height cuts add rings of faces', () {
      final plain = Shape(kind: ShapeKind.pipe, sides: 8).build();
      final cut = Shape(kind: ShapeKind.pipe, sides: 8, heightCuts: 2).build();

      expect(cut.faces.length, greaterThan(plain.faces.length));
    });
  });

  group('the torus', () {
    test('is a closed ring with no border', () {
      final mesh = Shape(kind: ShapeKind.torus, rings: 12, columns: 8).build();

      expect(mesh.faces, hasLength(12 * 8));
      // Closed all the way round, so nothing is on the border.
      expect(mesh.openFaces, isEmpty);
    });

    test('part of a circumference is open at both ends', () {
      final mesh = Shape(
        kind: ShapeKind.torus,
        rings: 12,
        columns: 8,
        circumference: 180,
      ).build();

      expect(mesh.openFaces, isNotEmpty);
    });
  });

  group('the door', () {
    test('is two uprights and a lintel with a gap between', () {
      final mesh = Shape(
        kind: ShapeKind.door,
        width: 3,
        height: 4,
        sideWidth: 0.5,
        pedimentHeight: 0.5,
      ).build();

      // Three boxes, six faces each.
      expect(mesh.faces, hasLength(18));

      // Nothing in the middle at the bottom, which is the point of a door.
      final atFloor = mesh.positions.where((at) => at.y < 0.01);
      expect(atFloor.any((at) => at.x.abs() < 0.4), isFalse);
    });
  });

  group('the cylinder', () {
    test('has a side per segment, and two ends', () {
      final mesh = Shape(kind: ShapeKind.cylinder, sides: 12).build();
      expect(mesh.faces, hasLength(12 + 2));
    });

    test('height cuts divide the sides without changing the shape', () {
      final mesh = Shape(
        kind: ShapeKind.cylinder,
        sides: 8,
        heightCuts: 3,
      ).build();

      // Four rings of eight, plus the two ends.
      expect(mesh.faces, hasLength(8 * 4 + 2));
      expect(mesh.bounds.max.y, closeTo(1, 1e-9));
    });

    test('without ends it is a tube', () {
      final mesh = Shape(
        kind: ShapeKind.cylinder,
        sides: 12,
        capped: false,
      ).build();
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
      final mesh = Shape(kind: ShapeKind.cone, sides: 9, capped: false).build();
      expect(mesh.faces, hasLength(9));
    });
  });

  group('the sphere', () {
    test('is an icosphere, so its faces are all about the same size', () {
      final mesh = Shape(kind: ShapeKind.sphere, subdivisions: 1).build();

      // The twenty faces of an icosahedron over its twelve corners. Latitude
      // and longitude would crowd every face into the poles, where a texture
      // pinches and a deformation bunches.
      expect(mesh.faces, hasLength(20));
      expect(mesh.positions, hasLength(12));

      final areas = [for (final face in mesh.faces) mesh.areaOf(face)];
      expect(areas.reduce(math.max) / areas.reduce(math.min), closeTo(1, 1e-6));
    });

    test('each division quadruples the faces', () {
      for (final (times, faces) in const [(1, 20), (2, 80), (3, 320)]) {
        expect(
          Shape(kind: ShapeKind.sphere, subdivisions: times).build().faces,
          hasLength(faces),
        );
      }
    });

    test('faces outwards', () {
      expect(
        facesOutwards(Shape(kind: ShapeKind.sphere, subdivisions: 2).build()),
        isTrue,
      );
    });

    test('every point is on the surface', () {
      final mesh = Shape(
        kind: ShapeKind.sphere,
        width: 2,
        height: 2,
        depth: 2,
        subdivisions: 3,
      ).build();

      for (final at in mesh.positions) {
        expect((at - Vector3(0, 1, 0)).length, closeTo(1, 1e-9));
      }
    });
  });

  group('the stairs', () {
    test('has a step per flight', () {
      final mesh = Shape(kind: ShapeKind.stairs, steps: 5).build();
      // Six faces a step, since each is a box until somebody welds them.
      expect(mesh.faces, hasLength(5 * 6));
    });

    test('by height it works out how many steps fit', () {
      final mesh = Shape(
        kind: ShapeKind.stairs,
        byCount: false,
        stepHeight: 0.25,
        height: 2,
      ).build();

      // Eight steps of a quarter each, rather than a number somebody counted.
      expect(mesh.faces, hasLength(8 * 6));
    });

    test('a step height of nothing does not make an infinity of steps', () {
      final mesh = Shape(
        kind: ShapeKind.stairs,
        byCount: false,
        stepHeight: 0,
      ).build();
      expect(mesh.faces.length, lessThan(256 * 6 + 1));
    });

    test('climbs by the height it was given', () {
      final mesh = Shape(
        kind: ShapeKind.stairs,
        steps: 4,
        height: 2,
        depth: 4,
      ).build();
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
        'positions': <num>[0, 0, 0, 1, 0, 0, 0, 1, 0],
        'faces': <Map<String, Object?>>[
          {
            'v': <int>[0, 1, 2],
          },
          {
            'v': <int>[0, 1, 99],
          },
        ],
      })!;

      expect(mesh.faces, hasLength(1));
    });

    test('is not read from something that is not one', () {
      expect(Mesh.fromJson('nonsense'), isNull);
      expect(Mesh.fromJson(<String, Object?>{'faces': <Object?>[]}), isNull);
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
