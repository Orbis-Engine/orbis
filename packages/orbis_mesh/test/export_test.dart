import 'dart:typed_data';

import 'package:orbis_mesh/orbis_mesh.dart';
import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  Mesh cube() => Shape.of(ShapeKind.cube).build();

  Written only(List<Written> files, String extension) =>
      files.firstWhere((one) => one.name.endsWith(extension));

  group('OBJ', () {
    test('a quad stays a quad', () {
      final text = only(cube().toObj(), '.obj').text;
      final faces = [
        for (final line in text.split('\n'))
          if (line.startsWith('f ')) line,
      ];

      expect(faces, hasLength(6));
      for (final face in faces) {
        expect(
          face.trim().split(RegExp(r'\s+')).length,
          5,
          reason: 'four corners and the f — not two triangles',
        );
      }
    });

    test('every corner has a position, a coordinate and a normal', () {
      final text = only(cube().toObj(), '.obj').text;
      for (final line in text.split('\n')) {
        if (!line.startsWith('f ')) continue;
        for (final corner in line.substring(2).trim().split(RegExp(r'\s+'))) {
          final parts = corner.split('/');
          expect(parts, hasLength(3));
          for (final part in parts) {
            expect(int.tryParse(part), isNotNull);
            expect(
              int.parse(part),
              greaterThan(0),
              reason: 'one-based, which is what OBJ has always been',
            );
          }
        }
      }
    });

    test('the counts add up', () {
      final text = only(cube().toObj(), '.obj').text;
      int count(String prefix) =>
          text.split('\n').where((line) => line.startsWith('$prefix ')).length;

      expect(count('v'), 8, reason: 'a cube has eight corners');
      // One coordinate and one normal a face corner: six faces of four.
      expect(count('vt'), 24);
      expect(count('vn'), 24);
    });

    test('materials come with a library that names them', () {
      final mesh = cube();
      for (var i = 0; i < mesh.faces.length; i++) {
        mesh.faces[i].material = i < 3 ? 0 : 1;
      }
      final files = mesh.toObj(
        name: 'wall',
        materials: const [
          GlbMaterial(name: 'Red brick', colour: [0.6, 0.2, 0.1, 1]),
          GlbMaterial(
            name: 'Glass',
            roughness: 0.05,
            colour: [0.8, 0.9, 1, 0.4],
          ),
        ],
      );

      expect(files, hasLength(2));
      expect(files.first.name, 'wall.obj');
      expect(files.last.name, 'wall.mtl');
      expect(only(files, '.obj').text, contains('mtllib wall.mtl'));

      final mtl = only(files, '.mtl').text;
      expect(
        mtl,
        contains('newmtl Red_brick'),
        reason: 'a space in a name splits the line',
      );
      expect(mtl, contains('newmtl Glass'));
      expect(mtl, contains('d 0.4'), reason: 'the see-through one says so');
    });

    test('a mesh with no materials writes no library', () {
      expect(cube().toObj(), hasLength(1));
    });

    test('faces are grouped so each material is said once', () {
      final mesh = cube();
      for (var i = 0; i < mesh.faces.length; i++) {
        mesh.faces[i].material = i.isEven ? 0 : 1;
      }
      final text = only(
        mesh.toObj(materials: const [GlbMaterial(), GlbMaterial()]),
        '.obj',
      ).text;

      final uses = [
        for (final line in text.split('\n'))
          if (line.startsWith('usemtl')) line,
      ];
      expect(uses, hasLength(2), reason: 'not back and forth down the file');
    });

    test('nothing is written in exponent form', () {
      final mesh = Mesh(
        positions: [
          Vector3(0.0000001, 0, 0),
          Vector3(1, 0, 0),
          Vector3(0, 1, 0),
        ],
        faces: [
          Face([0, 1, 2]),
        ],
      );
      final text = only(mesh.toObj(), '.obj').text;
      expect(text, isNot(contains('e-')));
      expect(text, isNot(contains('e+')));
    });
  });

  group('STL', () {
    test('binary says how many triangles and then has that many', () {
      final bytes = cube().toStl();
      final data = ByteData.sublistView(bytes);
      final count = data.getUint32(80, Endian.little);

      expect(count, 12, reason: 'six quads cut into two each');
      expect(bytes.length, 84 + count * 50);
    });

    test('a binary file does not start with the word solid', () {
      // Half the readers there are decide which kind it is by looking, and a
      // binary file that starts with "solid" is read as text and fails.
      final bytes = cube().toStl();
      expect(String.fromCharCodes(bytes.take(5)), isNot('solid'));
    });

    test('the text one is a solid with facets in it', () {
      final text = String.fromCharCodes(cube().toStl(binary: false));
      expect(text, startsWith('solid'));
      expect(text.trim(), endsWith('endsolid mesh'));
      expect(text.split('facet normal').length - 1, 12);
      expect(text.split('vertex ').length - 1, 36);
    });

    test('every facet has a direction of unit length', () {
      final bytes = cube().toStl();
      final data = ByteData.sublistView(bytes);
      final count = data.getUint32(80, Endian.little);

      for (var i = 0; i < count; i++) {
        final at = 84 + i * 50;
        final normal = Vector3(
          data.getFloat32(at, Endian.little),
          data.getFloat32(at + 4, Endian.little),
          data.getFloat32(at + 8, Endian.little),
        );
        expect(normal.length, closeTo(1, 1e-5));
      }
    });
  });

  group('PLY', () {
    test('the header says what is in it and the counts match', () {
      final text = String.fromCharCodes(cube().toPly(binary: false));
      expect(text, startsWith('ply'));
      expect(text, contains('format ascii 1.0'));
      expect(text, contains('element vertex 24'));
      expect(text, contains('element face 12'));

      final body = text.split('end_header\n').last.trim().split('\n');
      expect(body, hasLength(24 + 12));
      expect(body.last.startsWith('3 '), isTrue);
    });

    test('binary is the header as text and the rest as numbers', () {
      final bytes = cube().toPly();
      // Enough to hold the whole header, which is nearly three hundred
      // bytes: cut it short and the search for its end finds nothing.
      final text = String.fromCharCodes(bytes.take(500));
      expect(text, startsWith('ply'));
      expect(text, contains('binary_little_endian'));

      final at = text.indexOf('end_header\n') + 'end_header\n'.length;
      // Eight floats a vertex, and a byte plus three ints a face.
      expect(bytes.length - at, 24 * 32 + 12 * 13);
    });

    test('the first corner reads back as a corner of the cube', () {
      final bytes = cube().toPly();
      final text = String.fromCharCodes(bytes.take(500));
      final at = text.indexOf('end_header\n') + 'end_header\n'.length;
      final data = ByteData.sublistView(bytes, at);

      final point = Vector3(
        data.getFloat32(0, Endian.little),
        data.getFloat32(4, Endian.little),
        data.getFloat32(8, Endian.little),
      );
      final box = cube().bounds;
      for (final axis in [
        (point.x, box.min.x, box.max.x),
        (point.y, box.min.y, box.max.y),
        (point.z, box.min.z, box.max.z),
      ]) {
        expect(axis.$1, greaterThanOrEqualTo(axis.$2 - 1e-5));
        expect(axis.$1, lessThanOrEqualTo(axis.$3 + 1e-5));
      }
    });
  });

  group('reading a size back', () {
    test('a file says how big it is without being decoded', () {
      final mesh = Shape.of(ShapeKind.stairs).build();
      final box = boundsOfGlb(mesh.toGlb())!;
      final actual = mesh.bounds;

      expect(box.min.x, closeTo(actual.min.x, 1e-5));
      expect(box.max.y, closeTo(actual.max.y, 1e-5));
      expect(box.max.z, closeTo(actual.max.z, 1e-5));
    });

    test('several materials are several primitives, and it takes them all', () {
      final mesh = cube();
      for (var i = 0; i < mesh.faces.length; i++) {
        mesh.faces[i].material = i;
      }
      final box = boundsOfGlb(
        mesh.toGlb(
          materials: [for (var i = 0; i < 6; i++) const GlbMaterial()],
        ),
      )!;
      expect(box.max.x, closeTo(cube().bounds.max.x, 1e-5));
    });

    test('normals are not mistaken for positions', () {
      // Every normal is between minus one and one, so folding those in would
      // swallow anything smaller than a two-metre cube.
      final small = cube();
      for (final at in small.positions) {
        at.scale(0.1);
      }
      final box = boundsOfGlb(small.toGlb())!;
      expect(box.max.x, lessThan(0.2));
    });

    test('something that is not a glb is nothing, not a guess', () {
      expect(boundsOfGlb(Uint8List(0)), isNull);
      expect(boundsOfGlb(Uint8List.fromList([1, 2, 3, 4, 5])), isNull);
      expect(
        boundsOfGlb(Uint8List.fromList(List.filled(64, 0))),
        isNull,
        reason: 'a file of zeros has no magic number',
      );
    });

    test('a truncated file is nothing rather than a crash', () {
      final whole = cube().toGlb();
      expect(boundsOfGlb(whole.sublist(0, 30)), isNull);
    });
  });

  group('choosing a format', () {
    test('each one comes back named after itself', () {
      for (final format in MeshFormat.values) {
        final files = cube().writeAs(format, name: 'thing');
        expect(files, isNotEmpty);
        expect(files.first.name, 'thing.${format.extension}');
      }
    });

    test('only OBJ brings a second file, and only when it has materials', () {
      expect(
        cube().writeAs(MeshFormat.obj, materials: const [GlbMaterial()]),
        hasLength(2),
      );
      expect(cube().writeAs(MeshFormat.obj), hasLength(1));
      expect(
        cube().writeAs(MeshFormat.stl, materials: const [GlbMaterial()]),
        hasLength(1),
        reason: 'STL has nowhere to put one',
      );
    });

    test('the two that carry materials say so', () {
      expect(MeshFormat.obj.hasMaterials, isTrue);
      expect(MeshFormat.glb.hasMaterials, isTrue);
      expect(MeshFormat.stl.hasMaterials, isFalse);
      expect(MeshFormat.ply.hasMaterials, isFalse);
      expect(MeshFormat.obj.hasSidecar, isTrue);
      expect(MeshFormat.glb.hasSidecar, isFalse);
    });

    test('an empty mesh writes a file rather than throwing', () {
      for (final format in MeshFormat.values) {
        final files = Mesh().writeAs(format);
        expect(files, isNotEmpty);
        expect(files.first.bytes, isNotEmpty);
      }
    });
  });
}
