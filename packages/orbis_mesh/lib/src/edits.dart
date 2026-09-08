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
        for (final index in face.vertices) addVertex(positions[index] + along),
      ];

      final count = face.vertices.length;
      for (var i = 0; i < count; i++) {
        final a = face.vertices[i];
        final b = face.vertices[(i + 1) % count];
        addFace([
          a,
          b,
          fresh[(i + 1) % count],
          fresh[i],
        ], material: face.material);
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
        addFace([
          a,
          b,
          fresh[(i + 1) % count],
          fresh[i],
        ], material: face.material);
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
        made.add(
          addFace(
            [corners[i], edges[i], middle, edges[previous]],
            material: face.material,
            smooth: face.smooth,
          ),
        );
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

    String keyOf(Vector3 at) =>
        '${(at.x / cell).round()}/'
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

/// Moving the parts of a mesh, rather than the mesh.
///
/// Separate from the operations above because these change nothing about the
/// shape's structure — the same vertices in the same faces, standing
/// somewhere else. That is what makes them safe to run on every frame of a
/// drag: no face is created, none is dropped, and a selection made before the
/// drag still means the same thing after it.
extension MeshHandles on Mesh {
  /// Where a set of corners sits, on average. Null when none of them exist.
  ///
  /// Named for corners rather than overloading `centreOf`, which takes a face:
  /// a handle sits at the middle of *what is selected*, which may be two
  /// vertices of one face or every vertex of eight.
  Vector3? centreOfPoints(Iterable<int> which) {
    final sum = Vector3.zero();
    var count = 0;
    for (final index in which) {
      if (index < 0 || index >= positions.length) continue;
      sum.add(positions[index]);
      count++;
    }
    if (count == 0) return null;
    return sum..scale(1 / count);
  }

  /// Moves corners by [by].
  void movePoints(Iterable<int> which, Vector3 by) {
    for (final index in which) {
      if (index < 0 || index >= positions.length) continue;
      positions[index].add(by);
    }
  }

  /// Turns corners about [about].
  ///
  /// A matrix rather than a quaternion, deliberately. `Quaternion.rotate` and
  /// `rotated` in vector_math turn a vector the *opposite* way from the same
  /// quaternion's `asRotationMatrix`, and everything else in this engine goes
  /// through the matrix — so taking a quaternion here would leave a caller one
  /// honest-looking line away from elements turning the other way from the
  /// object they belong to. Hand it `q.asRotationMatrix()`.
  void turnPoints(Iterable<int> which, Matrix3 turn, Vector3 about) {
    for (final index in which) {
      if (index < 0 || index >= positions.length) continue;
      final turned = turn.transformed(positions[index] - about);
      positions[index] = turned + about;
    }
  }

  /// Scales corners about [about].
  void scalePoints(Iterable<int> which, Vector3 by, Vector3 about) {
    for (final index in which) {
      if (index < 0 || index >= positions.length) continue;
      final at = positions[index] - about;
      positions[index] = Vector3(
        about.x + at.x * by.x,
        about.y + at.y * by.y,
        about.z + at.z * by.z,
      );
    }
  }

  /// The direction a set of faces collectively points.
  ///
  /// Averaged and normalised, so pulling two faces of a corner moves them
  /// along the corner rather than each along its own wall. Null when the
  /// faces cancel each other out — the two sides of a flat sheet, say, where
  /// there is no "out" to move along and asking for one is a question with no
  /// answer.
  Vector3? normalAcross(Iterable<Face> which) {
    final sum = Vector3.zero();
    var count = 0;
    for (final face in which) {
      sum.add(normalOf(face));
      count++;
    }
    if (count == 0 || sum.length2 < 1e-12) return null;
    return sum.normalized();
  }
}

/// Growing a shape outwards.
///
/// For a boundary that has to sit a little outside the thing it belongs to —
/// which is nearly always what a collision shape wants, because a character
/// standing exactly on a surface is a character intersecting it half the time.
extension MeshShell on Mesh {
  /// A copy with every face moved [by] metres along its own normal.
  ///
  /// Corners move further than faces do, and by exactly the right amount: a
  /// corner of a cube pushed a metre along its diagonal would only move each
  /// of its three faces out by a bit over half a metre. So each corner is
  /// pushed along the average of the faces meeting there, scaled by how far
  /// off square that average is — which puts every face exactly [by] out and
  /// keeps the corner sharp.
  ///
  /// Faces, corners and everything a face wears are unchanged; only the
  /// positions move. A negative distance shrinks, which is legitimate and is
  /// how somebody makes a boundary that sits inside a decorative shell.
  Mesh grown(double by) {
    final out = copy();
    if (by == 0 || positions.isEmpty) return out;

    // Which faces meet at each corner, and which way each of them points.
    final meeting = <int, List<Vector3>>{};
    for (final face in faces) {
      if (face.vertices.length < 3) continue;
      final normal = normalOf(face);
      for (final index in face.vertices) {
        if (index < 0 || index >= positions.length) continue;
        (meeting[index] ??= []).add(normal);
      }
    }

    for (final entry in meeting.entries) {
      final normals = entry.value;
      final average = Vector3.zero();
      for (final one in normals) {
        average.add(one);
      }
      // Corners of a shape folded back on itself can cancel out. Leaving
      // those where they are keeps the shape closed, which matters more than
      // moving them somewhere arbitrary.
      if (average.length2 < 1e-12) continue;
      average.normalize();

      // The face most side-on to the average decides the scale, so no face
      // ends up further out than asked for. Clamped, because a corner where
      // two faces nearly double back is a scale that runs away.
      var least = 1.0;
      for (final one in normals) {
        final along = average.dot(one);
        if (along < least) least = along;
      }
      final scale = least < 0.2 ? 5.0 : 1 / least;

      out.positions[entry.key] = positions[entry.key] + average * (by * scale);
    }
    return out;
  }
}
