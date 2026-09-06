import 'dart:convert';
import 'dart:typed_data';

import 'package:orbis_mesh/orbis_mesh.dart';
import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  group('triangulating', () {
    test('a quad becomes two triangles', () {
      final tris = Shape(kind: ShapeKind.plane, widthCuts: 0, heightCuts: 0)
          .build()
          .triangulate();

      expect(tris.triangleCount, 2);
      expect(tris.vertexCount, 4);
    });

    test('a box keeps its corners apart, so it looks like a box', () {
      final tris = Shape(kind: ShapeKind.cube).build().triangulate();

      // Eight corners, twenty-four vertices: each corner needs three normals,
      // and sharing them is what makes a box look like a deflated ball.
      expect(tris.vertexCount, 24);
      expect(tris.triangleCount, 12);
    });

    test('every index names a vertex that is there', () {
      for (final kind in ShapeKind.values) {
        final tris = Shape(kind: kind).build().triangulate();
        for (final index in tris.indices) {
          expect(index, lessThan(tris.vertexCount), reason: kind.name);
        }
      }
    });

    test('there is a normal and a texture coordinate for every vertex', () {
      for (final kind in ShapeKind.values) {
        final tris = Shape(kind: kind).build().triangulate();
        expect(tris.normals.length, tris.positions.length, reason: kind.name);
        expect(tris.uvs.length ~/ 2, tris.vertexCount, reason: kind.name);
      }
    });

    test('every normal is a direction rather than nothing', () {
      for (final kind in ShapeKind.values) {
        final tris = Shape(kind: kind).build().triangulate();
        for (var i = 0; i + 2 < tris.normals.length; i += 3) {
          final length = Vector3(
            tris.normals[i],
            tris.normals[i + 1],
            tris.normals[i + 2],
          ).length;
          expect(length, closeTo(1, 1e-4), reason: kind.name);
        }
      }
    });

    test('a smooth side shades round rather than faceted', () {
      final tris = Shape(kind: ShapeKind.cylinder, sides: 16).build()
          .triangulate();

      // On a smooth cylinder a vertex's normal points away from the axis. On a
      // faceted one it points the way its own flat face does, which at the
      // seam between two faces is visibly the wrong way by half a segment.
      var checked = 0;
      for (var i = 0; i < tris.vertexCount; i++) {
        final at = Vector3(
          tris.positions[i * 3],
          tris.positions[i * 3 + 1],
          tris.positions[i * 3 + 2],
        );
        final normal = Vector3(
          tris.normals[i * 3],
          tris.normals[i * 3 + 1],
          tris.normals[i * 3 + 2],
        );
        // Only the sides: the ends are flat on purpose.
        if (normal.y.abs() > 0.1) continue;

        final radial = Vector3(at.x, 0, at.z);
        if (radial.length < 1e-6) continue;

        expect(angleBetween(normal, radial), lessThan(0.02));
        checked++;
      }
      expect(checked, greaterThan(16));
    });

    test('a flat shape does not', () {
      final tris = Shape(kind: ShapeKind.cube).build().triangulate();

      // Six faces, six directions, and no averaging between them.
      final directions = <String>{};
      for (var i = 0; i < tris.vertexCount; i++) {
        directions.add('${tris.normals[i * 3].round()}'
            '${tris.normals[i * 3 + 1].round()}'
            '${tris.normals[i * 3 + 2].round()}');
      }
      expect(directions, hasLength(6));
    });

    test('a face with fewer than three corners is skipped, not drawn', () {
      final mesh = Mesh(positions: [Vector3.zero(), Vector3(1, 0, 0)])
        ..addFace([0, 1]);

      expect(mesh.triangulate().triangleCount, 0);
    });
  });

  group('the glb it writes', () {
    /// The JSON chunk of a binary glTF.
    Map<String, Object?> headerOf(Uint8List glb) {
      final view = ByteData.sublistView(glb);
      final jsonLength = view.getUint32(12, Endian.little);
      final text = utf8.decode(glb.sublist(20, 20 + jsonLength)).trim();
      return jsonDecode(text) as Map<String, Object?>;
    }

    test('starts with the magic word and says it is version two', () {
      final glb = Shape(kind: ShapeKind.cube).build().toGlb();
      final view = ByteData.sublistView(glb);

      expect(view.getUint32(0, Endian.little), 0x46546C67);
      expect(view.getUint32(4, Endian.little), 2);
      expect(view.getUint32(8, Endian.little), glb.length);
    });

    test('every chunk is a whole number of four-byte words', () {
      for (final kind in ShapeKind.values) {
        final glb = Shape(kind: kind).build().toGlb();
        expect(glb.length % 4, 0, reason: kind.name);

        final view = ByteData.sublistView(glb);
        expect(view.getUint32(12, Endian.little) % 4, 0, reason: kind.name);
      }
    });

    test('describes one mesh with the three attributes a renderer wants', () {
      final header = headerOf(Shape(kind: ShapeKind.cube).build().toGlb());
      final primitive = ((header['meshes']! as List).first
          as Map<String, Object?>)['primitives'] as List;
      final attributes =
          (primitive.first as Map<String, Object?>)['attributes'] as Map;

      expect(attributes.keys, containsAll(['POSITION', 'NORMAL', 'TEXCOORD_0']));
    });

    test('the accessors count what is actually in the buffer', () {
      final mesh = Shape(kind: ShapeKind.cube).build();
      final tris = mesh.triangulate();
      final header = headerOf(mesh.toGlb());

      final accessors = header['accessors']! as List;
      expect((accessors[0] as Map)['count'], tris.indices.length);
      expect((accessors[1] as Map)['count'], tris.vertexCount);
      expect((accessors[2] as Map)['count'], tris.vertexCount);
    });

    test('the buffer views stay inside the buffer', () {
      for (final kind in ShapeKind.values) {
        final header = headerOf(Shape(kind: kind).build().toGlb());
        final length = ((header['buffers']! as List).first
            as Map<String, Object?>)['byteLength']! as int;

        for (final view in header['bufferViews']! as List) {
          final at = (view as Map)['byteOffset']! as int;
          final size = view['byteLength']! as int;
          expect(at + size, lessThanOrEqualTo(length), reason: kind.name);
          // Float accessors have to start on a four-byte boundary.
          expect(at % 4, 0, reason: kind.name);
        }
      }
    });

    test('positions carry the bounds, which the format requires', () {
      final mesh = Shape(kind: ShapeKind.cube, width: 4).build();
      final header = headerOf(mesh.toGlb());
      final positions = (header['accessors']! as List)[1] as Map;

      expect((positions['min']! as List).first, closeTo(-2, 1e-6));
      expect((positions['max']! as List).first, closeTo(2, 1e-6));
    });

    test('counts are written as integers, not as 12.0', () {
      // A count written with a decimal point is a file some loaders refuse.
      final glb = Shape(kind: ShapeKind.cube).build().toGlb();
      final view = ByteData.sublistView(glb);
      final jsonLength = view.getUint32(12, Endian.little);
      final text = utf8.decode(glb.sublist(20, 20 + jsonLength));

      expect(text, isNot(contains('.0,')));
      expect(text, contains('"version":"2.0"'));
    });

    test('an empty mesh still writes a file rather than throwing', () {
      final glb = Mesh().toGlb();
      expect(glb.length, greaterThan(20));
      expect(ByteData.sublistView(glb).getUint32(0, Endian.little), 0x46546C67);
    });
  });
}
