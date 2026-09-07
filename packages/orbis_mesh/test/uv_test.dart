import 'dart:math' as math;

import 'package:orbis_mesh/orbis_mesh.dart';
import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  Mesh cube() => Shape.of(ShapeKind.cube).build();

  /// The face pointing a given way.
  Face facing(Mesh mesh, Vector3 way) =>
      mesh.faces.firstWhere((face) => mesh.normalOf(face).dot(way) > 0.99);

  group('the rule', () {
    test('a face nobody touched is automatic', () {
      expect(const FaceUv().isManual, isFalse);
      expect(cube().faces.first.uv.isManual, isFalse);
    });

    test('tiling keeps the texture the same size on a bigger face', () {
      final small = cube();
      final large = Shape.of(ShapeKind.cube).build();
      // Twice as wide, and nothing else changed.
      for (final at in large.positions) {
        at.x *= 2;
      }

      final a = small.uvBoundsOf([facing(small, Vector3(0, 1, 0))])!;
      final b = large.uvBoundsOf([facing(large, Vector3(0, 1, 0))])!;

      // Which of the two coordinate axes the world's X became is the
      // projection's business, so this asks about the wider of them rather
      // than naming one.
      double longest(({Vector2 min, Vector2 max}) box) =>
          math.max(box.max.x - box.min.x, box.max.y - box.min.y);

      expect(
        longest(b),
        closeTo(longest(a) * 2, 1e-9),
        reason: 'twice the wall, twice the bricks',
      );
    });

    test('stretching puts the whole texture on whatever shape the face is', () {
      final mesh = cube();
      for (final at in mesh.positions) {
        at.x *= 3;
      }
      final face = facing(mesh, Vector3(0, 1, 0))
        ..uv = const FaceUv(fit: UvFit.stretch);

      final box = mesh.uvBoundsOf([face])!;
      expect(box.min.x, closeTo(0, 1e-9));
      expect(box.min.y, closeTo(0, 1e-9));
      expect(box.max.x, closeTo(1, 1e-9));
      expect(
        box.max.y,
        closeTo(1, 1e-9),
        reason: 'both axes filled, whatever that does to the picture',
      );
    });

    test('fitting keeps the picture square and leaves the spare room', () {
      final mesh = cube();
      for (final at in mesh.positions) {
        at.x *= 3;
      }
      final face = facing(mesh, Vector3(0, 1, 0))
        ..uv = const FaceUv(fit: UvFit.fit);

      final box = mesh.uvBoundsOf([face])!;
      final spans = [box.max.x - box.min.x, box.max.y - box.min.y]..sort();
      expect(spans.last, closeTo(1, 1e-9), reason: 'the long way fills it');
      expect(
        spans.first,
        closeTo(1 / 3, 1e-9),
        reason: 'and the short way keeps its proportion',
      );
    });

    test('an edge-on face does not divide by nothing', () {
      final mesh = Mesh(
        positions: [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(2, 0, 0)],
        faces: [
          Face([0, 1, 2], uv: const FaceUv(fit: UvFit.stretch)),
        ],
      );
      for (final at in mesh.uvsOf(mesh.faces.first)) {
        expect(at.x.isFinite, isTrue);
        expect(at.y.isFinite, isTrue);
      }
    });

    test('two faces pointing the same way get the same axes', () {
      final a = FaceUv.axesFor(Vector3(0, 1, 0));
      final b = FaceUv.axesFor(Vector3(0, 1, 0));
      expect(a.u, b.u);
      expect(a.v, b.v);
    });

    test('the offset moves the texture and the scale repeats it', () {
      final mesh = cube();
      final face = facing(mesh, Vector3(0, 1, 0));
      final plain = mesh.uvsOf(face).first.clone();

      face.uv = FaceUv(offset: Vector2(0.5, 0));
      expect(mesh.uvsOf(face).first.x, closeTo(plain.x + 0.5, 1e-9));

      face.uv = FaceUv(scale: Vector2(2, 1));
      expect(mesh.uvsOf(face).first.x, closeTo(plain.x * 2, 1e-9));
    });

    test('a quarter turn takes one axis onto the other', () {
      final mesh = cube();
      final face = facing(mesh, Vector3(0, 1, 0))
        ..uv = const FaceUv(rotation: 90);
      final plain = Face(face.vertices);
      final was = mesh.uvsOf(plain).first;
      final now = mesh.uvsOf(face).first;
      expect(now.x, closeTo(-was.y, 1e-9));
      expect(now.y, closeTo(was.x, 1e-9));
    });
  });

  group('freezing', () {
    test('coordinates come out the same as the rule gave', () {
      final mesh = cube();
      final face = facing(mesh, Vector3(0, 1, 0));
      final was = mesh.uvsOf(face);

      mesh.freezeUvs([face]);

      expect(face.uv.isManual, isTrue);
      final now = mesh.uvsOf(face);
      for (var i = 0; i < was.length; i++) {
        expect(now[i].x, closeTo(was[i].x, 1e-12));
        expect(now[i].y, closeTo(was[i].y, 1e-12));
      }
    });

    test('a frozen face stops following the shape', () {
      final mesh = cube();
      final face = facing(mesh, Vector3(0, 1, 0));
      mesh.freezeUvs([face]);
      final was = mesh.uvsOf(face).first.clone();

      for (final at in mesh.positions) {
        at.x *= 5;
      }
      expect(
        mesh.uvsOf(face).first.x,
        closeTo(was.x, 1e-12),
        reason:
            'drawn coordinates belong to nobody but the person who drew '
            'them',
      );
    });

    test('letting go returns to the rule and keeps the settings', () {
      final mesh = cube();
      final face = facing(mesh, Vector3(0, 1, 0))
        ..uv = FaceUv(offset: Vector2(0.25, 0));
      mesh
        ..freezeUvs([face])
        ..releaseUvs([face]);

      expect(face.uv.isManual, isFalse);
      expect(face.uv.offset.x, 0.25);
    });

    test('coordinates for the wrong number of corners are ignored', () {
      final mesh = cube();
      final face = facing(mesh, Vector3(0, 1, 0));
      // Two, for a face with four. What a face looks like after being cut.
      face.uv = FaceUv(manual: [Vector2.zero(), Vector2(1, 1)]);
      expect(
        mesh.uvsOf(face),
        hasLength(4),
        reason: 'back to the rule rather than out of range',
      );
    });
  });

  group('editing', () {
    test('nudging a rule moves its offset and a drawn one its corners', () {
      final mesh = cube();
      final auto = facing(mesh, Vector3(0, 1, 0));
      final drawn = facing(mesh, Vector3(0, -1, 0));
      mesh.freezeUvs([drawn]);

      final wasAuto = mesh.uvsOf(auto).first.clone();
      final wasDrawn = mesh.uvsOf(drawn).first.clone();
      mesh.nudgeUvs([auto, drawn], Vector2(0.3, -0.2));

      expect(auto.uv.isManual, isFalse, reason: 'still a rule');
      expect(mesh.uvsOf(auto).first.x, closeTo(wasAuto.x + 0.3, 1e-9));
      expect(mesh.uvsOf(drawn).first.y, closeTo(wasDrawn.y - 0.2, 1e-9));
    });

    test(
      'scaling a selection keeps the faces where they are to each other',
      () {
        final mesh = cube();
        final faces = mesh.faces.take(3).toList();
        mesh
          ..projectBox(faces)
          ..nudgeUvs([faces[1]], Vector2(4, 0));

        final apart =
            mesh.uvsOf(faces[1]).first.x - mesh.uvsOf(faces[0]).first.x;
        mesh.scaleUvs(faces, Vector2(2, 2));
        final now = mesh.uvsOf(faces[1]).first.x - mesh.uvsOf(faces[0]).first.x;

        expect(
          now,
          closeTo(apart * 2, 1e-9),
          reason: 'about the selection, not each face on its own',
        );
      },
    );

    test('fitting puts the whole selection in the square', () {
      final mesh = cube();
      final faces = mesh.faces.take(4).toList();
      mesh.fitUvs(faces);

      final box = mesh.uvBoundsOf(faces)!;
      expect(box.min.x, closeTo(0, 1e-9));
      expect(box.min.y, closeTo(0, 1e-9));
      expect(math.max(box.max.x, box.max.y), closeTo(1, 1e-9));
    });

    test('bounds are null when there is nothing rather than a point', () {
      expect(cube().uvBoundsOf(const []), isNull);
    });

    test('a planar projection runs one texture across several faces', () {
      final mesh = cube();
      // The top and one side, which point differently: projected together
      // they share axes, so the side is smeared — which is the thing this
      // does and the reason not to use it on a box.
      final top = facing(mesh, Vector3(0, 1, 0));
      final side = facing(mesh, Vector3(1, 0, 0));
      mesh.projectPlanar([top, side]);

      expect(top.uv.isManual, isTrue);
      expect(side.uv.isManual, isTrue);
      // Where they meet in the world they meet in the texture too.
      final shared = top.vertices.toSet().intersection(side.vertices.toSet());
      expect(shared, isNotEmpty);
      for (final index in shared) {
        final a = mesh.uvsOf(top)[top.vertices.indexOf(index)];
        final b = mesh.uvsOf(side)[side.vertices.indexOf(index)];
        expect((a - b).length, closeTo(0, 1e-9));
      }
    });

    test('a box projection puts each face on its own axes', () {
      final mesh = cube();
      mesh.projectBox(mesh.faces);
      for (final face in mesh.faces) {
        expect(face.uv.isManual, isTrue);
        // Every face covers a unit square, because a unit cube's faces do.
        final box = mesh.uvBoundsOf([face])!;
        expect(box.max.x - box.min.x, closeTo(1, 1e-9));
      }
    });

    test('flipping a rule sets its flag and a drawn one mirrors in place', () {
      final mesh = cube();
      final auto = facing(mesh, Vector3(0, 1, 0));
      mesh.flipUvs([auto], u: true);
      expect(auto.uv.flipU, isTrue);

      final drawn = facing(mesh, Vector3(0, -1, 0));
      mesh.freezeUvs([drawn]);
      final was = mesh.uvBoundsOf([drawn])!;
      mesh.flipUvs([drawn], u: true);
      final now = mesh.uvBoundsOf([drawn])!;
      expect(
        now.min.x,
        closeTo(was.min.x, 1e-9),
        reason: 'mirrored about its own middle, so it stays where it was',
      );
      expect(now.max.x, closeTo(was.max.x, 1e-9));
    });

    test('turning a rule adds to its angle', () {
      final mesh = cube();
      final face = facing(mesh, Vector3(0, 1, 0));
      mesh
        ..turnUvs([face], 30)
        ..turnUvs([face], 15);
      expect(face.uv.rotation, 45);
      expect(face.uv.isManual, isFalse);
    });
  });

  group('through the file', () {
    test('a rule survives a round trip', () {
      final face = Face(
        [0, 1, 2],
        uv: FaceUv(
          fit: UvFit.fit,
          offset: Vector2(0.25, -0.5),
          scale: Vector2(2, 3),
          rotation: 45,
          flipV: true,
          swap: true,
        ),
      );
      final back = Face.fromJson(face.toJson())!;
      expect(back.uv.fit, UvFit.fit);
      expect(back.uv.offset.x, 0.25);
      expect(back.uv.scale.y, 3);
      expect(back.uv.rotation, 45);
      expect(back.uv.flipV, isTrue);
      expect(back.uv.flipU, isFalse);
      expect(back.uv.swap, isTrue);
    });

    test('drawn coordinates survive one too', () {
      final face = Face([
        0,
        1,
        2,
      ], uv: FaceUv(manual: [Vector2(0, 0), Vector2(1, 0), Vector2(0.5, 1)]));
      final back = Face.fromJson(face.toJson())!;
      expect(back.uv.isManual, isTrue);
      expect(back.uv.manual!, hasLength(3));
      expect(back.uv.manual![2].y, 1);
    });

    test('a face with nothing said about its texture writes nothing', () {
      expect(Face([0, 1, 2]).toJson().containsKey('uv'), isFalse);
    });

    test('a copy of a face gets its own coordinates', () {
      final face = Face([
        0,
        1,
        2,
      ], uv: FaceUv(manual: [Vector2.zero(), Vector2.zero(), Vector2.zero()]));
      final copy = face.copy();
      expect(copy.uv.manual, isNotNull);
      expect(
        identical(copy.uv, face.uv),
        isTrue,
        reason: 'the rule is immutable, so sharing it is safe',
      );
    });
  });

  test('what a mesh is drawn with comes from the faces', () {
    final mesh = cube();
    final face = facing(mesh, Vector3(0, 1, 0))
      ..uv = FaceUv(
        manual: [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)],
      );

    final tris = mesh.triangulate();
    // The face's own corners, wherever they ended up in the buffer.
    final at = mesh.faces.indexOf(face);
    expect(at, isNonNegative);
    expect(tris.uvs.length ~/ 2, tris.vertexCount);
    // Somewhere in there is a corner at exactly one, one — which the tiling
    // rule would never produce for a cube centred on the origin.
    var found = false;
    for (var i = 0; i + 1 < tris.uvs.length; i += 2) {
      if ((tris.uvs[i] - 1).abs() < 1e-6 &&
          (tris.uvs[i + 1] - 1).abs() < 1e-6) {
        found = true;
      }
    }
    expect(found, isTrue);
  });
}
