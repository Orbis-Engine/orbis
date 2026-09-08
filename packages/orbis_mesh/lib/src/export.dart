import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart';

import 'mesh.dart';
import 'triangles.dart';

/// The formats a mesh can leave in.
///
/// Not because the engine needs them — it reads its own `.glb` — but because
/// a shape blocked out here is often the start of something that gets
/// finished somewhere else, and a tool that can only be a dead end is a tool
/// people stop putting real work into.
enum MeshFormat {
  /// Wavefront OBJ. The one everything reads, and the only one here that
  /// keeps faces as they were drawn rather than cutting them into triangles.
  /// Carries materials, in a `.mtl` beside it.
  obj('OBJ', 'obj'),

  /// Binary glTF, which is what the engine itself loads. The right answer
  /// for anything going into another engine.
  glb('glTF binary', 'glb'),

  /// Stereolithography. Triangles and nothing else — no colour, no
  /// coordinates, not even shared corners. What a printer takes.
  stl('STL', 'stl'),

  /// Polygon file format. Triangles with their normals and texture
  /// coordinates, and the one scanning and point-cloud tools speak.
  ply('PLY', 'ply');

  const MeshFormat(this.label, this.extension);

  final String label;
  final String extension;

  /// Whether the format carries materials of its own.
  bool get hasMaterials => this == obj || this == glb;

  /// Whether writing it produces a second file beside the first.
  bool get hasSidecar => this == obj;
}

/// One file, and what it is called.
class Written {
  const Written(this.name, this.bytes);

  /// The file name, extension and all. Relative: whoever asked decides where
  /// it goes.
  final String name;
  final Uint8List bytes;

  String get text => utf8.decode(bytes);
}

/// Writing a mesh out.
extension MeshExport on Mesh {
  /// This mesh in [format], as the files it takes.
  ///
  /// A list because one of them is two files: an OBJ that mentions materials
  /// is useless without the `.mtl` it names, and handing back only the first
  /// leaves somebody with a grey model and no clue why.
  List<Written> writeAs(
    MeshFormat format, {
    String name = 'mesh',
    List<GlbMaterial> materials = const [],
    bool binary = true,
  }) {
    switch (format) {
      case MeshFormat.obj:
        return toObj(name: name, materials: materials);
      case MeshFormat.glb:
        return [Written('$name.glb', toGlb(name: name, materials: materials))];
      case MeshFormat.stl:
        return [Written('$name.stl', toStl(name: name, binary: binary))];
      case MeshFormat.ply:
        return [Written('$name.ply', toPly(binary: binary))];
    }
  }

  /// Wavefront OBJ, and the material library it names.
  ///
  /// Faces are written as they are — a quad stays a quad — because OBJ is the
  /// only common format that can hold one, and cutting them up on the way out
  /// throws away the thing somebody was working on.
  List<Written> toObj({
    String name = 'mesh',
    List<GlbMaterial> materials = const [],
  }) {
    final out = StringBuffer()
      ..writeln('# Written by Orbis')
      ..writeln('# $vertexCount vertices, $faceCount faces');
    if (materials.isNotEmpty) out.writeln('mtllib $name.mtl');
    out.writeln('o $name');

    for (final at in positions) {
      out.writeln('v ${_number(at.x)} ${_number(at.y)} ${_number(at.z)}');
    }

    // Coordinates and normals are per corner rather than per vertex, because
    // that is what they are: a cube's corner has three normals and belongs to
    // three faces. OBJ indexes them separately, which is the whole reason it
    // can say so.
    final uvs = <String>[];
    final normals = <String>[];
    final perFace = <List<({int uv, int normal})>>[];

    for (final face in faces) {
      final normal = normalOf(face);
      final coordinates = face.uv.forFace(pointsOf(face), normal);
      final corners = <({int uv, int normal})>[];

      for (var i = 0; i < face.vertices.length; i++) {
        final uv = i < coordinates.length ? coordinates[i] : Vector2.zero();
        uvs.add('vt ${_number(uv.x)} ${_number(uv.y)}');
        normals.add(
          'vn ${_number(normal.x)} ${_number(normal.y)} ${_number(normal.z)}',
        );
        corners.add((uv: uvs.length, normal: normals.length));
      }
      perFace.add(corners);
    }

    for (final line in uvs) {
      out.writeln(line);
    }
    for (final line in normals) {
      out.writeln(line);
    }

    // Grouped by material, so a reader makes one object a material rather
    // than switching back and forth down the file.
    final order = [for (var i = 0; i < faces.length; i++) i]
      ..sort((a, b) => faces[a].material.compareTo(faces[b].material));
    var wearing = -1;

    for (final at in order) {
      final face = faces[at];
      if (face.material != wearing) {
        wearing = face.material;
        final named = wearing >= 0 && wearing < materials.length
            ? materials[wearing].name
            : 'material$wearing';
        out.writeln('usemtl ${_word(named)}');
        if (face.smooth) {
          out.writeln('s 1');
        } else {
          out.writeln('s off');
        }
      }

      final corners = perFace[at];
      final parts = <String>[];
      for (var i = 0; i < face.vertices.length; i++) {
        // One-based, which OBJ has been since 1986 and is the commonest way
        // to write one of these that nothing will open.
        parts.add(
          '${face.vertices[i] + 1}/${corners[i].uv}/'
          '${corners[i].normal}',
        );
      }
      out.writeln('f ${parts.join(' ')}');
    }

    final files = [Written('$name.obj', _bytes(out.toString()))];
    if (materials.isNotEmpty) {
      files.add(Written('$name.mtl', _bytes(_mtl(materials))));
    }
    return files;
  }

  static String _mtl(List<GlbMaterial> materials) {
    final out = StringBuffer()..writeln('# Written by Orbis');
    for (final one in materials) {
      final c = one.colour;
      out
        ..writeln('newmtl ${_word(one.name)}')
        ..writeln('Kd ${_number(c[0])} ${_number(c[1])} ${_number(c[2])}')
        // Roughness the other way round, which is what an exponent is. The
        // mapping is a convention rather than a conversion: OBJ predates
        // anything physically based and there is no right answer, only the
        // one every other exporter uses.
        ..writeln(
          'Ns ${_number((1 - one.roughness) * (1 - one.roughness) * 900 + 1)}',
        )
        ..writeln(
          'Ks ${_number(one.metallic)} ${_number(one.metallic)} '
          '${_number(one.metallic)}',
        )
        ..writeln(
          'Ke ${_number(one.emissive[0])} ${_number(one.emissive[1])} '
          '${_number(one.emissive[2])}',
        );
      if (c.length > 3 && c[3] < 1) out.writeln('d ${_number(c[3])}');
      out.writeln('illum 2');
    }
    return out.toString();
  }

  /// Stereolithography: triangles, each with the direction it faces.
  ///
  /// Everything else is thrown away — colour, coordinates, even the fact that
  /// two triangles share a corner. That is not a shortcoming of the writer;
  /// it is what the format is, and it is why it is the one a printer takes.
  Uint8List toStl({String name = 'mesh', bool binary = true}) {
    final tris = triangulate();
    final count = tris.triangleCount;

    Vector3 corner(int at) => Vector3(
      tris.positions[at * 3],
      tris.positions[at * 3 + 1],
      tris.positions[at * 3 + 2],
    );

    if (!binary) {
      final out = StringBuffer()..writeln('solid ${_word(name)}');
      for (var i = 0; i < count; i++) {
        final a = corner(tris.indices[i * 3]);
        final b = corner(tris.indices[i * 3 + 1]);
        final c = corner(tris.indices[i * 3 + 2]);
        final normal = (b - a).cross(c - a);
        if (normal.length2 > 1e-20) normal.normalize();

        out
          ..writeln(
            '  facet normal ${_number(normal.x)} '
            '${_number(normal.y)} ${_number(normal.z)}',
          )
          ..writeln('    outer loop');
        for (final at in [a, b, c]) {
          out.writeln(
            '      vertex ${_number(at.x)} ${_number(at.y)} ${_number(at.z)}',
          );
        }
        out
          ..writeln('    endloop')
          ..writeln('  endfacet');
      }
      out.writeln('endsolid ${_word(name)}');
      return _bytes(out.toString());
    }

    final out = ByteData(84 + count * 50);
    // Eighty bytes of anything, by convention not starting with "solid" —
    // a binary file that does is read as text by half the readers there are.
    final header = utf8.encode('Orbis $name'.padRight(80).substring(0, 80));
    for (var i = 0; i < 80; i++) {
      out.setUint8(i, header[i]);
    }
    out.setUint32(80, count, Endian.little);

    var at = 84;
    void float(double value) {
      out.setFloat32(at, value, Endian.little);
      at += 4;
    }

    for (var i = 0; i < count; i++) {
      final a = corner(tris.indices[i * 3]);
      final b = corner(tris.indices[i * 3 + 1]);
      final c = corner(tris.indices[i * 3 + 2]);
      final normal = (b - a).cross(c - a);
      if (normal.length2 > 1e-20) normal.normalize();

      float(normal.x);
      float(normal.y);
      float(normal.z);
      for (final point in [a, b, c]) {
        float(point.x);
        float(point.y);
        float(point.z);
      }
      out.setUint16(at, 0, Endian.little);
      at += 2;
    }
    return out.buffer.asUint8List();
  }

  /// Polygon file format: corners with their normals and coordinates, and a
  /// list of which corners each triangle uses.
  Uint8List toPly({bool binary = true}) {
    final tris = triangulate();
    final header = StringBuffer()
      ..writeln('ply')
      ..writeln(binary ? 'format binary_little_endian 1.0' : 'format ascii 1.0')
      ..writeln('comment Written by Orbis')
      ..writeln('element vertex ${tris.vertexCount}')
      ..writeln('property float x')
      ..writeln('property float y')
      ..writeln('property float z')
      ..writeln('property float nx')
      ..writeln('property float ny')
      ..writeln('property float nz')
      ..writeln('property float s')
      ..writeln('property float t')
      ..writeln('element face ${tris.triangleCount}')
      // uchar for the count and int for the indices, which is the combination
      // every reader handles. A list of any other pair is legal and half of
      // them will not open it.
      ..writeln('property list uchar int vertex_indices')
      ..writeln('end_header');

    if (!binary) {
      final out = StringBuffer()..write(header);
      for (var i = 0; i < tris.vertexCount; i++) {
        out.writeln(
          [
            _number(tris.positions[i * 3]),
            _number(tris.positions[i * 3 + 1]),
            _number(tris.positions[i * 3 + 2]),
            _number(tris.normals[i * 3]),
            _number(tris.normals[i * 3 + 1]),
            _number(tris.normals[i * 3 + 2]),
            _number(tris.uvs[i * 2]),
            _number(tris.uvs[i * 2 + 1]),
          ].join(' '),
        );
      }
      for (var i = 0; i < tris.triangleCount; i++) {
        out.writeln(
          '3 ${tris.indices[i * 3]} ${tris.indices[i * 3 + 1]} '
          '${tris.indices[i * 3 + 2]}',
        );
      }
      return _bytes(out.toString());
    }

    final headerBytes = _bytes(header.toString());
    final body = ByteData(tris.vertexCount * 32 + tris.triangleCount * 13);
    var at = 0;

    void float(double value) {
      body.setFloat32(at, value, Endian.little);
      at += 4;
    }

    for (var i = 0; i < tris.vertexCount; i++) {
      float(tris.positions[i * 3]);
      float(tris.positions[i * 3 + 1]);
      float(tris.positions[i * 3 + 2]);
      float(tris.normals[i * 3]);
      float(tris.normals[i * 3 + 1]);
      float(tris.normals[i * 3 + 2]);
      float(tris.uvs[i * 2]);
      float(tris.uvs[i * 2 + 1]);
    }
    for (var i = 0; i < tris.triangleCount; i++) {
      body.setUint8(at++, 3);
      for (var corner = 0; corner < 3; corner++) {
        body.setInt32(at, tris.indices[i * 3 + corner], Endian.little);
        at += 4;
      }
    }

    final out = BytesBuilder()
      ..add(headerBytes)
      ..add(body.buffer.asUint8List());
    return out.toBytes();
  }
}

/// A number as a text format wants it: short, and never in exponent form.
///
/// `1e-7` is legal in every one of these formats and refused by a surprising
/// number of the things that read them.
String _number(double value) {
  if (!value.isFinite) return '0';
  if (value == value.roundToDouble() && value.abs() < 1e9) {
    return value.toStringAsFixed(1);
  }
  final text = value.toStringAsFixed(6);
  // Trailing zeros off, but never the whole fractional part: "1." is not a
  // number to some readers.
  final trimmed = text.replaceFirst(RegExp(r'0+$'), '');
  return trimmed.endsWith('.') ? '${trimmed}0' : trimmed;
}

/// A name with the spaces taken out, because these formats separate by them.
String _word(String name) {
  final cleaned = name.trim().replaceAll(RegExp(r'\s+'), '_');
  return cleaned.isEmpty ? 'unnamed' : cleaned;
}

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

/// Reading back only what a file says about its own size.
///
/// The box a model occupies, without loading the model. glTF requires every
/// POSITION accessor to carry its own minimum and maximum — precisely so a
/// reader can frame, cull or pick against a file it has not decoded — and
/// this takes it at its word.
///
/// Worth having because the editor does not hold the geometry of a model the
/// renderer loaded: it knows a path and nothing else, and without this every
/// imported model is picked and outlined as a two-metre cube whatever it
/// actually is.
({Vector3 min, Vector3 max})? boundsOfGlb(Uint8List glb) {
  if (glb.length < 20) return null;
  final data = ByteData.sublistView(glb);
  if (data.getUint32(0, Endian.little) != 0x46546C67) return null;

  final jsonLength = data.getUint32(12, Endian.little);
  if (20 + jsonLength > glb.length) return null;

  Map<String, Object?> document;
  try {
    document =
        jsonDecode(utf8.decode(glb.sublist(20, 20 + jsonLength)))
            as Map<String, Object?>;
  } on FormatException {
    return null;
  }

  final accessors = document['accessors'];
  final meshes = document['meshes'];
  if (accessors is! List || meshes is! List) return null;

  var minX = double.infinity;
  var minY = double.infinity;
  var minZ = double.infinity;
  var maxX = double.negativeInfinity;
  var maxY = double.negativeInfinity;
  var maxZ = double.negativeInfinity;
  var found = false;

  // Only the accessors a primitive actually uses for POSITION. Taking every
  // accessor with a min and a max would fold in normals, which live between
  // minus one and one and would swallow anything smaller than that.
  for (final mesh in meshes) {
    if (mesh is! Map) continue;
    final primitives = mesh['primitives'];
    if (primitives is! List) continue;

    for (final primitive in primitives) {
      if (primitive is! Map) continue;
      final attributes = primitive['attributes'];
      if (attributes is! Map) continue;
      final at = attributes['POSITION'];
      if (at is! int || at < 0 || at >= accessors.length) continue;

      final accessor = accessors[at];
      if (accessor is! Map) continue;
      final low = accessor['min'];
      final high = accessor['max'];
      if (low is! List || high is! List || low.length < 3 || high.length < 3) {
        continue;
      }
      if (low.any((one) => one is! num) || high.any((one) => one is! num)) {
        continue;
      }

      found = true;
      minX = math.min(minX, (low[0]! as num).toDouble());
      minY = math.min(minY, (low[1]! as num).toDouble());
      minZ = math.min(minZ, (low[2]! as num).toDouble());
      maxX = math.max(maxX, (high[0]! as num).toDouble());
      maxY = math.max(maxY, (high[1]! as num).toDouble());
      maxZ = math.max(maxZ, (high[2]! as num).toDouble());
    }
  }

  // The file's own node transforms are not applied. A model whose root node
  // moves or scales its mesh would be framed wrong, and that is a real gap —
  // but it is a much smaller one than treating every model as a cube, and
  // closing it means walking the node tree, which means decoding the file.
  return found
      ? (min: Vector3(minX, minY, minZ), max: Vector3(maxX, maxY, maxZ))
      : null;
}
