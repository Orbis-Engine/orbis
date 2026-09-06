import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import 'mesh.dart';

/// A shape drawn as an outline and then pulled up.
///
/// The other way of making geometry from the primitives: instead of choosing
/// a box and squashing it, somebody draws the plan of a room, a path or a
/// pond and gives it a height. Almost everything in a level that is not a box
/// is one of these, and doing it with box primitives means twenty of them and
/// a seam at every join.
///
/// The points are kept, not just the mesh they made. That is the whole
/// difference between this and drawing a shape once: a wall can be moved a
/// week later by dragging the corner it belongs to, and the room closes up
/// again.
class PolyShape {
  PolyShape({
    List<Vector3>? points,
    this.height = 2.0,
    this.flipped = false,
  }) : points = points ?? [];

  /// The outline, in order, in the object's own space.
  ///
  /// Any plane, not just the ground: they are projected onto the plane they
  /// best fit, so a shape drawn on a sloping roof stays on it.
  final List<Vector3> points;

  /// How far it is pulled up from the outline, along the plane's normal.
  /// Negative pulls it the other way; nought leaves a flat surface, which is
  /// a legitimate thing to want and is how a floor is made.
  double height;

  /// Whether the outline was drawn the other way round.
  ///
  /// A plan drawn clockwise and one drawn anticlockwise are the same room,
  /// and somebody drawing one is not thinking about winding. This is worked
  /// out rather than asked for; the flag is here so it can be overridden when
  /// the guess is wrong, which happens on a shape drawn nearly edge-on.
  bool flipped;

  bool get isDrawable => points.length >= 3;

  /// The plane the points best lie on: a middle, and a direction.
  ///
  /// Newell's method over the outline, the same as a face's normal and for
  /// the same reason — points drawn by hand are never quite in a plane, and
  /// the cross product of any two of them is whichever answer those two
  /// happen to give.
  ({Vector3 centre, Vector3 normal}) get plane {
    final centre = Vector3.zero();
    for (final at in points) {
      centre.add(at);
    }
    if (points.isNotEmpty) centre.scale(1 / points.length);

    final normal = Vector3.zero();
    for (var i = 0; i < points.length; i++) {
      final here = points[i];
      final next = points[(i + 1) % points.length];
      normal
        ..x += (here.y - next.y) * (here.z + next.z)
        ..y += (here.z - next.z) * (here.x + next.x)
        ..z += (here.x - next.x) * (here.y + next.y);
    }

    return (
      centre: centre,
      normal: normal.length2 < 1e-20 ? Vector3(0, 1, 0) : normal.normalized(),
    );
  }

  /// The shape as geometry: a top, a bottom and a wall between them.
  ///
  /// An empty mesh below three points, because two points are a line and a
  /// line is not a thing that can be drawn — and something degenerate instead
  /// would put a shape in the scene that renders as nothing and cannot be
  /// selected.
  ///
  /// Built here rather than by extruding a cap, because an extrude leaves the
  /// bottom open. A room somebody drew is a solid.
  Mesh build() {
    final mesh = Mesh();
    if (!isDrawable) return mesh;

    final normal = plane.normal;

    // Which way is up for this shape. A plan drawn clockwise and one drawn
    // anticlockwise are the same room, and a negative height is the same
    // shape pulled the other way — so both are settled here, once, by turning
    // the outline over rather than by two more cases further down.
    final reverse = flipped != (height < 0);
    final outline = reverse ? points.reversed.toList() : points.toList();
    final up = reverse ? -normal : normal;
    final far = height.abs();

    for (final at in outline) {
      mesh.addVertex(at.clone());
    }
    final count = outline.length;

    if (far < 1e-9) {
      // Flat, which is how a floor or a lake is made and is a legitimate
      // thing to ask for.
      mesh.addFace([for (var i = 0; i < count; i++) i]);
      return mesh;
    }

    for (final at in outline) {
      mesh.addVertex(at + up * far);
    }

    // The face at the outline is the underside, so it is wound the other way.
    mesh.addFace([for (var i = count - 1; i >= 0; i--) i]);
    mesh.addFace([for (var i = 0; i < count; i++) count + i]);

    // And the wall: one quad an edge, wound to face outwards.
    for (var i = 0; i < count; i++) {
      final next = (i + 1) % count;
      mesh.addFace([i, next, count + next, count + i]);
    }

    return mesh;
  }

  /// Where a point on the drawing plane is, given a ray.
  ///
  /// Used while drawing: the pointer is a ray into the world and a point has
  /// to land on the plane being drawn on. Null when the ray runs parallel to
  /// it, which is somebody looking along the surface they are drawing on and
  /// is a question with no answer.
  static Vector3? onPlane(
    Vector3 origin,
    Vector3 direction,
    Vector3 planePoint,
    Vector3 planeNormal,
  ) {
    final slope = planeNormal.dot(direction);
    if (slope.abs() < 1e-9) return null;
    final away = planeNormal.dot(planePoint - origin) / slope;
    // Behind the camera is not on the plane in front of it.
    if (away < 0) return null;
    return origin + direction * away;
  }

  PolyShape copy() => PolyShape(
        points: [for (final at in points) at.clone()],
        height: height,
        flipped: flipped,
      );

  Map<String, Object?> toJson() => {
        'points': [
          for (final at in points) ...[at.x, at.y, at.z],
        ],
        'height': height,
        if (flipped) 'flipped': true,
      };

  static PolyShape? fromJson(Object? value) {
    if (value is! Map) return null;
    final map = value.cast<String, Object?>();
    final raw = map['points'];
    if (raw is! List) return null;

    final points = <Vector3>[];
    for (var i = 0; i + 2 < raw.length; i += 3) {
      final x = raw[i], y = raw[i + 1], z = raw[i + 2];
      if (x is! num || y is! num || z is! num) continue;
      points.add(Vector3(x.toDouble(), y.toDouble(), z.toDouble()));
    }

    return PolyShape(
      points: points,
      height: map['height'] is num ? (map['height']! as num).toDouble() : 2.0,
      flipped: map['flipped'] == true,
    );
  }
}

/// How far apart two points have to be for the second to count as a new one.
///
/// Somebody clicking twice in the same place means one point. Without this a
/// double-click leaves a zero-length edge, which is a wall of no width that
/// nothing can be done with afterwards.
const double kSamePoint = 1e-4;

/// Whether adding [at] to [points] would close the outline rather than
/// extend it — a click back on the first point, which is how somebody says
/// they are finished.
bool closesOutline(List<Vector3> points, Vector3 at, {double reach = 0.15}) =>
    points.length >= 3 && (points.first - at).length < reach;

/// Whether a point is far enough from the last one to be worth adding.
bool isNewPoint(List<Vector3> points, Vector3 at) =>
    points.isEmpty || (points.last - at).length > kSamePoint;

/// The area an outline encloses, seen from its own plane.
///
/// Signed, so its sign says which way round the outline was drawn. Used to
/// decide whether a shape needs turning over, and to refuse one that encloses
/// nothing.
double signedAreaOf(List<Vector3> points, Vector3 normal) {
  if (points.length < 3) return 0;
  final total = Vector3.zero();
  for (var i = 0; i < points.length; i++) {
    total.add(points[i].cross(points[(i + 1) % points.length]));
  }
  return total.dot(normal) / 2;
}

/// Whether an outline crosses itself.
///
/// A figure of eight is not a room, and the triangulation of one is a mess
/// of overlapping faces rather than an error — so it is worth saying no
/// before the shape exists rather than leaving somebody to work out why it
/// looks wrong.
bool outlineCrosses(List<Vector3> points, Vector3 normal) {
  if (points.length < 4) return false;

  // Flattened onto the plane, because "crosses" is a question about the
  // drawing and not about the world.
  final away = normal.x.abs() < 0.9 ? Vector3(1, 0, 0) : Vector3(0, 1, 0);
  final u = normal.cross(away).normalized();
  final v = normal.cross(u).normalized();
  final flat = [for (final at in points) Vector2(at.dot(u), at.dot(v))];

  for (var i = 0; i < flat.length; i++) {
    final a1 = flat[i];
    final a2 = flat[(i + 1) % flat.length];
    for (var j = i + 1; j < flat.length; j++) {
      // Neighbouring edges share a corner and always "meet" there.
      if (j == i || (j + 1) % flat.length == i || j == (i + 1) % flat.length) {
        continue;
      }
      final b1 = flat[j];
      final b2 = flat[(j + 1) % flat.length];
      if (_segmentsCross(a1, a2, b1, b2)) return true;
    }
  }
  return false;
}

bool _segmentsCross(Vector2 a1, Vector2 a2, Vector2 b1, Vector2 b2) {
  double side(Vector2 a, Vector2 b, Vector2 at) =>
      (b.x - a.x) * (at.y - a.y) - (b.y - a.y) * (at.x - a.x);

  final d1 = side(a1, a2, b1);
  final d2 = side(a1, a2, b2);
  final d3 = side(b1, b2, a1);
  final d4 = side(b1, b2, a2);

  // Strictly opposite sides both ways. Touching at a point is not crossing:
  // an outline that comes back to graze itself is odd but drawable, and
  // refusing it would refuse a lot of legitimate shapes to catch one.
  return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
      ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0));
}

/// How far a point is from a line between two others, in a plane.
double distanceToSegment(Vector2 at, Vector2 a, Vector2 b) {
  final along = b - a;
  final length2 = along.length2;
  if (length2 < 1e-12) return (at - a).length;
  final t = (((at - a).dot(along)) / length2).clamp(0.0, 1.0);
  return (at - (a + along * t)).length;
}

/// The smallest turn between two directions, for the tools that care.
double turnBetween(Vector2 a, Vector2 b) =>
    math.atan2(a.x * b.y - a.y * b.x, a.dot(b));
