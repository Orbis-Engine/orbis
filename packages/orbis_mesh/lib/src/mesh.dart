import 'package:vector_math/vector_math_64.dart';

import 'uv.dart';

/// One flat surface, named by the corners it joins.
///
/// Any number of corners, not three. A cube has six faces and not twelve
/// triangles, and every operation here — extruding, insetting, flipping —
/// means something on a quad and something fiddlier on the two triangles it
/// was cut into. Triangles are what the renderer is given at the end, not what
/// the editing works on.
class Face {
  Face(this.vertices, {this.material = 0, this.smooth = false, FaceUv? uv})
      : uv = uv ?? const FaceUv();

  /// Indices into the mesh's positions, going round the face.
  ///
  /// The order decides which way it faces: counter-clockwise seen from the
  /// front, which is the convention glTF, Filament and OpenGL all share.
  final List<int> vertices;

  /// Which material this face wears. An index rather than a name, so a mesh
  /// carries no strings and a face can be re-pointed without a lookup.
  int material;

  /// How this face gets its texture coordinates.
  ///
  /// Automatic by default, which means a rule rather than coordinates: the
  /// face is projected flat and then moved, turned and scaled. It survives
  /// the face being extruded, moved, resized or cut, because it is worked out
  /// again from whatever the face is now.
  FaceUv uv;

  /// Whether this face's normals are shared with its neighbours.
  ///
  /// Flat is the default because a shape somebody just made out of boxes
  /// should look like boxes. Smoothing is something they turn on for the
  /// cylinder, not something they turn off for everything else.
  bool smooth;

  int get length => vertices.length;

  bool get isTriangle => vertices.length == 3;
  bool get isQuad => vertices.length == 4;

  Face copy() =>
      Face([...vertices], material: material, smooth: smooth, uv: uv);

  Map<String, Object?> toJson() => {
        'v': vertices,
        if (material != 0) 'm': material,
        if (smooth) 's': true,
        if (uv.toJson().isNotEmpty) 'uv': uv.toJson(),
      };

  static Face? fromJson(Object? value) {
    if (value is! Map) return null;
    final map = value.cast<String, Object?>();
    final raw = map['v'];
    if (raw is! List || raw.length < 3) return null;

    return Face(
      [
        for (final index in raw)
          if (index is int) index,
      ],
      material: map['m'] is int ? map['m']! as int : 0,
      smooth: map['s'] == true,
      uv: FaceUv.fromJson(map['uv']),
    );
  }
}

/// Geometry somebody is building.
///
/// Positions and faces, and nothing else. Not a half-edge structure: those are
/// faster to walk and they refuse to hold anything that is not a closed
/// surface, and half of what somebody builds in an editor — a wall, a floor, a
/// shape mid-extrude — is not one. This holds whatever was made and says what
/// it can about it.
class Mesh {
  Mesh({List<Vector3>? positions, List<Face>? faces})
      : positions = positions ?? [],
        faces = faces ?? [];

  final List<Vector3> positions;
  final List<Face> faces;

  int get vertexCount => positions.length;
  int get faceCount => faces.length;

  bool get isEmpty => faces.isEmpty;

  Mesh copy() => Mesh(
        positions: [for (final at in positions) at.clone()],
        faces: [for (final face in faces) face.copy()],
      );

  /// The corners of a face, as points.
  List<Vector3> pointsOf(Face face) => [
        for (final index in face.vertices)
          if (index >= 0 && index < positions.length) positions[index],
      ];

  /// Which way a face points.
  ///
  /// Newell's method rather than the cross product of the first two edges: a
  /// quad whose corners are not quite in a plane — which is most of them once
  /// anybody has moved a vertex — has no single normal, and the cross product
  /// of one corner's edges is whichever answer that corner happens to give.
  /// This is the average of all of them.
  Vector3 normalOf(Face face) {
    final points = pointsOf(face);
    if (points.length < 3) return Vector3(0, 1, 0);

    final normal = Vector3.zero();
    for (var i = 0; i < points.length; i++) {
      final here = points[i];
      final next = points[(i + 1) % points.length];
      normal
        ..x += (here.y - next.y) * (here.z + next.z)
        ..y += (here.z - next.z) * (here.x + next.x)
        ..z += (here.x - next.x) * (here.y + next.y);
    }

    // A degenerate face — every corner in a line, or all in one place — has no
    // direction. Up is a lie, but it is a lie that does not produce NaN in
    // everything downstream.
    return normal.length2 < 1e-20 ? Vector3(0, 1, 0) : normal.normalized();
  }

  /// The middle of a face.
  Vector3 centreOf(Face face) {
    final points = pointsOf(face);
    if (points.isEmpty) return Vector3.zero();

    final sum = Vector3.zero();
    for (final point in points) {
      sum.add(point);
    }
    return sum..scale(1 / points.length);
  }

  /// How much surface a face has.
  ///
  /// Half the length of the sum of the corner cross products, which is exact
  /// for any face in a plane however bent its outline is — a fan from the
  /// first corner is not, and a face cut twice is rarely convex. A face whose
  /// corners are not quite in a plane gets the area of its projection, which
  /// is the only answer that means anything for one.
  double areaOf(Face face) {
    final points = pointsOf(face);
    if (points.length < 3) return 0;

    final total = Vector3.zero();
    for (var i = 0; i < points.length; i++) {
      total.add(points[i].cross(points[(i + 1) % points.length]));
    }
    return total.length / 2;
  }

  /// The box everything sits inside, as its smallest and largest corner.
  ({Vector3 min, Vector3 max}) get bounds {
    if (positions.isEmpty) {
      return (min: Vector3.zero(), max: Vector3.zero());
    }

    final min = positions.first.clone();
    final max = positions.first.clone();
    for (final at in positions) {
      Vector3.min(min, at, min);
      Vector3.max(max, at, max);
    }
    return (min: min, max: max);
  }

  /// Adds a point and says where it went.
  int addVertex(Vector3 at) {
    positions.add(at.clone());
    return positions.length - 1;
  }

  /// Adds a face over points that are already there.
  Face addFace(List<int> vertices, {int material = 0, bool smooth = false}) {
    final face = Face(vertices, material: material, smooth: smooth);
    faces.add(face);
    return face;
  }

  /// Moves every point.
  void transform(Matrix4 by) {
    for (final at in positions) {
      at.setFrom(by.transformed3(at));
    }
  }

  /// Turns every face the other way.
  ///
  /// What a shape needs when it has been mirrored: reflecting the points turns
  /// the winding inside out, and a mesh that is inside out is a mesh that is
  /// invisible from the side somebody is looking at.
  void flip() {
    for (final face in faces) {
      final reversed = face.vertices.reversed.toList();
      face.vertices
        ..clear()
        ..addAll(reversed);
    }
  }

  /// Everything from another mesh, added to this one.
  void merge(Mesh other) {
    final offset = positions.length;
    for (final at in other.positions) {
      positions.add(at.clone());
    }
    for (final face in other.faces) {
      faces.add(Face(
        [for (final index in face.vertices) index + offset],
        material: face.material,
        smooth: face.smooth,
      ));
    }
  }

  Map<String, Object?> toJson() => {
        'positions': [
          for (final at in positions) ...[at.x, at.y, at.z],
        ],
        'faces': [for (final face in faces) face.toJson()],
      };

  static Mesh? fromJson(Object? value) {
    if (value is! Map) return null;
    final map = value.cast<String, Object?>();

    final raw = map['positions'];
    if (raw is! List) return null;

    final positions = <Vector3>[];
    for (var i = 0; i + 2 < raw.length; i += 3) {
      positions.add(Vector3(
        (raw[i] as num?)?.toDouble() ?? 0,
        (raw[i + 1] as num?)?.toDouble() ?? 0,
        (raw[i + 2] as num?)?.toDouble() ?? 0,
      ));
    }

    final rawFaces = map['faces'];
    return Mesh(
      positions: positions,
      faces: [
        if (rawFaces is List)
          for (final entry in rawFaces)
            if (Face.fromJson(entry) case final face?)
              if (face.vertices.every((i) => i >= 0 && i < positions.length))
                face,
      ],
    );
  }
}
