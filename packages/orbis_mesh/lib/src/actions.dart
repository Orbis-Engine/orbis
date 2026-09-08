import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import 'edits.dart';
import 'mesh.dart';

/// An edge, named by the two points it joins.
///
/// Ordered smallest first, so an edge shared by two faces is one edge rather
/// than two that happen to be the same.
typedef MeshEdge = (int, int);

MeshEdge edgeOf(int a, int b) => a < b ? (a, b) : (b, a);

/// The rest of what somebody does to geometry.
///
/// Separated from [MeshEdits] only by size: those are the operations a shape
/// is built out of, and these are the ones somebody reaches for once it is
/// built. Every one of them takes a selection and returns what should be
/// selected afterwards, because in a modelling tool the answer to "what now"
/// is nearly always "the thing that just appeared".
extension MeshActions on Mesh {
  // ---- looking around ----

  /// Which faces use an edge.
  List<Face> facesOn(MeshEdge edge) => [
    for (final face in faces)
      if (_hasEdge(face, edge)) face,
  ];

  bool _hasEdge(Face face, MeshEdge edge) {
    final count = face.vertices.length;
    for (var i = 0; i < count; i++) {
      if (edgeOf(face.vertices[i], face.vertices[(i + 1) % count]) == edge) {
        return true;
      }
    }
    return false;
  }

  /// Every edge in the mesh.
  Set<MeshEdge> get allEdges => edgesOf(faces);

  /// The edges nothing shares: the outline of a hole, or of a flat sheet.
  Set<MeshEdge> get openEdges {
    final counts = <MeshEdge, int>{};
    for (final face in faces) {
      for (final edge in edgesOf([face])) {
        counts[edge] = (counts[edge] ?? 0) + 1;
      }
    }
    return {
      for (final entry in counts.entries)
        if (entry.value < 2) entry.key,
    };
  }

  /// Which faces touch a point.
  List<Face> facesAt(int vertex) => [
    for (final face in faces)
      if (face.vertices.contains(vertex)) face,
  ];

  // ---- growing and shrinking a selection ----

  /// The faces next to the ones given.
  ///
  /// [withinAngle] in degrees keeps the growth on a flat area: growing across
  /// the corner of a box is rarely what somebody meant, and stopping at the
  /// fold is what makes this usable on a whole wall.
  Set<Face> grow(Iterable<Face> which, {double? withinAngle}) {
    final chosen = which.toSet();
    if (chosen.isEmpty) return chosen;

    final edges = edgesOf(chosen);
    final grown = {...chosen};

    for (final face in faces) {
      if (grown.contains(face)) continue;
      if (!edgesOf([face]).any(edges.contains)) continue;

      if (withinAngle != null) {
        final limit = math.cos(withinAngle.clamp(0, 180) * math.pi / 180);
        final fits = chosen.any(
          (already) => normalOf(face).dot(normalOf(already)) >= limit - 1e-9,
        );
        if (!fits) continue;
      }
      grown.add(face);
    }
    return grown;
  }

  /// The selection without the faces on its edge.
  Set<Face> shrink(Iterable<Face> which) {
    final chosen = which.toSet();
    if (chosen.length < 2) return {};

    final outside = <MeshEdge, int>{};
    for (final face in chosen) {
      for (final edge in edgesOf([face])) {
        outside[edge] = (outside[edge] ?? 0) + 1;
      }
    }

    return {
      for (final face in chosen)
        // A face every one of whose edges is shared with another selected
        // face is one in the middle.
        if (edgesOf([face]).every((edge) => (outside[edge] ?? 0) > 1)) face,
    };
  }

  // ---- loops and rings ----

  /// The loop of edges running through this one.
  ///
  /// A loop crosses a quad to the edge opposite and carries on. It stops at a
  /// triangle, at a hole and where it meets itself, which is what makes it
  /// useful: an edge loop is the line somebody wants to cut along, and one
  /// that wandered off through a triangle fan would not be.
  Set<MeshEdge> edgeLoop(MeshEdge from) {
    final loop = {from};

    for (final direction in const [0, 1]) {
      var current = from;
      var pivot = direction == 0 ? from.$1 : from.$2;

      while (true) {
        final next = _acrossQuad(current, pivot);
        if (next == null || loop.contains(next)) break;
        loop.add(next);
        pivot = next.$1 == pivot || next.$2 == pivot
            ? (next.$1 == pivot ? next.$2 : next.$1)
            : pivot;
        current = next;
      }
    }
    return loop;
  }

  /// The next edge of a loop: the one on the far side of the quad, sharing
  /// the point the loop is travelling through.
  MeshEdge? _acrossQuad(MeshEdge edge, int through) {
    for (final face in facesOn(edge)) {
      if (!face.isQuad) continue;

      for (final other in edgesOf([face])) {
        if (other == edge) continue;
        if (other.$1 != through && other.$2 != through) continue;
        // Two edges of a quad share the pivot; the loop wants the one that
        // continues rather than the one that turns the corner, which is the
        // one whose faces do not include the one we came through.
        final onward = facesOn(other).where((f) => f != face);
        if (onward.isEmpty) continue;
        return other;
      }
    }
    return null;
  }

  /// The ring of edges parallel to this one.
  ///
  /// A ring crosses a quad to the edge *opposite* rather than continuing
  /// through a shared point. It is what somebody selects to put a cut all the
  /// way round a cylinder.
  Set<MeshEdge> edgeRing(MeshEdge from) {
    final ring = {from};
    final queue = <MeshEdge>[from];

    while (queue.isNotEmpty) {
      final edge = queue.removeLast();
      for (final face in facesOn(edge)) {
        if (!face.isQuad) continue;
        final opposite = _oppositeEdge(face, edge);
        if (opposite == null || ring.contains(opposite)) continue;
        ring.add(opposite);
        queue.add(opposite);
      }
    }
    return ring;
  }

  MeshEdge? _oppositeEdge(Face face, MeshEdge edge) {
    final v = face.vertices;
    for (var i = 0; i < 4; i++) {
      if (edgeOf(v[i], v[(i + 1) % 4]) != edge) continue;
      return edgeOf(v[(i + 2) % 4], v[(i + 3) % 4]);
    }
    return null;
  }

  /// The faces along a loop, which is what an edge ring separates.
  Set<Face> faceLoop(Face from) {
    if (!from.isQuad) return {from};

    final loop = {from};
    for (var i = 0; i < 2; i++) {
      // The two directions across the quad: one pair of opposite edges each.
      final edge = edgeOf(from.vertices[i], from.vertices[i + 1]);
      for (final next in edgeRing(edge)) {
        loop.addAll(facesOn(next));
      }
    }
    return loop;
  }

  // ---- the actions ----

  /// Pulls every selected vertex together into one.
  ///
  /// Regardless of distance, unlike welding: this is somebody saying "these
  /// are one point now", not "tidy up what is already touching".
  int collapse(Iterable<int> which, {bool toFirst = false}) {
    final chosen = [
      for (final index in which)
        if (index >= 0 && index < positions.length) index,
    ];
    if (chosen.length < 2) return 0;

    final at = toFirst
        ? positions[chosen.first].clone()
        : chosen
              .fold(Vector3.zero(), (sum, i) => sum..add(positions[i]))
              .scaled(1 / chosen.length);

    for (final index in chosen) {
      positions[index].setFrom(at);
    }
    // Welding is what actually joins them; moving them together only makes
    // them coincident, and a face with three corners in one place is a face
    // that draws nothing rather than one that has gone.
    return weld();
  }

  /// Splits a point into one per face using it, so the faces move apart.
  ///
  /// The opposite of welding, and what somebody does before pulling one
  /// corner of a box away from the rest.
  int split(Iterable<int> which) {
    var made = 0;
    for (final index in which.toSet()) {
      final touching = facesAt(index);
      if (touching.length < 2) continue;

      // The first face keeps the original; every other gets its own copy.
      for (final face in touching.skip(1)) {
        final fresh = addVertex(positions[index]);
        for (var i = 0; i < face.vertices.length; i++) {
          if (face.vertices[i] == index) face.vertices[i] = fresh;
        }
        made++;
      }
    }
    return made;
  }

  /// Puts a face over a hole.
  ///
  /// Finds the ring of open edges the given points sit on and closes it. A
  /// hole with a hundred sides becomes a face with a hundred corners, which is
  /// something this model can hold and a triangle-only one cannot.
  List<Face> fillHole(Iterable<int> around) {
    final open = openEdges;
    if (open.isEmpty) return const [];

    final wanted = around.toSet();
    final made = <Face>[];
    final used = <MeshEdge>{};

    for (final start in open) {
      if (used.contains(start)) continue;
      if (wanted.isNotEmpty &&
          !wanted.contains(start.$1) &&
          !wanted.contains(start.$2)) {
        continue;
      }

      // Walk the border from one end until it comes back.
      final ring = <int>[start.$1, start.$2];
      used.add(start);
      var at = start.$2;

      while (true) {
        final next = open.firstWhere(
          (edge) => !used.contains(edge) && (edge.$1 == at || edge.$2 == at),
          orElse: () => (-1, -1),
        );
        if (next.$1 < 0) break;
        used.add(next);
        at = next.$1 == at ? next.$2 : next.$1;
        if (at == ring.first) break;
        ring.add(at);
      }

      if (ring.length < 3) continue;
      made.add(addFace(ring));
    }

    // Wound to match whatever is around it rather than by luck: a patch
    // facing the wrong way is a hole that looks like it is still there.
    for (final face in made) {
      final neighbours = [
        for (final edge in edgesOf([face]))
          ...facesOn(edge).where((other) => other != face),
      ];

      final average = neighbours.fold(
        Vector3.zero(),
        (sum, other) => sum..add(normalOf(other)),
      );

      // The neighbours agree when the hole is in a flat sheet. Round the lid
      // of a box they point four different ways and cancel out entirely — so
      // where they say nothing, face away from the middle of the shape, which
      // is what the outside of a closed thing means.
      final wanted = average.length2 > 1e-12
          ? average
          : centreOf(face) - _centre;
      if (normalOf(face).dot(wanted) < 0) flipFaces([face]);
    }
    return made;
  }

  /// Cuts a corner off, leaving a face where the edge was.
  List<Face> bevel(Iterable<MeshEdge> which, double distance) {
    final chosen = which.toSet();
    if (chosen.isEmpty || distance <= 0) return const [];

    final made = <Face>[];
    for (final edge in chosen) {
      final sides = facesOn(edge);
      if (sides.length != 2) continue;

      // Each end of the edge is pulled back along both faces, and the four
      // points that leaves become the new face.
      final corners = <int>[];
      for (final vertex in [edge.$1, edge.$2]) {
        for (final face in sides) {
          final towards = centreOf(face) - positions[vertex];
          final step = towards.length <= distance
              ? towards
              : towards.normalized() * distance;
          final moved = addVertex(positions[vertex] + step);
          corners.add(moved);

          for (var i = 0; i < face.vertices.length; i++) {
            if (face.vertices[i] == vertex) face.vertices[i] = moved;
          }
        }
      }

      if (corners.length == 4) {
        made.add(addFace([corners[0], corners[1], corners[3], corners[2]]));
        final neighbours = sides
            .map(normalOf)
            .fold(Vector3.zero(), (sum, normal) => sum..add(normal));
        if (normalOf(made.last).dot(neighbours) < 0) flipFaces([made.last]);
      }
    }
    return made;
  }

  /// Puts a face between two open edges.
  ///
  /// How two separate pieces are joined: extrude one edge towards the other,
  /// or bridge the gap directly.
  Face? bridge(MeshEdge a, MeshEdge b) {
    if (a == b) return null;

    // Wound so the two edges are traversed in opposite directions, or the
    // face comes out as a bow tie.
    final near =
        (positions[a.$1] - positions[b.$1]).length +
        (positions[a.$2] - positions[b.$2]).length;
    final crossed =
        (positions[a.$1] - positions[b.$2]).length +
        (positions[a.$2] - positions[b.$1]).length;

    return crossed < near
        ? addFace([a.$1, a.$2, b.$1, b.$2])
        : addFace([a.$1, a.$2, b.$2, b.$1]);
  }

  /// Splits each edge into pieces.
  List<int> subdivideEdges(Iterable<MeshEdge> which, {int into = 1}) {
    final cuts = into.clamp(1, 32);
    final made = <int>[];

    for (final edge in which.toSet()) {
      final a = positions[edge.$1];
      final b = positions[edge.$2];

      final fresh = [
        for (var i = 1; i <= cuts; i++)
          addVertex(a + (b - a) * (i / (cuts + 1))),
      ];
      made.addAll(fresh);

      // Put into every face using the edge, so nothing is left with a corner
      // in the middle of a neighbour's edge.
      for (final face in facesOn(edge)) {
        final count = face.vertices.length;
        for (var i = 0; i < count; i++) {
          final here = face.vertices[i];
          final next = face.vertices[(i + 1) % count];
          if (edgeOf(here, next) != edge) continue;

          face.vertices.insertAll(
            i + 1,
            here == edge.$1 ? fresh : fresh.reversed,
          );
          break;
        }
      }
    }
    return made;
  }

  /// Separates faces from the mesh, leaving them where they are.
  ///
  /// Returns a mesh of its own. What somebody does before moving a piece
  /// away, and what makes a doorway out of a wall.
  Mesh detach(Iterable<Face> which) {
    final chosen = which.toSet();
    if (chosen.isEmpty) return Mesh();

    final taken = Mesh();
    final moveTo = <int, int>{};
    for (final face in chosen) {
      taken.addFace(
        [
          for (final index in face.vertices)
            moveTo[index] ??= taken.addVertex(positions[index]),
        ],
        material: face.material,
        smooth: face.smooth,
      );
    }

    deleteFaces(chosen);
    return taken;
  }

  /// Copies faces in place, as a mesh of their own.
  Mesh duplicateFaces(Iterable<Face> which) {
    final taken = Mesh();
    final moveTo = <int, int>{};
    for (final face in which) {
      if (!faces.contains(face)) continue;
      taken.addFace(
        [
          for (final index in face.vertices)
            moveTo[index] ??= taken.addVertex(positions[index]),
        ],
        material: face.material,
        smooth: face.smooth,
      );
    }
    return taken;
  }

  /// Joins faces into one, dropping the edges between them.
  Face? mergeFaces(Iterable<Face> which) {
    final chosen = which.toList();
    if (chosen.length < 2) return null;

    // The border of the group, walked round to make one outline.
    final counts = <MeshEdge, int>{};
    for (final face in chosen) {
      for (final edge in edgesOf([face])) {
        counts[edge] = (counts[edge] ?? 0) + 1;
      }
    }
    final border = {
      for (final entry in counts.entries)
        if (entry.value == 1) entry.key,
    };
    if (border.length < 3) return null;

    final ring = <int>[border.first.$1];
    var at = border.first.$2;
    final used = <MeshEdge>{border.first};
    while (at != ring.first) {
      ring.add(at);
      final next = border.firstWhere(
        (edge) => !used.contains(edge) && (edge.$1 == at || edge.$2 == at),
        orElse: () => (-1, -1),
      );
      if (next.$1 < 0) return null;
      used.add(next);
      at = next.$1 == at ? next.$2 : next.$1;
    }
    if (ring.length < 3) return null;

    final material = chosen.first.material;
    final smooth = chosen.first.smooth;
    deleteFaces(chosen);
    final made = addFace(ring, material: material, smooth: smooth);

    // Facing the way the pieces did rather than whichever way the walk went.
    final was = chosen.fold(
      Vector3.zero(),
      (sum, face) => sum..add(normalOf(face)),
    );
    if (normalOf(made).dot(was) < 0) flipFaces([made]);
    return made;
  }

  /// Cuts faces down to triangles.
  ///
  /// Named for the faces rather than for the mesh, because the mesh already
  /// has a triangulate — the one that hands geometry to the renderer. This is
  /// the one that changes what the geometry *is*.
  List<Face> triangulateFaces(Iterable<Face> which) {
    final chosen = [
      for (final face in which)
        if (faces.contains(face)) face,
    ];
    final made = <Face>[];

    for (final face in chosen) {
      if (face.isTriangle) {
        made.add(face);
        continue;
      }
      for (var i = 1; i + 1 < face.vertices.length; i++) {
        made.add(
          addFace(
            [face.vertices[0], face.vertices[i], face.vertices[i + 1]],
            material: face.material,
            smooth: face.smooth,
          ),
        );
      }
      faces.remove(face);
    }
    return made;
  }

  /// Turns faces the way most of them already point.
  ///
  /// What fixes a shape that came in with some of its faces inside out —
  /// which is most of what is wrong with a mesh somebody was given.
  int conformNormals([Iterable<Face>? which]) {
    final chosen = (which ?? faces).toList();
    if (chosen.isEmpty) return 0;

    final middle = _centre;
    var outward = 0;
    for (final face in faces) {
      if (normalOf(face).dot(centreOf(face) - middle) > 0) outward++;
    }
    final wantOutward = outward * 2 >= faces.length;

    var turned = 0;
    for (final face in chosen) {
      final points = normalOf(face).dot(centreOf(face) - middle) > 0;
      if (points == wantOutward) continue;
      flipFaces([face]);
      turned++;
    }
    return turned;
  }

  Vector3 get _centre {
    final box = bounds;
    return (box.min + box.max) / 2;
  }

  /// Moves the mesh so a point is at the origin, and says how far it moved.
  ///
  /// The pivot is where an object turns and scales around, and a shape that
  /// turns around a corner two rooms away is one nobody can place.
  Vector3 centrePivotOn(Iterable<int> which) {
    final chosen = [
      for (final index in which)
        if (index >= 0 && index < positions.length) index,
    ];
    final at = chosen.isEmpty
        ? _centre
        : chosen
              .fold(Vector3.zero(), (sum, i) => sum..add(positions[i]))
              .scaled(1 / chosen.length);

    transform(Matrix4.translationValues(-at.x, -at.y, -at.z));
    return at;
  }

  /// A mirrored copy, across whichever axes are asked for.
  Mesh mirrored({bool x = false, bool y = false, bool z = false}) {
    final copy = this.copy();
    if (!x && !y && !z) return copy;

    copy.transform(
      Matrix4.diagonal3(Vector3(x ? -1 : 1, y ? -1 : 1, z ? -1 : 1)),
    );
    // Reflecting turns the winding inside out, and a mesh that is inside out
    // is one that is invisible from the side somebody is looking at.
    final flips = [x, y, z].where((on) => on).length;
    if (flips.isOdd) copy.flip();
    return copy;
  }
}
