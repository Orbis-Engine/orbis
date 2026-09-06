import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import 'mesh.dart';
import 'uv.dart';

/// Working on texture coordinates.
///
/// Everything here goes one of two ways. Either it changes the *rule* a face
/// gets its coordinates from, which is cheap and survives the face changing
/// shape; or it freezes the rule into coordinates and edits those, which is
/// the only way to say something the rule cannot.
///
/// A face is frozen the moment somebody drags one of its corners, and not
/// before. That is the whole of the automatic-to-manual story: nobody chooses
/// it from a menu, it happens because they did something a rule cannot
/// express.
extension MeshUvs on Mesh {
  /// Turns a face's rule into coordinates, so they can be edited one at a
  /// time. Already-frozen faces are left alone.
  void freezeUvs(Iterable<Face> which) {
    for (final face in which) {
      if (face.uv.isManual) continue;
      face.uv = face.uv.copyWith(
        manual: face.uv.forFace(pointsOf(face), normalOf(face)),
      );
    }
  }

  /// Back to the rule, throwing away whatever was drawn.
  ///
  /// The settings underneath are kept rather than reset: somebody who tried
  /// editing by hand and changed their mind wants the offset and scale they
  /// had, not the defaults.
  void releaseUvs(Iterable<Face> which) {
    for (final face in which) {
      face.uv = face.uv.copyWith(clearManual: true);
    }
  }

  /// The coordinates a face currently has, whichever way it gets them.
  List<Vector2> uvsOf(Face face) =>
      face.uv.forFace(pointsOf(face), normalOf(face));

  /// The box every one of these faces' coordinates fits in.
  ///
  /// Null when there are none, which is the difference between "they are all
  /// at the origin" and "there is nothing to look at" — and a UV view that
  /// framed the second as the first would show an empty square and no reason
  /// why.
  ({Vector2 min, Vector2 max})? uvBoundsOf(Iterable<Face> which) {
    var minU = double.infinity;
    var minV = double.infinity;
    var maxU = double.negativeInfinity;
    var maxV = double.negativeInfinity;
    var found = false;

    for (final face in which) {
      for (final at in uvsOf(face)) {
        found = true;
        minU = math.min(minU, at.x);
        minV = math.min(minV, at.y);
        maxU = math.max(maxU, at.x);
        maxV = math.max(maxV, at.y);
      }
    }
    return found ? (min: Vector2(minU, minV), max: Vector2(maxU, maxV)) : null;
  }

  /// Moves coordinates.
  ///
  /// A face still on its rule has the move folded into the rule's offset,
  /// which keeps it automatic. One that has been frozen has its corners
  /// moved. Same gesture either way, and the difference only shows later,
  /// when the face changes shape.
  void nudgeUvs(Iterable<Face> which, Vector2 by) {
    for (final face in which) {
      final drawn = face.uv.manual;
      if (drawn == null) {
        face.uv = face.uv.copyWith(offset: face.uv.offset + by);
        continue;
      }
      face.uv = face.uv.copyWith(
        manual: [for (final at in drawn) at + by],
      );
    }
  }

  /// Scales coordinates about a point.
  ///
  /// The point is in coordinate space, not on the face — which is what makes
  /// scaling a selection of several faces keep them where they are relative
  /// to each other rather than each shrinking into its own middle.
  void scaleUvs(Iterable<Face> which, Vector2 by, {Vector2? about}) {
    final chosen = which.toList();
    final centre = about ?? _middleOf(chosen);
    if (centre == null) return;

    for (final face in chosen) {
      final drawn = face.uv.manual;
      if (drawn == null) {
        // On the rule, so the scale is the rule's — and the offset has to
        // move with it, or the face slides as it grows.
        final was = face.uv;
        face.uv = was.copyWith(
          scale: Vector2(was.scale.x * by.x, was.scale.y * by.y),
          offset: Vector2(
            centre.x + (was.offset.x - centre.x) * by.x,
            centre.y + (was.offset.y - centre.y) * by.y,
          ),
        );
        continue;
      }
      face.uv = face.uv.copyWith(
        manual: [
          for (final at in drawn)
            Vector2(
              centre.x + (at.x - centre.x) * by.x,
              centre.y + (at.y - centre.y) * by.y,
            ),
        ],
      );
    }
  }

  /// Turns coordinates about a point, in degrees.
  void turnUvs(Iterable<Face> which, double degrees, {Vector2? about}) {
    final chosen = which.toList();
    final centre = about ?? _middleOf(chosen);
    if (centre == null) return;

    final radians = degrees * math.pi / 180;
    final cos = math.cos(radians);
    final sin = math.sin(radians);

    for (final face in chosen) {
      final drawn = face.uv.manual;
      if (drawn == null) {
        face.uv = face.uv.copyWith(rotation: face.uv.rotation + degrees);
        continue;
      }
      face.uv = face.uv.copyWith(
        manual: [
          for (final at in drawn)
            Vector2(
              centre.x + (at.x - centre.x) * cos - (at.y - centre.y) * sin,
              centre.y + (at.x - centre.x) * sin + (at.y - centre.y) * cos,
            ),
        ],
      );
    }
  }

  /// Projects several faces as though they were one flat surface.
  ///
  /// From their average direction, so a texture runs across all of them
  /// without a seam. What somebody wants for a wall made of six quads and
  /// never wants for the six sides of a box, where it would smear the ones
  /// facing away.
  void projectPlanar(Iterable<Face> which) {
    final chosen = which.toList();
    if (chosen.isEmpty) return;

    final normal = Vector3.zero();
    for (final face in chosen) {
      normal.add(normalOf(face));
    }
    if (normal.length2 < 1e-12) return;
    final axes = FaceUv.axesFor(normal.normalized());

    for (final face in chosen) {
      face.uv = face.uv.copyWith(
        manual: [
          for (final at in pointsOf(face))
            Vector2(at.dot(axes.u), at.dot(axes.v)),
        ],
      );
    }
  }

  /// Projects each face from whichever way it happens to point.
  ///
  /// Which is what the rule already does, so this is the rule made explicit:
  /// the faces are frozen where they stand. Useful before hand-editing, and
  /// as the way back from a planar projection that smeared something.
  void projectBox(Iterable<Face> which) {
    for (final face in which) {
      final axes = FaceUv.axesFor(normalOf(face));
      face.uv = face.uv.copyWith(
        manual: [
          for (final at in pointsOf(face))
            Vector2(at.dot(axes.u), at.dot(axes.v)),
        ],
      );
    }
  }

  /// Fits the coordinates of these faces into the nought-to-one square,
  /// together — so their arrangement is kept and only their size changes.
  void fitUvs(Iterable<Face> which, {bool keepShape = true}) {
    final chosen = which.toList();
    final box = uvBoundsOf(chosen);
    if (box == null) return;

    var spanU = box.max.x - box.min.x;
    var spanV = box.max.y - box.min.y;
    if (spanU < 1e-9) spanU = 1;
    if (spanV < 1e-9) spanV = 1;
    if (keepShape) {
      final most = math.max(spanU, spanV);
      spanU = most;
      spanV = most;
    }

    freezeUvs(chosen);
    for (final face in chosen) {
      final drawn = face.uv.manual;
      if (drawn == null) continue;
      face.uv = face.uv.copyWith(
        manual: [
          for (final at in drawn)
            Vector2((at.x - box.min.x) / spanU, (at.y - box.min.y) / spanV),
        ],
      );
    }
  }

  /// Mirrors coordinates.
  void flipUvs(Iterable<Face> which, {bool u = false, bool v = false}) {
    if (!u && !v) return;
    for (final face in which) {
      final drawn = face.uv.manual;
      if (drawn == null) {
        face.uv = face.uv.copyWith(
          flipU: u ? !face.uv.flipU : face.uv.flipU,
          flipV: v ? !face.uv.flipV : face.uv.flipV,
        );
        continue;
      }
      final centre = _middleOf([face]) ?? Vector2.zero();
      face.uv = face.uv.copyWith(
        manual: [
          for (final at in drawn)
            Vector2(
              u ? 2 * centre.x - at.x : at.x,
              v ? 2 * centre.y - at.y : at.y,
            ),
        ],
      );
    }
  }

  /// The middle of what these faces cover, in coordinate space.
  Vector2? _middleOf(List<Face> which) {
    final box = uvBoundsOf(which);
    if (box == null) return null;
    return (box.min + box.max)..scale(0.5);
  }
}
