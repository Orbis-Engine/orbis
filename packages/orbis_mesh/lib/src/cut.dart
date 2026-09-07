import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import 'mesh.dart';
import 'uv.dart';

/// Where a drawn point falls on a face.
///
/// Three answers rather than two, because a point on a corner and a point on
/// an edge are cut differently: one uses a vertex that already exists and the
/// other has to make one, and treating a corner as an edge point at nought
/// leaves a duplicate vertex on top of the original.
sealed class OnFace {
  const OnFace();
}

/// On an existing corner, by its position in the face.
class AtCorner extends OnFace {
  const AtCorner(this.corner);

  final int corner;
}

/// Along the edge that leaves corner [corner], a fraction [along] of the way.
class AlongEdge extends OnFace {
  const AlongEdge(this.corner, this.along);

  final int corner;
  final double along;
}

/// Somewhere in the middle.
class InsideFace extends OnFace {
  const InsideFace();
}

/// Cutting a face into more of them.
///
/// The move for everything a primitive cannot start: a doorway in a wall, a
/// step across a floor, an edge to grab where there was not one. Without it a
/// shape can only be made out of whole faces, and anything else means going
/// back to a modelling package.
extension MeshCut on Mesh {
  /// Where [at] falls on [face], given how near counts as on.
  ///
  /// [reach] is in metres, and generous on purpose: somebody drawing on a
  /// wall means the edge they aimed at, and a cut that lands a millimetre
  /// inside leaves a sliver of a face nobody can select.
  OnFace whereOn(Face face, Vector3 at, {double reach = 0.02}) {
    final points = pointsOf(face);
    if (points.length < 3) return const InsideFace();

    var nearestCorner = -1;
    var nearest = reach;
    for (var i = 0; i < points.length; i++) {
      final away = (points[i] - at).length;
      if (away < nearest) {
        nearest = away;
        nearestCorner = i;
      }
    }
    if (nearestCorner >= 0) return AtCorner(nearestCorner);

    var bestEdge = -1;
    var bestAlong = 0.0;
    var bestAway = reach;
    for (var i = 0; i < points.length; i++) {
      final a = points[i];
      final b = points[(i + 1) % points.length];
      final along = b - a;
      final length2 = along.length2;
      if (length2 < 1e-12) continue;
      final t = (((at - a).dot(along)) / length2).clamp(0.0, 1.0);
      final away = (at - (a + along * t)).length;
      if (away >= bestAway) continue;
      bestAway = away;
      bestEdge = i;
      bestAlong = t;
    }
    if (bestEdge >= 0) return AlongEdge(bestEdge, bestAlong);

    return const InsideFace();
  }

  /// Cuts [face] along [path], replacing it with the faces that result.
  ///
  /// The path is a list of points in the object's own space. Two shapes of
  /// cut are understood, and they are the two anybody draws:
  ///
  /// - **Edge to edge.** The first and last points are on the face's boundary
  ///   and the rest are wherever. The face becomes two, one either side of
  ///   the line.
  /// - **A closed loop inside it.** The face becomes the loop, plus what is
  ///   left around it — joined by a slit from one to the other, because a
  ///   face here is a ring of corners and has nowhere to put a hole.
  ///
  /// Returns the new faces, or an empty list when the path does not cut
  /// anything — which is a refusal to be reported, not a failure: a path that
  /// starts and ends in the middle of a face does not divide it, and doing
  /// something anyway would leave geometry nobody asked for.
  List<Face> cutFace(Face face, List<Vector3> path, {double reach = 0.02}) {
    final at = faces.indexOf(face);
    if (at < 0 || path.length < 2 || face.vertices.length < 3) return const [];

    final closed = (path.first - path.last).length < reach && path.length >= 4;
    return closed
        ? _cutLoop(at, face, path, reach)
        : _cutAcross(at, face, path, reach);
  }

  /// A path from one edge of a face to another: the face becomes two.
  List<Face> _cutAcross(int at, Face face, List<Vector3> path, double reach) {
    final entry = whereOn(face, path.first, reach: reach);
    final exit = whereOn(face, path.last, reach: reach);
    if (entry is InsideFace || exit is InsideFace) return const [];

    // The outline with the two ends put into it, so both are corners of it.
    final outline = [...face.vertices];
    final inserts = <({int after, double along, int vertex})>[];

    int placeEnd(OnFace where, Vector3 point) {
      switch (where) {
        case AtCorner(:final corner):
          return face.vertices[corner];
        case AlongEdge(:final corner, :final along):
          final made = addVertex(point.clone());
          inserts.add((after: corner, along: along, vertex: made));
          return made;
        case InsideFace():
          return -1;
      }
    }

    final first = placeEnd(entry, path.first);
    final last = placeEnd(exit, path.last);
    if (first < 0 || last < 0 || first == last) return const [];

    // Later edges first, so inserting into one does not move the next.
    inserts.sort((a, b) => a.after == b.after
        ? b.along.compareTo(a.along)
        : b.after.compareTo(a.after));
    for (final one in inserts) {
      outline.insert(one.after + 1, one.vertex);
    }

    final from = outline.indexOf(first);
    final to = outline.indexOf(last);
    if (from < 0 || to < 0) return const [];

    // Everything strictly between the two ends becomes new corners, shared by
    // both halves — one vertex each, not two, or the cut is a crack.
    final middle = [
      for (var i = 1; i < path.length - 1; i++) addVertex(path[i].clone()),
    ];

    List<int> walk(int start, int end) {
      final out = <int>[];
      var i = start;
      while (true) {
        out.add(outline[i]);
        if (i == end) break;
        i = (i + 1) % outline.length;
      }
      return out;
    }

    final one = [...walk(from, to), ...middle.reversed];
    final two = [...walk(to, from), ...middle];
    if (one.length < 3 || two.length < 3) return const [];

    return _replace(at, face, [one, two]);
  }

  /// A closed loop drawn inside a face: the loop becomes a face of its own,
  /// and what is left surrounds it.
  ///
  /// Joined by a slit rather than left as a hole, because a face here is a
  /// ring of corners with nowhere to put one. The slit runs between the two
  /// nearest corners, which puts it where it is least visible — and it is
  /// invisible anyway once the inner face is extruded or painted, which is
  /// what somebody drew it for.
  List<Face> _cutLoop(int at, Face face, List<Vector3> path, double reach) {
    // The closing point is the opening one said twice.
    final loop = path.sublist(0, path.length - 1);
    if (loop.length < 3) return const [];

    final normal = normalOf(face);
    // Wound the same way as the face, so the inner face faces the same way.
    final wound = signedLoopArea(loop, normal) < 0 ? loop.reversed.toList() : loop;

    final inner = [for (final point in wound) addVertex(point.clone())];
    // A second set for the ring, so the two faces do not share corners along
    // the slit — they meet there and are not joined there.
    final ringInner = [for (final point in wound) addVertex(point.clone())];

    final outline = face.vertices;
    var bestOuter = 0;
    var bestInner = 0;
    var bestAway = double.infinity;
    for (var i = 0; i < outline.length; i++) {
      for (var j = 0; j < wound.length; j++) {
        final away = (positions[outline[i]] - wound[j]).length;
        if (away >= bestAway) continue;
        bestAway = away;
        bestOuter = i;
        bestInner = j;
      }
    }

    // Round the outside, in through the slit, round the inside the other way,
    // and back out. One face, and it has the loop cut out of it.
    final ring = <int>[
      for (var i = 0; i <= outline.length; i++)
        outline[(bestOuter + i) % outline.length],
      for (var j = 0; j <= wound.length; j++)
        ringInner[(bestInner - j + wound.length * 2) % wound.length],
    ];

    return _replace(at, face, [ring, inner]);
  }

  /// Puts new faces where an old one was, keeping what it wore.
  ///
  /// In its place rather than appended, so the order somebody made things in
  /// survives a cut — and material and smoothing carry over, because a cut
  /// divides a surface rather than making a different one. The texture rule
  /// carries too, but drawn coordinates do not: they belonged to corners that
  /// are no longer all there.
  List<Face> _replace(int at, Face face, List<List<int>> outlines) {
    final made = [
      for (final corners in outlines)
        Face(
          corners,
          material: face.material,
          smooth: face.smooth,
          uv: face.uv.isManual
              ? face.uv.copyWith(clearManual: true)
              : face.uv,
        ),
    ];

    faces.removeAt(at);
    faces.insertAll(at, made);
    return made;
  }
}

/// The signed area a loop of points encloses, seen along [normal].
///
/// Its sign says which way round the loop goes, which is what decides whether
/// a face made from it points the same way as the one it was drawn on.
double signedLoopArea(List<Vector3> loop, Vector3 normal) {
  if (loop.length < 3) return 0;
  final total = Vector3.zero();
  for (var i = 0; i < loop.length; i++) {
    total.add(loop[i].cross(loop[(i + 1) % loop.length]));
  }
  return total.dot(normal) / 2;
}

/// Whether a point is inside a face, seen from the face's own plane.
///
/// The crossing rule, which is right for the concave faces an editor makes as
/// well as the convex ones — a face cut twice is rarely convex afterwards.
bool pointInsideOutline(List<Vector2> outline, Vector2 at) {
  var inside = false;
  for (var i = 0, j = outline.length - 1; i < outline.length; j = i++) {
    final a = outline[i];
    final b = outline[j];
    if ((a.y > at.y) == (b.y > at.y)) continue;
    final crossing = (b.x - a.x) * (at.y - a.y) / (b.y - a.y) + a.x;
    if (at.x < crossing) inside = !inside;
  }
  return inside;
}

/// A face's corners on its own plane, and the axes that got them there.
({List<Vector2> flat, Vector3 u, Vector3 v}) flattenFace(
  List<Vector3> points,
  Vector3 normal,
) {
  final axes = FaceUv.axesFor(normal);
  return (
    flat: [for (final at in points) Vector2(at.dot(axes.u), at.dot(axes.v))],
    u: axes.u,
    v: axes.v,
  );
}

/// How far apart two angles are, for deciding whether a drawn path doubles
/// back on itself.
double angleGap(double a, double b) {
  var gap = (a - b) % (2 * math.pi);
  if (gap > math.pi) gap -= 2 * math.pi;
  if (gap < -math.pi) gap += 2 * math.pi;
  return gap;
}
