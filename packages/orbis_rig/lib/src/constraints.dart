import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import 'armature.dart';
import 'ik.dart';

/// Which of a bone's own axes a constraint aims.
///
/// A bone points along its own Y, so that is what usually wants aiming — but
/// a control that should keep its front towards something aims Z instead.
enum TrackAxis {
  x(0),
  y(1),
  z(2),
  negativeX(0, negated: true),
  negativeY(1, negated: true),
  negativeZ(2, negated: true);

  const TrackAxis(this.column, {this.negated = false});

  /// Which column of the bone's matrix holds this axis.
  final int column;

  final bool negated;

  Vector3 of(Matrix4 matrix) {
    final vector = matrix.getColumn(column);
    final axis = Vector3(vector.x, vector.y, vector.z)..normalize();
    return negated ? -axis : axis;
  }
}

/// Something that adjusts where a bone ended up.
///
/// Applied after a bone's own transform and before its children are worked
/// out, so a constrained bone carries everything below it with it — which is
/// what makes a rig a mechanism rather than a list of independent parts.
abstract interface class BoneConstraint {
  /// How much of the constraint to apply, from zero to one.
  ///
  /// Every constraint blends rather than switching, because the interesting
  /// uses are partial: a head that half-follows a target reads as attention,
  /// and one that fully follows reads as a turret.
  double get influence;

  /// Bones this constraint reads, which must be worked out before the bone it
  /// is on.
  ///
  /// A hierarchy is not the only thing that decides evaluation order. A bone
  /// aimed at its cousin depends on that cousin, and ordering by parents alone
  /// would read a matrix that has not been computed yet — silently, with the
  /// previous frame's answer, which is the kind of bug that only shows up as a
  /// limb one frame behind.
  Iterable<String> get dependencies;

  Matrix4 apply(Matrix4 world, Pose pose);
}

/// Takes another bone's orientation.
class CopyRotation implements BoneConstraint {
  CopyRotation(this.source, {this.influence = 1, this.invert = false});

  /// The bone to copy from. It must already have been evaluated, which
  /// evaluation order guarantees for a parent and does not for a sibling.
  final String source;

  @override
  final double influence;

  /// Turns the opposite way instead. What a counter-rotating mechanism needs.
  final bool invert;

  @override
  Iterable<String> get dependencies => [source];

  @override
  Matrix4 apply(Matrix4 world, Pose pose) {
    final target = pose.worldOf(source);

    final current = _rotationOf(world);
    var wanted = _rotationOf(target);
    if (invert) wanted = wanted.conjugated();

    final blended = _slerp(current, wanted, influence.clamp(0.0, 1.0));
    return Matrix4.compose(world.getTranslation(), blended, _scaleOf(world));
  }
}

/// Points one of a bone's axes at a place, and twists no further than it must.
///
/// Damped because it takes the shortest rotation to the target rather than
/// building a full orientation from an up vector. That leaves the bone's roll
/// alone, which is what stops an aimed bone spinning as it passes overhead —
/// the classic failure of a naive look-at in a rig.
class DampedTrack implements BoneConstraint {
  DampedTrack({
    required this.target,
    this.axis = TrackAxis.y,
    this.influence = 1,
  });

  /// The bone to aim at.
  final String target;

  final TrackAxis axis;

  @override
  final double influence;

  @override
  Iterable<String> get dependencies => [target];

  @override
  Matrix4 apply(Matrix4 world, Pose pose) {
    final origin = world.getTranslation();
    final toTarget = pose.worldOf(target).getTranslation() - origin;
    if (toTarget.length2 < 1e-12) return world;

    final current = axis.of(world);
    final correction = rotationBetween(current, toTarget.normalized());

    final rotation = _rotationOf(world);
    final wanted = correction * rotation;
    final blended = _slerp(rotation, wanted, influence.clamp(0.0, 1.0));

    return Matrix4.compose(origin, blended, _scaleOf(world));
  }
}

/// Stops a bone bending further than a joint can.
///
/// A cone about the rest direction rather than per-axis minimums and maximums.
/// A cone has no rotation order to get wrong and no gimbal to fall into, and
/// it is what a shoulder or a finger actually is — the axis-aligned version
/// exists in other tools because Euler angles were already there, not because
/// joints are shaped like boxes.
class LimitRotation implements BoneConstraint {
  LimitRotation({required this.maximumAngle, this.influence = 1});

  /// How far from its rest direction the bone may point, in radians.
  final double maximumAngle;

  @override
  final double influence;

  /// Reads nothing but the bone it is on.
  @override
  Iterable<String> get dependencies => const [];

  @override
  Matrix4 apply(Matrix4 world, Pose pose) {
    final rotation = _rotationOf(world);

    // The angle of the rotation itself: a quaternion's w is the cosine of half
    // its angle, which is the cheapest way to ask "how far has this turned".
    final half = math.acos(rotation.w.abs().clamp(0.0, 1.0));
    final angle = half * 2;
    if (angle <= maximumAngle) return world;

    final scale = maximumAngle / angle;
    final limited = _slerp(Quaternion.identity(), rotation, scale);
    final blended = _slerp(rotation, limited, influence.clamp(0.0, 1.0));

    return Matrix4.compose(world.getTranslation(), blended, _scaleOf(world));
  }
}

Quaternion _rotationOf(Matrix4 matrix) {
  final rotation = Quaternion.identity();
  final scale = Vector3.zero();
  final translation = Vector3.zero();
  matrix.decompose(translation, rotation, scale);
  return rotation.normalized();
}

Vector3 _scaleOf(Matrix4 matrix) {
  final rotation = Quaternion.identity();
  final scale = Vector3.zero();
  final translation = Vector3.zero();
  matrix.decompose(translation, rotation, scale);
  return scale;
}

/// Spherical interpolation that always takes the shorter arc.
Quaternion _slerp(Quaternion a, Quaternion b, double t) {
  if (t <= 0) return a.clone();
  if (t >= 1) return b.clone();

  var dot = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
  var target = b;
  if (dot < 0) {
    target = Quaternion(-b.x, -b.y, -b.z, -b.w);
    dot = -dot;
  }

  if (dot > 0.9995) {
    return Quaternion(
      a.x + (target.x - a.x) * t,
      a.y + (target.y - a.y) * t,
      a.z + (target.z - a.z) * t,
      a.w + (target.w - a.w) * t,
    )..normalize();
  }

  final theta = math.acos(dot.clamp(-1.0, 1.0));
  final sinTheta = math.sin(theta);
  return Quaternion(
    (a.x * math.sin((1 - t) * theta) + target.x * math.sin(t * theta)) /
        sinTheta,
    (a.y * math.sin((1 - t) * theta) + target.y * math.sin(t * theta)) /
        sinTheta,
    (a.z * math.sin((1 - t) * theta) + target.z * math.sin(t * theta)) /
        sinTheta,
    (a.w * math.sin((1 - t) * theta) + target.w * math.sin(t * theta)) /
        sinTheta,
  )..normalize();
}
