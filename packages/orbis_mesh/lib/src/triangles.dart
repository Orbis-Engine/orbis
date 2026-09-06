import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart';

import 'mesh.dart';

/// A mesh as a renderer takes it: triangles, with a normal and a texture
/// coordinate on every corner.
///
/// The other direction from everything else here. Editing works on faces of
/// any number of corners because that is what somebody drew; drawing works on
/// triangles with one normal each because that is what a graphics card takes.
/// This is the one place the two meet.
class Triangles {
  const Triangles({
    required this.positions,
    required this.normals,
    required this.uvs,
    required this.indices,
  });

  /// Three floats a vertex.
  final Float32List positions;

  /// Three floats a vertex, in the same order.
  final Float32List normals;

  /// Two floats a vertex.
  final Float32List uvs;

  final Uint16List indices;

  int get vertexCount => positions.length ~/ 3;
  int get triangleCount => indices.length ~/ 3;
}

/// Turning faces into triangles.
extension MeshTriangles on Mesh {
  /// The mesh, ready to draw.
  ///
  /// Corners are not shared between faces unless the faces are smooth. A cube
  /// has eight corners and twenty-four vertices, because each one needs three
  /// different normals — sharing them is what makes a box look like a
  /// deflated ball.
  Triangles triangulate() {
    final positionsOut = <double>[];
    final normalsOut = <double>[];
    final uvsOut = <double>[];
    final indicesOut = <int>[];

    // Smooth faces average their normals per shared corner, so a cylinder's
    // sides look round while its ends stay flat.
    final smoothed = _smoothNormals();

    for (final face in faces) {
      if (face.vertices.length < 3) continue;

      final normal = normalOf(face);
      final axes = _uvAxes(normal);
      final first = positionsOut.length ~/ 3;

      for (final index in face.vertices) {
        final at = positions[index];
        final n = face.smooth ? (smoothed[index] ?? normal) : normal;

        positionsOut.addAll([at.x, at.y, at.z]);
        normalsOut.addAll([n.x, n.y, n.z]);
        // Projected onto the two axes most across the face: a flat unwrap,
        // which is right for a wall and wrong for a face somebody wants to
        // paint. Good enough to see a texture's scale, which is what it is
        // for until there is a UV editor.
        uvsOut.addAll([at.dot(axes.u), at.dot(axes.v)]);
      }

      // A fan from the first corner. Right for anything convex, and for the
      // concave faces an editor makes it produces triangles that overlap
      // rather than gaps — visible, and not a crash.
      for (var i = 1; i + 1 < face.vertices.length; i++) {
        indicesOut.addAll([first, first + i, first + i + 1]);
      }
    }

    return Triangles(
      positions: Float32List.fromList(positionsOut),
      normals: Float32List.fromList(normalsOut),
      uvs: Float32List.fromList(uvsOut),
      indices: Uint16List.fromList(indicesOut),
    );
  }

  /// A normal per point, averaged over the smooth faces using it.
  Map<int, Vector3> _smoothNormals() {
    final sums = <int, Vector3>{};
    for (final face in faces) {
      if (!face.smooth) continue;
      final normal = normalOf(face);
      // Weighted by area, so a long thin face does not count as much as the
      // broad one beside it — which is what makes a cylinder's seam invisible.
      final weight = areaOf(face);
      for (final index in face.vertices) {
        (sums[index] ??= Vector3.zero()).add(normal * weight);
      }
    }

    return {
      for (final entry in sums.entries)
        entry.key: entry.value.length2 < 1e-20
            ? Vector3(0, 1, 0)
            : entry.value.normalized(),
    };
  }

  /// Two axes across a face, for a flat unwrap.
  ({Vector3 u, Vector3 v}) _uvAxes(Vector3 normal) {
    // Whichever world axis the face is least aligned with, so the two axes
    // that come out of it are never parallel to the normal.
    final away = normal.x.abs() < 0.9 ? Vector3(1, 0, 0) : Vector3(0, 1, 0);
    final u = normal.cross(away).normalized();
    return (u: u, v: normal.cross(u).normalized());
  }
}

/// Writing a mesh as a `.glb`, which the renderer already knows how to load.
///
/// A shape made in the editor becomes a file, and everything downstream — the
/// loader, the instancing, the shadow pass — treats it exactly as it treats a
/// model somebody exported from Blender. The alternative is a second path
/// through the renderer for geometry that came from here, and two paths is two
/// things to keep working.
extension MeshGlb on Mesh {
  /// This mesh as a binary glTF file.
  Uint8List toGlb({String name = 'mesh'}) {
    final tris = triangulate();

    // glTF wants the buffer's parts aligned to four bytes, and the index
    // buffer's own component size. Laid out indices first so the alignment
    // works out without padding between the float arrays.
    final indexBytes = tris.indices.buffer.asUint8List(
      tris.indices.offsetInBytes,
      tris.indices.lengthInBytes,
    );
    final indexPadding = (4 - indexBytes.length % 4) % 4;

    final builder = BytesBuilder()
      ..add(indexBytes)
      ..add(Uint8List(indexPadding))
      ..add(tris.positions.buffer.asUint8List(
        tris.positions.offsetInBytes,
        tris.positions.lengthInBytes,
      ))
      ..add(tris.normals.buffer.asUint8List(
        tris.normals.offsetInBytes,
        tris.normals.lengthInBytes,
      ))
      ..add(tris.uvs.buffer.asUint8List(
        tris.uvs.offsetInBytes,
        tris.uvs.lengthInBytes,
      ));
    final binary = builder.toBytes();

    final indexEnd = indexBytes.length + indexPadding;
    final positionEnd = indexEnd + tris.positions.lengthInBytes;
    final normalEnd = positionEnd + tris.normals.lengthInBytes;

    final box = bounds;
    final json = _json({
      'asset': {'version': '2.0', 'generator': 'Orbis'},
      'scene': 0,
      'scenes': [
        {'nodes': [0]},
      ],
      'nodes': [
        {'mesh': 0, 'name': name},
      ],
      'meshes': [
        {
          'name': name,
          'primitives': [
            {
              'attributes': {'POSITION': 1, 'NORMAL': 2, 'TEXCOORD_0': 3},
              'indices': 0,
              'mode': 4,
            },
          ],
        },
      ],
      'accessors': [
        {
          'bufferView': 0,
          'componentType': 5123, // unsigned short
          'count': tris.indices.length,
          'type': 'SCALAR',
        },
        {
          'bufferView': 1,
          'componentType': 5126, // float
          'count': tris.vertexCount,
          'type': 'VEC3',
          // Required on POSITION, and the loader uses it to size the
          // bounding box rather than walking every vertex again.
          'min': [box.min.x, box.min.y, box.min.z],
          'max': [box.max.x, box.max.y, box.max.z],
        },
        {
          'bufferView': 2,
          'componentType': 5126,
          'count': tris.vertexCount,
          'type': 'VEC3',
        },
        {
          'bufferView': 3,
          'componentType': 5126,
          'count': tris.vertexCount,
          'type': 'VEC2',
        },
      ],
      'bufferViews': [
        {'buffer': 0, 'byteOffset': 0, 'byteLength': indexBytes.length},
        {
          'buffer': 0,
          'byteOffset': indexEnd,
          'byteLength': tris.positions.lengthInBytes,
        },
        {
          'buffer': 0,
          'byteOffset': positionEnd,
          'byteLength': tris.normals.lengthInBytes,
        },
        {
          'buffer': 0,
          'byteOffset': normalEnd,
          'byteLength': tris.uvs.lengthInBytes,
        },
      ],
      'buffers': [
        {'byteLength': binary.length},
      ],
    });

    final jsonPadding = (4 - json.length % 4) % 4;
    final jsonChunk = BytesBuilder()
      ..add(json)
      // Padded with spaces rather than zeros, which the specification asks for
      // so the chunk is still valid JSON if anybody looks at it.
      ..add(Uint8List(jsonPadding)..fillRange(0, jsonPadding, 0x20));
    final jsonBytes = jsonChunk.toBytes();

    final total = 12 + 8 + jsonBytes.length + 8 + binary.length;
    final out = ByteData(total);
    var at = 0;

    void word(int value) {
      out.setUint32(at, value, Endian.little);
      at += 4;
    }

    word(0x46546C67); // 'glTF'
    word(2);
    word(total);

    word(jsonBytes.length);
    word(0x4E4F534A); // 'JSON'
    for (final byte in jsonBytes) {
      out.setUint8(at++, byte);
    }

    word(binary.length);
    word(0x004E4942); // 'BIN'
    for (final byte in binary) {
      out.setUint8(at++, byte);
    }

    return out.buffer.asUint8List();
  }

  static Uint8List _json(Map<String, Object?> value) =>
      Uint8List.fromList(_encode(value).codeUnits);

  static String _encode(Object? value) {
    if (value is Map) {
      return '{${value.entries.map((e) => '"${e.key}":${_encode(e.value)}').join(',')}}';
    }
    if (value is List) {
      return '[${value.map(_encode).join(',')}]';
    }
    if (value is String) return '"$value"';
    if (value is double) {
      // Whole numbers as integers: glTF is fussy about which fields are
      // integers, and a count written as 12.0 is a file some loaders refuse.
      return value == value.roundToDouble() && value.abs() < 1e15
          ? '${value.round()}'
          : '$value';
    }
    if (value is num || value is bool) return '$value';
    return 'null';
  }
}

/// A number the tests use to say two directions are the same.
double angleBetween(Vector3 a, Vector3 b) =>
    math.acos(a.normalized().dot(b.normalized()).clamp(-1.0, 1.0));
