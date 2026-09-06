import 'package:orbis_mesh/orbis_mesh.dart';
import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  Mesh cube() => Shape.of(ShapeKind.cube).build();

  test('the centre of a selection is the middle of its corners', () {
    final mesh = cube();
    for (final face in mesh.faces) {
      final centre = mesh.centreOfPoints(face.vertices)!;
      expect(centre, mesh.centreOf(face),
          reason: 'the same answer as asking about the face itself');
    }
    // Every corner of a cube averages to the middle of it, which is the
    // pivot a handle over the whole thing should sit at.
    expect(
      mesh.centreOfPoints([for (var i = 0; i < mesh.vertexCount; i++) i]),
      mesh.centreOfPoints(mesh.faces.expand((face) => face.vertices)),
    );
  });

  test('the centre of nothing is nothing', () {
    expect(cube().centreOfPoints(const []), isNull);
    expect(cube().centreOfPoints([99, -3]), isNull, reason: 'and of nothing that is');
  });

  test('moving corners moves only those corners', () {
    final mesh = cube();
    final face = mesh.faces.first;
    final before = [for (final at in mesh.positions) at.clone()];

    mesh.movePoints(face.vertices, Vector3(0, 2, 0));

    final moved = face.vertices.toSet();
    for (var i = 0; i < mesh.positions.length; i++) {
      final shift = mesh.positions[i] - before[i];
      expect(shift.y, moved.contains(i) ? 2 : 0,
          reason: 'vertex $i');
      expect(shift.x, 0);
    }
    expect(mesh.faceCount, 6, reason: 'nothing was created or dropped');
  });

  test('an index the mesh does not have is skipped, not thrown at', () {
    final mesh = cube();
    final before = mesh.positions.first.clone();
    mesh.movePoints([-1, 900], Vector3(5, 5, 5));
    expect(mesh.positions.first, before);
  });

  test('turning about a point leaves that point where it is', () {
    final mesh = cube();
    final about = Vector3(0, 0, 0);
    final turn = Quaternion.axisAngle(Vector3(0, 1, 0), 3.14159265358979 / 2)
        .asRotationMatrix();
    final was = mesh.positions[0].clone();

    mesh.turnPoints([0], turn, about);
    final now = mesh.positions[0];

    expect(now.length, closeTo(was.length, 1e-9),
        reason: 'a rotation about the origin keeps the distance');
    expect(now.y, closeTo(was.y, 1e-9), reason: 'and the axis it turns about');
    // A quarter turn about +Y takes +X to -Z, which is the sense the object
    // handle turns in. Taking a quaternion here would give the opposite.
    expect(now.z, closeTo(-was.x, 1e-9));
    expect(now.x, closeTo(was.z, 1e-9));
  });

  test('turning about a corner pins that corner', () {
    final mesh = cube();
    final pin = mesh.positions[0].clone();
    mesh.turnPoints(
      [0, 1],
      Quaternion.axisAngle(Vector3(0, 1, 0), 0.7).asRotationMatrix(),
      pin,
    );
    expect((mesh.positions[0] - pin).length, closeTo(0, 1e-9));
  });

  test('scaling about a point pushes away from it', () {
    final mesh = cube();
    final about = Vector3.zero();
    final was = mesh.positions[0].clone();
    mesh.scalePoints([0], Vector3(2, 1, 1), about);
    expect(mesh.positions[0].x, closeTo(was.x * 2, 1e-9));
    expect(mesh.positions[0].y, closeTo(was.y, 1e-9));
  });

  test('two faces of a corner point along the corner', () {
    final mesh = cube();
    // The faces whose normals are +X and +Y, whichever way round the cube
    // lists them.
    Face facing(Vector3 way) => mesh.faces.firstWhere(
          (face) => mesh.normalOf(face).dot(way) > 0.99,
        );
    final across = mesh.normalAcross([facing(Vector3(1, 0, 0)), facing(Vector3(0, 1, 0))])!;

    expect(across.length, closeTo(1, 1e-9), reason: 'normalised');
    expect(across.x, closeTo(across.y, 1e-9), reason: 'evenly between them');
    expect(across.z, closeTo(0, 1e-9));
  });

  test('two faces back to back have no direction to be pulled along', () {
    final mesh = cube();
    Face facing(Vector3 way) => mesh.faces.firstWhere(
          (face) => mesh.normalOf(face).dot(way) > 0.99,
        );
    expect(
      mesh.normalAcross([facing(Vector3(1, 0, 0)), facing(Vector3(-1, 0, 0))]),
      isNull,
    );
  });

  test('a drag is a move repeated, not a move accumulated', () {
    // What the viewport does: the mesh is rebuilt from the one it started
    // with and moved by the whole shift, every frame. So the same shift
    // applied to a fresh copy always lands in the same place.
    final start = cube();
    final face = start.faces.first.vertices.toList();

    final once = start.copy()..movePoints(face, Vector3(0, 3, 0));
    final again = start.copy()..movePoints(face, Vector3(0, 3, 0));

    for (var i = 0; i < once.positions.length; i++) {
      expect(once.positions[i], again.positions[i]);
    }
  });
}
