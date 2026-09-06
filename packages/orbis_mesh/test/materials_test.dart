import 'dart:convert';
import 'dart:typed_data';

import 'package:orbis_mesh/orbis_mesh.dart';
import 'package:test/test.dart';

/// Reads the JSON chunk back out of a glb.
Map<String, Object?> jsonOf(Uint8List glb) {
  final data = ByteData.sublistView(glb);
  final length = data.getUint32(12, Endian.little);
  final text = utf8.decode(glb.sublist(20, 20 + length)).trimRight();
  return jsonDecode(text) as Map<String, Object?>;
}

void main() {
  Mesh cube() => Shape.of(ShapeKind.cube).build();

  test('a mesh nobody painted is one run of everything', () {
    final tris = cube().triangulate();
    expect(tris.runs, hasLength(1));
    expect(tris.runs.single.material, 0);
    expect(tris.runs.single.count, tris.indices.length);
  });

  test('faces are sorted so each material is one run', () {
    final mesh = cube();
    // Deliberately out of order, which is how somebody painting faces one at
    // a time would leave them.
    mesh.faces[0].material = 2;
    mesh.faces[1].material = 0;
    mesh.faces[2].material = 2;
    mesh.faces[3].material = 1;

    final tris = mesh.triangulate();
    final materials = [for (final run in tris.runs) run.material];
    expect(materials, [0, 1, 2], reason: 'in order, each appearing once');

    // Contiguous and covering everything: a gap would be triangles nobody
    // draws, and an overlap would be triangles drawn twice.
    var at = 0;
    for (final run in tris.runs) {
      expect(run.start, at);
      at += run.count;
    }
    expect(at, tris.indices.length);
  });

  test('the same triangles come out however they are grouped', () {
    final plain = cube().triangulate();
    final painted = cube();
    for (var i = 0; i < painted.faces.length; i++) {
      painted.faces[i].material = i % 3;
    }
    expect(painted.triangulate().indices.length, plain.indices.length);
    expect(painted.triangulate().vertexCount, plain.vertexCount);
  });

  test('a painted mesh writes one primitive a material', () {
    final mesh = cube();
    for (var i = 0; i < mesh.faces.length; i++) {
      mesh.faces[i].material = i < 2 ? 0 : 1;
    }

    final json = jsonOf(mesh.toGlb(materials: const [
      GlbMaterial(name: 'Brick', colour: [0.6, 0.2, 0.15, 1]),
      GlbMaterial(name: 'Glass', metallic: 1, roughness: 0.05),
    ]));

    final primitives = ((json['meshes']! as List).first
        as Map<String, Object?>)['primitives']! as List;
    expect(primitives, hasLength(2));
    expect((primitives[0] as Map)['material'], 0);
    expect((primitives[1] as Map)['material'], 1);

    final materials = json['materials']! as List;
    expect((materials[0] as Map)['name'], 'Brick');
    expect(
      ((materials[1] as Map)['pbrMetallicRoughness']
          as Map)['metallicFactor'],
      1,
    );
  });

  test('each primitive reads its own slice of the indices', () {
    final mesh = cube();
    for (var i = 0; i < mesh.faces.length; i++) {
      mesh.faces[i].material = i < 2 ? 0 : 1;
    }
    final json = jsonOf(mesh.toGlb(materials: const [
      GlbMaterial(),
      GlbMaterial(),
    ]));

    final accessors = json['accessors']! as List;
    final first = accessors[0] as Map<String, Object?>;
    final second = accessors[1] as Map<String, Object?>;

    expect(first['bufferView'], 0);
    expect(second['bufferView'], 0, reason: 'the same indices, offset into');
    expect(first['byteOffset'] ?? 0, 0);
    // Two quads is four triangles is twelve indices, two bytes each.
    expect(second['byteOffset'], 24);
    expect(first['count'], 12);
  });

  test('a face painted with a material nobody listed still gets drawn', () {
    final mesh = cube();
    mesh.faces[0].material = 9;

    final json = jsonOf(mesh.toGlb(materials: const [GlbMaterial()]));
    final primitives = ((json['meshes']! as List).first
        as Map<String, Object?>)['primitives']! as List;

    // Two primitives, and the one nobody named has no material — the file's
    // own default, which is a surface somebody can see and fix.
    expect(primitives, hasLength(2));
    expect(primitives.where((one) => (one as Map).containsKey('material')),
        hasLength(1));
  });

  test('a mesh with no materials writes none at all', () {
    final json = jsonOf(cube().toGlb());
    expect(json.containsKey('materials'), isFalse);
    final primitives = ((json['meshes']! as List).first
        as Map<String, Object?>)['primitives']! as List;
    expect(primitives, hasLength(1));
    expect((primitives.single as Map).containsKey('material'), isFalse);
  });

  test('the attribute accessors come after the index ones', () {
    final mesh = cube();
    for (var i = 0; i < mesh.faces.length; i++) {
      mesh.faces[i].material = i;
    }
    final json = jsonOf(
      mesh.toGlb(materials: [for (var i = 0; i < 6; i++) const GlbMaterial()]),
    );

    final primitives = ((json['meshes']! as List).first
        as Map<String, Object?>)['primitives']! as List;
    expect(primitives, hasLength(6));

    final attributes =
        (primitives.first as Map)['attributes']! as Map<String, Object?>;
    expect(attributes['POSITION'], 6, reason: 'six index accessors, then it');

    final accessors = json['accessors']! as List;
    expect((accessors[6] as Map)['type'], 'VEC3');
    expect((accessors[6] as Map)['min'], isA<List<Object?>>());
  });

  test('an emissive material says so and a plain one does not', () {
    expect(const GlbMaterial().toGltf().containsKey('emissiveFactor'), isFalse);
    expect(
      const GlbMaterial(emissive: [1, 0.5, 0]).toGltf()['emissiveFactor'],
      [1, 0.5, 0],
    );
    expect(const GlbMaterial(cutout: true).toGltf()['alphaMode'], 'MASK');
  });
}
