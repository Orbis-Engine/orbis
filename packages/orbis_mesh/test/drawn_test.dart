import 'package:orbis_mesh/orbis_mesh.dart';
import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  /// A unit square on the ground, drawn so it faces up.
  List<Vector3> square() => [
        Vector3(0, 0, 0),
        Vector3(0, 0, 1),
        Vector3(1, 0, 1),
        Vector3(1, 0, 0),
      ];

  group('the outline', () {
    test('under three points there is nothing to build', () {
      expect(PolyShape(points: [Vector3.zero()]).isDrawable, isFalse);
      expect(PolyShape(points: [Vector3.zero()]).build().isEmpty, isTrue);
      expect(PolyShape(points: square()).isDrawable, isTrue);
    });

    test('the plane is the one the points best lie on', () {
      final shape = PolyShape(points: square());
      expect(shape.plane.normal.y, closeTo(1, 1e-9));
      expect(shape.plane.centre.x, closeTo(0.5, 1e-9));
      expect(shape.plane.centre.y, closeTo(0, 1e-9));
    });

    test('points nowhere near a plane still give one rather than nothing', () {
      // Every point in a line: no plane at all, and the honest answer is a
      // lie that does not produce NaN in everything downstream.
      final shape = PolyShape(points: [
        Vector3(0, 0, 0),
        Vector3(1, 0, 0),
        Vector3(2, 0, 0),
      ]);
      expect(shape.plane.normal.length, closeTo(1, 1e-9));
    });

    test('a click back on the first point closes it, and only then', () {
      final points = square();
      expect(closesOutline(points, Vector3(0, 0, 0)), isTrue);
      expect(closesOutline(points, Vector3(5, 0, 5)), isFalse);
      expect(closesOutline(points.take(2).toList(), Vector3(0, 0, 0)), isFalse,
          reason: 'two points do not enclose anything to close');
    });

    test('a second click in the same place is not a second point', () {
      final points = [Vector3(1, 0, 1)];
      expect(isNewPoint(points, Vector3(1, 0, 1)), isFalse);
      expect(isNewPoint(points, Vector3(1.5, 0, 1)), isTrue);
      expect(isNewPoint(const [], Vector3.zero()), isTrue);
    });

    test('which way round it was drawn shows in the sign of its area', () {
      final up = Vector3(0, 1, 0);
      expect(signedAreaOf(square(), up), closeTo(1, 1e-9));
      expect(signedAreaOf(square().reversed.toList(), up), closeTo(-1, 1e-9));
    });

    test('a figure of eight is caught before it becomes geometry', () {
      final crossed = [
        Vector3(0, 0, 0),
        Vector3(1, 0, 1),
        Vector3(1, 0, 0),
        Vector3(0, 0, 1),
      ];
      expect(outlineCrosses(crossed, Vector3(0, 1, 0)), isTrue);
      expect(outlineCrosses(square(), Vector3(0, 1, 0)), isFalse);
      expect(outlineCrosses(square().take(3).toList(), Vector3(0, 1, 0)),
          isFalse,
          reason: 'a triangle cannot cross itself');
    });

    test('an outline that grazes itself is allowed', () {
      // Two edges meeting at a point rather than passing through each other.
      // Odd, drawable, and refusing it would refuse a lot to catch one.
      final grazing = [
        Vector3(0, 0, 0),
        Vector3(2, 0, 0),
        Vector3(1, 0, 1),
        Vector3(2, 0, 2),
        Vector3(0, 0, 2),
        Vector3(1, 0, 1),
      ];
      expect(outlineCrosses(grazing, Vector3(0, 1, 0)), isFalse);
    });
  });

  group('building', () {
    test('a square pulled up is a closed box', () {
      final mesh = PolyShape(points: square(), height: 2).build();

      expect(mesh.vertexCount, 8);
      expect(mesh.faceCount, 6, reason: 'a top, a bottom and four walls');

      final box = mesh.bounds;
      expect(box.min.y, closeTo(0, 1e-9));
      expect(box.max.y, closeTo(2, 1e-9));
    });

    test('every face points away from the middle', () {
      final mesh = PolyShape(points: square(), height: 2).build();
      final middle = mesh.bounds.min + (mesh.bounds.max - mesh.bounds.min) / 2;

      for (final face in mesh.faces) {
        final outward = mesh.centreOf(face) - middle;
        expect(mesh.normalOf(face).dot(outward), greaterThan(0),
            reason: 'a face wound the wrong way is a hole in a solid');
      }
    });

    test('drawn the other way round it still comes out solid', () {
      final mesh =
          PolyShape(points: square().reversed.toList(), height: 2).build();
      final middle = mesh.bounds.min + (mesh.bounds.max - mesh.bounds.min) / 2;

      for (final face in mesh.faces) {
        final outward = mesh.centreOf(face) - middle;
        expect(mesh.normalOf(face).dot(outward), greaterThan(0));
      }
    });

    test('a negative height goes the other way and is still solid', () {
      final mesh = PolyShape(points: square(), height: -2).build();
      final box = mesh.bounds;
      expect(box.min.y, closeTo(-2, 1e-9));
      expect(box.max.y, closeTo(0, 1e-9));

      final middle = box.min + (box.max - box.min) / 2;
      for (final face in mesh.faces) {
        expect(
          mesh.normalOf(face).dot(mesh.centreOf(face) - middle),
          greaterThan(0),
        );
      }
    });

    test('no height at all leaves one flat surface', () {
      final mesh = PolyShape(points: square(), height: 0).build();
      expect(mesh.faceCount, 1);
      expect(mesh.vertexCount, 4);
      expect(mesh.normalOf(mesh.faces.single).y, closeTo(1, 1e-9));
    });

    test('a six-sided plan gives six walls', () {
      final points = [
        for (var i = 0; i < 6; i++)
          Vector3(
            (i.isEven ? 1.0 : 0.6) * (i == 0 ? 1 : 1),
            0,
            i.toDouble(),
          ),
      ];
      final mesh = PolyShape(points: points, height: 1).build();
      expect(mesh.faceCount, 8, reason: 'six walls, a top and a bottom');
    });

    test('a shape on a sloping plane stays on it', () {
      // A square tilted forty-five degrees, drawn on that slope.
      final tilted = [
        Vector3(0, 0, 0),
        Vector3(0, 1, 1),
        Vector3(1, 1, 1),
        Vector3(1, 0, 0),
      ];
      final shape = PolyShape(points: tilted, height: 1);
      final mesh = shape.build();

      // The bottom face is the one somebody drew, so its normal is the
      // plane's — turned over, because it is the underside.
      final normal = shape.plane.normal;
      final bottom = mesh.faces.firstWhere(
        (face) => mesh.normalOf(face).dot(normal) < -0.99,
      );
      for (final at in mesh.pointsOf(bottom)) {
        expect((at - shape.plane.centre).dot(normal).abs(), lessThan(1e-9),
            reason: 'still on the plane it was drawn on');
      }
    });
  });

  group('placing a point', () {
    test('a ray meets the plane where it should', () {
      final at = PolyShape.onPlane(
        Vector3(0, 5, 0),
        Vector3(0, -1, 0),
        Vector3.zero(),
        Vector3(0, 1, 0),
      );
      expect(at!.y, closeTo(0, 1e-9));
    });

    test('a ray along the plane meets it nowhere', () {
      expect(
        PolyShape.onPlane(
          Vector3(0, 5, 0),
          Vector3(1, 0, 0),
          Vector3.zero(),
          Vector3(0, 1, 0),
        ),
        isNull,
      );
    });

    test('behind the camera is not on the plane in front of it', () {
      expect(
        PolyShape.onPlane(
          Vector3(0, 5, 0),
          Vector3(0, 1, 0),
          Vector3.zero(),
          Vector3(0, 1, 0),
        ),
        isNull,
      );
    });
  });

  test('the points survive a round trip, and are the shape', () {
    final shape = PolyShape(points: square(), height: 3, flipped: true);
    final back = PolyShape.fromJson(shape.toJson())!;

    expect(back.points, hasLength(4));
    expect(back.points[2].x, 1);
    expect(back.height, 3);
    expect(back.flipped, isTrue);
    // Which is the whole point of keeping them: the shape can be redrawn from
    // a corner a week later.
    expect(back.build().faceCount, shape.build().faceCount);
  });

  test('a copy can be edited without touching the original', () {
    final shape = PolyShape(points: square(), height: 1);
    final copy = shape.copy()..height = 9;
    copy.points.first.x = 42;

    expect(shape.height, 1);
    expect(shape.points.first.x, 0);
  });
}
