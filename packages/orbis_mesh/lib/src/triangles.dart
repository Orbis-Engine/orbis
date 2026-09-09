import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart';

import 'mesh.dart';
import 'uv.dart';

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
    this.groups = const [],
  });

  /// Three floats a vertex.
  final Float32List positions;

  /// Three floats a vertex, in the same order.
  final Float32List normals;

  /// Two floats a vertex.
  final Float32List uvs;

  /// Thirty-two bits each, because sixteen is not enough.
  ///
  /// Sixteen-bit indices are half the size and every mesh anybody draws by
  /// hand fits in them — and then somebody generates one. A block world's
  /// surface is a few hundred thousand vertices, and at sixty-five thousand
  /// and thirty-six an unsigned short wraps: the file writes, the loader
  /// reads it without complaint, and the mesh draws nothing, because every
  /// triangle past that point points at the wrong corners. Two hours of a
  /// perfectly valid eleven-megabyte file rendering an empty sky.
  ///
  /// Always thirty-two, rather than narrowing when a mesh happens to fit.
  /// Two bytes an index is worth less than a second code path that is only
  /// exercised by small meshes and therefore only ever right for those.
  final Uint32List indices;

  /// Which stretch of [indices] wears which material.
  ///
  /// A run rather than a material per triangle: faces are sorted by material
  /// when they are triangulated, so every material's triangles end up
  /// together and one number a group says everything. That is also the shape
  /// a graphics card wants — one draw a material, not one draw a triangle.
  final List<({int material, int start, int count})> groups;

  /// The groups as something to walk. A mesh nobody gave materials to is one
  /// run of everything, so there is no second case to write anywhere else.
  List<({int material, int start, int count})> get runs => groups.isEmpty
      ? [(material: 0, start: 0, count: indices.length)]
      : groups;

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
    final groups = <({int material, int start, int count})>[];

    // Smooth faces average their normals per shared corner, so a cylinder's
    // sides look round while its ends stay flat.
    final smoothed = _smoothNormals();

    // In material order, so each material's triangles are one run. Sorted
    // here rather than asked of the caller: the order faces are listed in is
    // the order somebody made them, and that is worth keeping for everything
    // else.
    final ordered = [...faces]
      ..sort((a, b) => a.material.compareTo(b.material));
    var group = -1;

    for (final face in ordered) {
      if (face.vertices.length < 3) continue;

      if (face.material != group) {
        group = face.material;
        groups.add((material: group, start: indicesOut.length, count: 0));
      }

      final normal = normalOf(face);
      final first = positionsOut.length ~/ 3;
      // Whatever the face says its coordinates are: a rule projected flat, or
      // the ones somebody drew.
      final coordinates = face.uv.forFace(pointsOf(face), normal);

      for (var corner = 0; corner < face.vertices.length; corner++) {
        final index = face.vertices[corner];
        final at = positions[index];
        final n = face.smooth ? (smoothed[index] ?? normal) : normal;

        positionsOut.addAll([at.x, at.y, at.z]);
        normalsOut.addAll([n.x, n.y, n.z]);
        final uv = corner < coordinates.length
            ? coordinates[corner]
            : Vector2.zero();
        uvsOut.addAll([uv.x, uv.y]);
      }

      for (final corner in cutUp(pointsOf(face), normal)) {
        indicesOut.add(first + corner);
      }
      final last = groups.removeLast();
      groups.add((
        material: last.material,
        start: last.start,
        count: indicesOut.length - last.start,
      ));
    }

    return Triangles(
      positions: Float32List.fromList(positionsOut),
      normals: Float32List.fromList(normalsOut),
      uvs: Float32List.fromList(uvsOut),
      indices: Uint32List.fromList(indicesOut),
      groups: groups,
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
}

/// Cuts a face into triangles, whatever shape its outline is.
///
/// A fan from the first corner is right only for a convex face, and the faces
/// an editor makes are routinely not: an L-shaped room is concave the moment
/// it is drawn, and a fan across one produces triangles that stick out past
/// the wall — visible as slivers of whatever is behind.
///
/// Ear clipping instead. Quadratic in the number of corners, which is nothing
/// for the ten or twenty a face has, and it handles the keyhole outlines a
/// cut produces as well as ordinary concave ones.
///
/// Returns positions within the face's own corner list, three at a time.
List<int> cutUp(List<Vector3> points, Vector3 normal) {
  final count = points.length;
  if (count < 3) return const [];
  if (count == 3) return const [0, 1, 2];

  // Flattened onto the face's own plane. The axes are right-handed about the
  // normal, so a face wound anticlockwise about it is anticlockwise here too
  // and its area is positive.
  final axes = FaceUv.axesFor(normal);
  final flat = [
    for (final at in points) Vector2(at.dot(axes.u), at.dot(axes.v)),
  ];

  var area = 0.0;
  for (var i = 0; i < count; i++) {
    final a = flat[i];
    final b = flat[(i + 1) % count];
    area += a.x * b.y - b.x * a.y;
  }

  // Worked on anticlockwise whichever way it came in, and the result mapped
  // back at the end — one direction to reason about rather than two.
  final order = [for (var i = 0; i < count; i++) i];
  if (area < 0) {
    final reversed = order.reversed.toList();
    order
      ..clear()
      ..addAll(reversed);
  }

  double cross(Vector2 a, Vector2 b, Vector2 c) =>
      (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);

  bool same(Vector2 a, Vector2 b) => (a - b).length2 < 1e-18;

  bool inside(Vector2 a, Vector2 b, Vector2 c, Vector2 at) {
    // A corner standing exactly on one of the ear's own is not in the way of
    // it. This is what makes a keyhole outline work at all: the slit is two
    // pairs of coincident corners, and counting each as blocking its own
    // triangle leaves the whole face with no ear anywhere.
    if (same(at, a) || same(at, b) || same(at, c)) return false;

    final d1 = cross(a, b, at);
    final d2 = cross(b, c, at);
    final d3 = cross(c, a, at);
    // Otherwise, on an edge counts as in: a corner lying exactly on the far
    // side of a candidate ear makes that ear unsafe, and clipping it would
    // cross the outline.
    return d1 >= 0 && d2 >= 0 && d3 >= 0;
  }

  final out = <int>[];
  final left = [...order];
  // Every pass removes one corner or gives up. Without the bound a
  // self-intersecting outline — which a cut can leave and a drawing can be
  // given — would spin here forever.
  var guard = count * count;

  while (left.length > 3 && guard-- > 0) {
    var clipped = false;

    for (var i = 0; i < left.length; i++) {
      final previous = flat[left[(i - 1 + left.length) % left.length]];
      final here = flat[left[i]];
      final next = flat[left[(i + 1) % left.length]];

      // A reflex corner is a dent, and the triangle across it is outside the
      // face rather than part of it.
      if (cross(previous, here, next) <= 0) continue;

      var clear = true;
      for (var j = 0; j < left.length; j++) {
        if (j == i ||
            j == (i - 1 + left.length) % left.length ||
            j == (i + 1) % left.length) {
          continue;
        }
        if (inside(previous, here, next, flat[left[j]])) {
          clear = false;
          break;
        }
      }
      if (!clear) continue;

      out.addAll([
        left[(i - 1 + left.length) % left.length],
        left[i],
        left[(i + 1) % left.length],
      ]);
      left.removeAt(i);
      clipped = true;
      break;
    }

    // No ear anywhere: the outline crosses itself or has no area. A fan over
    // what is left is wrong, but it is visible and it is not a crash — which
    // beats leaving a hole where a face should be.
    if (!clipped) break;
  }

  for (var i = 1; i + 1 < left.length; i++) {
    out.addAll([left[0], left[i], left[i + 1]]);
  }
  return out;
}

/// One material, as much of it as a `.glb` can carry.
///
/// Deliberately glTF's own set and no more. A material in the editor may
/// describe things this cannot — a texture's tiling, an alpha cut-off, which
/// way it faces — and those belong on the object, because they are the
/// renderer's business rather than the file's. What travels in the file is
/// what any loader would understand: the colour, how metal it is, how rough,
/// and what it gives off.
class GlbMaterial {
  const GlbMaterial({
    this.name = 'material',
    this.colour = const [0.8, 0.8, 0.8, 1.0],
    this.metallic = 0.0,
    this.roughness = 0.5,
    this.emissive = const [0.0, 0.0, 0.0],
    this.doubleSided = false,
    this.cutout = false,
  });

  final String name;

  /// Linear red, green, blue and alpha.
  final List<double> colour;
  final double metallic;
  final double roughness;
  final List<double> emissive;
  final bool doubleSided;

  /// Whether it is punched out by its alpha rather than blended. The two
  /// glTF answers that need no extra state; anything softer is a renderer
  /// setting and not a property of the file.
  final bool cutout;

  Map<String, Object?> toGltf() => {
    'name': name,
    'pbrMetallicRoughness': {
      'baseColorFactor': colour,
      'metallicFactor': metallic,
      'roughnessFactor': roughness,
    },
    if (emissive.any((one) => one > 0)) 'emissiveFactor': emissive,
    if (doubleSided) 'doubleSided': true,
    if (cutout) 'alphaMode': 'MASK',
    if (cutout) 'alphaCutoff': 0.5,
  };
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
  Uint8List toGlb({
    String name = 'mesh',
    List<GlbMaterial> materials = const [],
  }) {
    final tris = triangulate();

    // One primitive a material, which is what a glTF loader turns into one
    // draw call each. A face pointing at a material nobody listed falls back
    // to the file's default rather than to nothing: a wrong colour is
    // recoverable and a missing surface is not.
    final found = [
      for (final group in tris.runs)
        if (group.count > 0) group,
    ];
    // An empty mesh still has to be a valid file, and a file with no
    // primitives is not one.
    final used = found.isEmpty
        ? [(material: 0, start: 0, count: tris.indices.length)]
        : found;
    final wanted = <int>{for (final group in used) group.material};
    final listed = [
      for (var i = 0; i < materials.length; i++)
        if (wanted.contains(i)) i,
    ];
    final slotOf = {for (var i = 0; i < listed.length; i++) listed[i]: i};

    // glTF wants the buffer's parts aligned to four bytes, and the index
    // buffer's own component size. Laid out indices first so the alignment
    // works out without padding between the float arrays — and with
    // four-byte indices the padding below is always nothing, which is left
    // in rather than removed because it is the alignment rule that is load
    // bearing, not the fact that this particular buffer satisfies it.
    final indexBytes = tris.indices.buffer.asUint8List(
      tris.indices.offsetInBytes,
      tris.indices.lengthInBytes,
    );
    final indexPadding = (4 - indexBytes.length % 4) % 4;

    final builder = BytesBuilder()
      ..add(indexBytes)
      ..add(Uint8List(indexPadding))
      ..add(
        tris.positions.buffer.asUint8List(
          tris.positions.offsetInBytes,
          tris.positions.lengthInBytes,
        ),
      )
      ..add(
        tris.normals.buffer.asUint8List(
          tris.normals.offsetInBytes,
          tris.normals.lengthInBytes,
        ),
      )
      ..add(
        tris.uvs.buffer.asUint8List(
          tris.uvs.offsetInBytes,
          tris.uvs.lengthInBytes,
        ),
      );
    final binary = builder.toBytes();

    final indexEnd = indexBytes.length + indexPadding;
    final positionEnd = indexEnd + tris.positions.lengthInBytes;
    final normalEnd = positionEnd + tris.normals.lengthInBytes;

    final box = bounds;
    final json = _json({
      'asset': {'version': '2.0', 'generator': 'Orbis'},
      'scene': 0,
      'scenes': [
        {
          'nodes': [0],
        },
      ],
      'nodes': [
        {'mesh': 0, 'name': name},
      ],
      'meshes': [
        {
          'name': name,
          'primitives': [
            for (var i = 0; i < used.length; i++)
              {
                // The attribute accessors come after every index accessor,
                // so where they are depends on how many materials the mesh
                // ended up with.
                'attributes': {
                  'POSITION': used.length,
                  'NORMAL': used.length + 1,
                  'TEXCOORD_0': used.length + 2,
                },
                'indices': i,
                'mode': 4,
                if (slotOf.containsKey(used[i].material))
                  'material': slotOf[used[i].material],
              },
          ],
        },
      ],
      if (listed.isNotEmpty)
        'materials': [for (final at in listed) materials[at].toGltf()],
      'accessors': [
        // One accessor a group, all over the same buffer view: the indices
        // are already sorted so each material's are a contiguous run, and a
        // byte offset is cheaper than a second copy of them.
        for (final group in used)
          {
            'bufferView': 0,
            'byteOffset': group.start * 4,
            'componentType': 5125, // unsigned int
            'count': group.count,
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
