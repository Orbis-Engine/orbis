import 'package:vector_math/vector_math_64.dart';

import 'mesh.dart';

/// The operations that change geometry.
///
/// Free functions over a mesh rather than methods on it, because a mesh is a
/// description and these are things somebody does to one. It also keeps the
/// model small enough to read in one sitting, which is what makes it possible
/// to be sure an operation left it valid.
extension MeshEdits on Mesh {
  /// Pulls faces out along their own normals.
  ///
  /// The move a modelling tool is built around: everything from a doorway to a
  /// chimney is a face pulled out and moved. New sides are made round the
  /// edge, wound so they face outwards, and the original face is carried to
  /// the end rather than left behind inside the shape.
  ///
  /// Returns the faces that ended up on the outside, which is what somebody
  /// wants selected afterwards — they are almost always about to extrude
  /// again.
  List<Face> extrude(Iterable<Face> which, double distance) {
    final chosen = [
      for (final face in which)
        if (faces.contains(face)) face,
    ];
    if (chosen.isEmpty) return const [];

    // Each face taken on its own. Extruding two faces that share an edge as
    // one region is a different operation, and doing it silently would weld
    // two chimneys into a wall.
    final moved = <Face>[];
    for (final face in chosen) {
      final along = normalOf(face) * distance;

      // A copy of every corner, moved. Shared corners are duplicated on
      // purpose: pulling one face should not drag its neighbours' vertices
      // with it.
      final fresh = [
        for (final index in face.vertices)
          addVertex(positions[index] + along),
      ];

      final count = face.vertices.length;
      for (var i = 0; i < count; i++) {
        final a = face.vertices[i];
        final b = face.vertices[(i + 1) % count];
        addFace(
          [a, b, fresh[(i + 1) % count], fresh[i]],
          material: face.material,
        );
      }

      // The face itself moves rather than a new one being added: it keeps its
      // material and whatever else was set on it, which is what somebody means
      // by extruding *this* face.
      face.vertices
        ..clear()
        ..addAll(fresh);
      moved.add(face);
    }
    return moved;
  }

  /// Shrinks faces towards their own middle, leaving a border round each.
  ///
  /// What a window is: inset a wall, then extrude the middle inwards. Doing it
  /// with a scale on the face would move the border too; this keeps the outer
  /// edge exactly where it was.
  List<Face> inset(Iterable<Face> which, double amount) {
    final chosen = [
      for (final face in which)
        if (faces.contains(face)) face,
    ];
    if (chosen.isEmpty) return const [];

    final inner = <Face>[];
    for (final face in chosen) {
      final centre = centreOf(face);
      final fresh = <int>[];
      for (final index in face.vertices) {
        final at = positions[index];
        final towards = centre - at;
        // A face smaller than the inset asked for collapses to its middle
        // rather than turning inside out, which is what scaling past the
        // centre would do.
        final step = towards.length <= amount
            ? towards
            : towards.normalized() * amount;
        fresh.add(addVertex(at + step));
      }

      final count = face.vertices.length;
      for (var i = 0; i < count; i++) {
        final a = face.vertices[i];
        final b = face.vertices[(i + 1) % count];
        addFace(
          [a, b, fresh[(i + 1) % count], fresh[i]],
          material: face.material,
        );
      }

      face.vertices
        ..clear()
        ..addAll(fresh);
      inner.add(face);
    }
    return inner;
  }

  /// Cuts every face into four by adding a point in the middle of each edge
  /// and one in the middle of the face.
  ///
  /// Quads out of quads, so the result is still something the other operations
  /// work on. A triangle becomes three quads for the same reason.
  List<Face> subdivide(Iterable<Face> which) {
    final chosen = [
      for (final face in which)
        if (faces.contains(face)) face,
    ];
    if (chosen.isEmpty) return const [];

    final made = <Face>[];
    for (final face in chosen) {
      final corners = [...face.vertices];
      final count = corners.length;

      final middle = addVertex(centreOf(face));
      final edges = [
        for (var i = 0; i < count; i++)
          addVertex(
            (positions[corners[i]] + positions[corners[(i + 1) % count]]) / 2,
          ),
      ];

      for (var i = 0; i < count; i++) {
        final previous = (i - 1 + count) % count;
        made.add(addFace(
          [corners[i], edges[i], middle, edges[previous]],
          material: face.material,
          smooth: face.smooth,
        ));
      }
      faces.remove(face);
    }
    return made;
  }

  /// Takes faces out.
  ///
  /// The points they used stay, because another face may be using them and
  /// walking the whole mesh to find out costs more than a few unused vertices.
  /// [compact] is what clears those up, when somebody wants it.
  void deleteFaces(Iterable<Face> which) {
    final going = which.toSet();
    faces.removeWhere(going.contains);
  }

  /// Turns the chosen faces the other way round.
  void flipFaces(Iterable<Face> which) {
    for (final face in which) {
      if (!faces.contains(face)) continue;
      final reversed = face.vertices.reversed.toList();
      face.vertices
        ..clear()
        ..addAll(reversed);
    }
  }

  /// Joins points that are in the same place, so faces share corners again.
  ///
  /// Extruding and merging both leave duplicates behind on purpose — an
  /// operation that welded as it went would drag neighbours around. This is
  /// the one that tidies up, and it is somebody's decision rather than a side
  /// effect.
  ///
  /// Returns how many points went.
  int weld({double within = 1e-4}) {
    if (positions.isEmpty) return 0;

    // Bucketed by rounded position rather than compared with everything: a
    // mesh with ten thousand vertices is a hundred million comparisons, and
    // this is an operation somebody presses a button for.
    final cell = within <= 0 ? 1e-4 : within;
    final buckets = <String, int>{};
    final moveTo = List<int>.filled(positions.length, 0);
    final kept = <Vector3>[];

    String keyOf(Vector3 at) => '${(at.x / cell).round()}/'
        '${(at.y / cell).round()}/${(at.z / cell).round()}';

    for (var i = 0; i < positions.length; i++) {
      final key = keyOf(positions[i]);
      final already = buckets[key];
      if (already != null) {
        moveTo[i] = already;
        continue;
      }
      buckets[key] = kept.length;
      moveTo[i] = kept.length;
      kept.add(positions[i]);
    }

    final went = positions.length - kept.length;
    if (went == 0) return 0;

    positions
      ..clear()
      ..addAll(kept);

    for (final face in faces) {
      final moved = [for (final index in face.vertices) moveTo[index]];
      // A corner that welded onto the one beside it leaves the face with a
      // repeated point, which is an edge of no length.
      final tidy = <int>[];
      for (var i = 0; i < moved.length; i++) {
        if (moved[i] != moved[(i + 1) % moved.length]) tidy.add(moved[i]);
      }
      face.vertices
        ..clear()
        ..addAll(tidy);
    }
    // A face with fewer than three corners left is not a face.
    faces.removeWhere((face) => face.vertices.length < 3);

    return went;
  }

  /// Throws away points nothing uses, and renumbers what is left.
  int compact() {
    final used = <int>{};
    for (final face in faces) {
      used.addAll(face.vertices);
    }

    if (used.length == positions.length) return 0;

    final moveTo = <int, int>{};
    final kept = <Vector3>[];
    for (var i = 0; i < positions.length; i++) {
      if (!used.contains(i)) continue;
      moveTo[i] = kept.length;
      kept.add(positions[i]);
    }

    final went = positions.length - kept.length;
    positions
      ..clear()
      ..addAll(kept);
    for (final face in faces) {
      final moved = [for (final index in face.vertices) moveTo[index]!];
      face.vertices
        ..clear()
        ..addAll(moved);
    }
    return went;
  }

  /// Moves the chosen points.
  void moveVertices(Iterable<int> which, Vector3 by) {
    for (final index in which) {
      if (index < 0 || index >= positions.length) continue;
      positions[index].add(by);
    }
  }

  /// Every point a set of faces touches.
  Set<int> verticesOf(Iterable<Face> which) => {
        for (final face in which) ...face.vertices,
      };

  /// The edges of a set of faces, each as its two points, smaller first so an
  /// edge shared by two faces is one edge rather than two.
  Set<(int, int)> edgesOf(Iterable<Face> which) {
    final edges = <(int, int)>{};
    for (final face in which) {
      final count = face.vertices.length;
      for (var i = 0; i < count; i++) {
        final a = face.vertices[i];
        final b = face.vertices[(i + 1) % count];
        edges.add(a < b ? (a, b) : (b, a));
      }
    }
    return edges;
  }

  /// The faces on the outside of the shape: the ones with an edge nothing
  /// else shares.
  ///
  /// What tells somebody their extrude left a hole, and what a "select border"
  /// does.
  List<Face> get openFaces {
    final counts = <(int, int), int>{};
    for (final face in faces) {
      for (final edge in edgesOf([face])) {
        counts[edge] = (counts[edge] ?? 0) + 1;
      }
    }

    return [
      for (final face in faces)
        if (edgesOf([face]).any((edge) => (counts[edge] ?? 0) < 2)) face,
    ];
  }
}
