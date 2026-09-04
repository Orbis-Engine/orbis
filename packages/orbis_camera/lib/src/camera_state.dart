import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import 'lens.dart';

/// Something a camera can follow or look at.
///
/// An interface rather than an entity handle, so the camera solver depends on
/// nothing but maths. A game implements it over the entity store; a test
/// implements it with two numbers.
abstract interface class CameraTarget {
  Vector3 get position;
  Quaternion get rotation;
}

/// A target that does not move, for tests and for framing a fixed point.
class FixedTarget implements CameraTarget {
  FixedTarget(this.position, [Quaternion? rotation])
    : rotation = rotation ?? Quaternion.identity();

  @override
  Vector3 position;

  @override
  Quaternion rotation;
}

/// Where a camera is and what it sees.
class CameraState {
  CameraState({
    Vector3? position,
    Quaternion? rotation,
    this.lens = const Lens(),
  }) : position = position ?? Vector3.zero(),
       rotation = rotation ?? Quaternion.identity();

  Vector3 position;
  Quaternion rotation;
  Lens lens;

  /// The direction the camera is looking.
  Vector3 get forward => rotateVector(rotation, Vector3(0, 0, -1));

  Vector3 get up => rotateVector(rotation, Vector3(0, 1, 0));

  Vector3 get right => rotateVector(rotation, Vector3(1, 0, 0));

  CameraState clone() => CameraState(
    position: position.clone(),
    rotation: rotation.clone(),
    lens: lens,
  );

  /// Blends two camera states.
  ///
  /// Rotation goes the short way round, which is what a viewer expects from a
  /// cut between two shots and is not what naive interpolation of four
  /// components gives you.
  static CameraState lerp(CameraState a, CameraState b, double t) {
    if (t <= 0) return a.clone();
    if (t >= 1) return b.clone();
    return CameraState(
      position: a.position + (b.position - a.position) * t,
      rotation: slerpShortest(a.rotation, b.rotation, t),
      lens: Lens.lerp(a.lens, b.lens, t),
    );
  }
}

/// Rotates a vector by a quaternion.
///
/// Written out through the rotation matrix rather than using the quaternion's
/// own rotate, which applies the rotation in the opposite sense to the one
/// every other part of this package means by it. A silently mirrored camera is
/// a bad afternoon.
Vector3 rotateVector(Quaternion q, Vector3 v) => Matrix3.fromList([
  1 - 2 * (q.y * q.y + q.z * q.z),
  2 * (q.x * q.y + q.z * q.w),
  2 * (q.x * q.z - q.y * q.w),
  2 * (q.x * q.y - q.z * q.w),
  1 - 2 * (q.x * q.x + q.z * q.z),
  2 * (q.y * q.z + q.x * q.w),
  2 * (q.x * q.z + q.y * q.w),
  2 * (q.y * q.z - q.x * q.w),
  1 - 2 * (q.x * q.x + q.y * q.y),
]).transformed(v);

/// Spherical interpolation that always takes the shorter arc.
Quaternion slerpShortest(Quaternion a, Quaternion b, double t) {
  var dot = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;

  // A quaternion and its negation describe the same orientation, so flipping
  // one when they point apart is what makes the interpolation take the short
  // way rather than spinning most of the way around.
  var target = b;
  if (dot < 0) {
    target = Quaternion(-b.x, -b.y, -b.z, -b.w);
    dot = -dot;
  }

  if (dot > 0.9995) {
    // Nearly aligned: interpolating linearly and renormalising avoids dividing
    // by a sine that has gone to zero.
    final result = Quaternion(
      a.x + (target.x - a.x) * t,
      a.y + (target.y - a.y) * t,
      a.z + (target.z - a.z) * t,
      a.w + (target.w - a.w) * t,
    );
    return result..normalize();
  }

  final theta = math.acos(dot.clamp(-1.0, 1.0));
  final sinTheta = math.sin(theta);
  final wa = math.sin((1 - t) * theta) / sinTheta;
  final wb = math.sin(t * theta) / sinTheta;

  return Quaternion(
    a.x * wa + target.x * wb,
    a.y * wa + target.y * wb,
    a.z * wa + target.z * wb,
    a.w * wa + target.w * wb,
  )..normalize();
}

/// A rotation that looks along [forward], kept upright against [up].
///
/// Falls back to the world up when the two are parallel, which happens the
/// moment a camera looks straight down at something — the case that produces a
/// roll spike if it is not handled.
Quaternion lookRotation(Vector3 forward, [Vector3? up]) {
  final f = forward.normalized();
  var reference = (up ?? Vector3(0, 1, 0)).normalized();

  if (f.cross(reference).length < 1e-4) {
    reference = f.z.abs() < 0.9 ? Vector3(0, 0, 1) : Vector3(1, 0, 0);
  }

  // A camera looks down its own negative Z, so the third basis vector points
  // backwards. The other two are then derived from it rather than from the
  // forward direction — deriving them from forward produces a left-handed
  // basis, which is a reflection rather than a rotation and converts to a
  // quaternion that silently refuses to turn.
  final back = -f;
  final right = reference.cross(back).normalized();
  final upward = back.cross(right);

  return quaternionFromBasis(right, upward, back);
}

/// Builds a quaternion from three orthonormal basis vectors.
///
/// Written out rather than using the library's own matrix conversion, which
/// returns the identity for a perfectly valid rotation. A camera that silently
/// refuses to turn is a long afternoon, so the conversion is done here where it
/// can be read and tested.
///
/// Shepperd's method: pick whichever of the four components is largest to
/// divide by, since dividing by the smallest is where the precision goes.
Quaternion quaternionFromBasis(Vector3 right, Vector3 up, Vector3 back) {
  final m00 = right.x, m10 = right.y, m20 = right.z;
  final m01 = up.x, m11 = up.y, m21 = up.z;
  final m02 = back.x, m12 = back.y, m22 = back.z;

  final trace = m00 + m11 + m22;

  if (trace > 0) {
    final s = math.sqrt(trace + 1.0) * 2;
    return Quaternion(
      (m21 - m12) / s,
      (m02 - m20) / s,
      (m10 - m01) / s,
      0.25 * s,
    )..normalize();
  }

  if (m00 > m11 && m00 > m22) {
    final s = math.sqrt(1.0 + m00 - m11 - m22) * 2;
    return Quaternion(
      0.25 * s,
      (m01 + m10) / s,
      (m02 + m20) / s,
      (m21 - m12) / s,
    )..normalize();
  }

  if (m11 > m22) {
    final s = math.sqrt(1.0 + m11 - m00 - m22) * 2;
    return Quaternion(
      (m01 + m10) / s,
      0.25 * s,
      (m12 + m21) / s,
      (m02 - m20) / s,
    )..normalize();
  }

  final s = math.sqrt(1.0 + m22 - m00 - m11) * 2;
  return Quaternion((m02 + m20) / s, (m12 + m21) / s, 0.25 * s, (m10 - m01) / s)
    ..normalize();
}
