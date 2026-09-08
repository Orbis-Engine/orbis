import 'package:orbis_mesh/orbis_mesh.dart';
import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  Mesh cube() => Shape.of(ShapeKind.cube).build();

  test('growing by nothing changes nothing', () {
    final was = cube();
    final now = was.grown(0);
    for (var i = 0; i < was.vertexCount; i++) {
      expect(now.positions[i], was.positions[i]);
    }
  });

  test('every face ends up exactly the distance out it was asked for', () {
    final was = cube();
    final now = was.grown(0.25);

    for (var i = 0; i < was.faces.length; i++) {
      final normal = was.normalOf(was.faces[i]);
      final moved = now.centreOf(now.faces[i]) - was.centreOf(was.faces[i]);
      // Along the normal by exactly the distance, and not sideways at all.
      expect(moved.dot(normal), closeTo(0.25, 1e-9), reason: 'face $i');
      expect((moved - normal * 0.25).length, closeTo(0, 1e-9));
    }
  });

  test('a corner moves further than a face, which is what keeps it sharp', () {
    final was = cube();
    final now = was.grown(0.5);
    // A cube corner is a metre-and-a-bit along its diagonal for half a metre
    // of face: root three times as far.
    final corner = (now.positions[0] - was.positions[0]).length;
    expect(corner, closeTo(0.5 * 1.7320508, 1e-6));
  });

  test('a negative distance shrinks it', () {
    final was = cube();
    final now = was.grown(-0.1);
    expect(now.bounds.max.x, lessThan(was.bounds.max.x));
    expect(now.bounds.max.x, closeTo(was.bounds.max.x - 0.1, 1e-9));
  });

  test('nothing about the shape changes but where its corners are', () {
    final was = cube();
    was.faces.first
      ..material = 2
      ..smooth = true;
    final now = was.grown(0.3);

    expect(now.faceCount, was.faceCount);
    expect(now.vertexCount, was.vertexCount);
    expect(now.faces.first.material, 2);
    expect(now.faces.first.smooth, isTrue);
    expect(now.faces.first.vertices, was.faces.first.vertices);
  });

  test('the original is left alone', () {
    final was = cube();
    final before = was.positions.first.clone();
    was.grown(1);
    expect(was.positions.first, before);
  });

  test('a drawn room grows without turning inside out', () {
    final room = PolyShape(
      points: [
        Vector3(0, 0, 0),
        Vector3(0, 0, 3),
        Vector3(2, 0, 3),
        Vector3(2, 0, 1),
        Vector3(4, 0, 1),
        Vector3(4, 0, 0),
      ],
      height: 2,
    ).build();

    final grown = room.grown(0.2);
    // Every face still points the way it did. Not "away from the middle":
    // this room is concave, and the faces of its dent genuinely point back
    // towards its own centre.
    for (var i = 0; i < room.faces.length; i++) {
      final was = room.normalOf(room.faces[i]);
      final now = grown.normalOf(grown.faces[i]);
      expect((now - was).length, lessThan(1e-9), reason: 'face $i');
    }
    // And it is bigger everywhere.
    expect(grown.bounds.max.y, closeTo(room.bounds.max.y + 0.2, 1e-9));
    expect(grown.bounds.min.x, closeTo(room.bounds.min.x - 0.2, 1e-9));
  });

  test('a reflex corner is grown too, not left behind', () {
    final room = PolyShape(
      points: [
        Vector3(0, 0, 0),
        Vector3(0, 0, 3),
        Vector3(2, 0, 3),
        Vector3(2, 0, 1),
        Vector3(4, 0, 1),
        Vector3(4, 0, 0),
      ],
      height: 2,
    ).build();

    final was = room.copy();
    final now = room.grown(0.2);
    var moved = 0;
    for (var i = 0; i < was.vertexCount; i++) {
      if ((now.positions[i] - was.positions[i]).length > 1e-9) moved++;
    }
    expect(moved, was.vertexCount, reason: 'every corner, dents included');
  });

  test('a corner where faces cancel is left where it is', () {
    // Two faces back to back: their normals sum to nothing, and there is no
    // direction to move the corner in.
    final sheet = Mesh(
      positions: [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1)],
      faces: [
        Face([0, 1, 2]),
        Face([2, 1, 0]),
      ],
    );
    final grown = sheet.grown(0.5);
    for (var i = 0; i < sheet.vertexCount; i++) {
      expect(grown.positions[i], sheet.positions[i]);
    }
  });

  test('an empty mesh grows to nothing rather than throwing', () {
    expect(Mesh().grown(1).isEmpty, isTrue);
  });
}
