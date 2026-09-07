import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

/// Where a two-bone chain ends up reaching for something.
class IkSolution {
  const IkSolution({
    required this.joint,
    required this.end,
    required this.reachable,
    this.stretch = 1,
  });

  /// The elbow or knee.
  final Vector3 joint;

  /// The hand or foot. Equal to the target when it was reachable.
  final Vector3 end;

  /// False when the target was further than the limb is long, or so close the
  /// limb would have to fold through itself. The chain still points at it,
  /// straightened or folded as far as it goes — refusing to solve would leave
  /// the limb wherever it was, which looks broken rather than strained.
  final bool reachable;

  /// How much longer than its rest length the limb had to become, as a
  /// multiplier. One when it did not stretch.
  ///
  /// Reported rather than baked into the positions, because stretching is
  /// something the *bones* do: the caller has to scale them, or the mesh
  /// stays the length it was and tears away from the joint.
  final double stretch;
}

/// Places a two-bone chain so its end reaches a target.
///
/// Solved with the law of cosines rather than iterated. A limb is a triangle
/// with two known sides, so there is a closed-form answer, and an iterative
/// solver would spend a budget converging on something already known — and
/// converge differently on different frames, which is how IK gets its
/// reputation for jitter.
///
/// [pole] decides which way the joint bends. Two solutions satisfy any
/// reachable target, mirrored about the line from root to target, and the
/// pole picks one — it is the difference between a knee and a backwards knee.
/// [stretch] lets the limb grow rather than stopping short: at zero it stops
/// at full extension, at one it reaches anything. Partial values are the
/// useful ones — a little stretch hides the pop as a limb straightens without
/// making the character rubbery.
IkSolution solveTwoBoneIk({
  required Vector3 root,
  required Vector3 pole,
  required Vector3 target,
  required double upperLength,
  required double lowerLength,
  double stretch = 0,
}) {
  final toTarget = target - root;
  final reach = toTarget.length;

  if (reach < 1e-9 || upperLength <= 0 || lowerLength <= 0) {
    return IkSolution(
      joint: root + Vector3(0, upperLength, 0),
      end: root + Vector3(0, upperLength + lowerLength, 0),
      reachable: false,
    );
  }

  final direction = toTarget / reach;
  final maximum = upperLength + lowerLength;
  final minimum = (upperLength - lowerLength).abs();

  // Past full extension with stretch allowed, the limb is a straight line and
  // there is no triangle left to solve — it is one division, not a special
  // case of the law of cosines.
  if (stretch > 0 && reach > maximum) {
    final factor = 1 + (reach / maximum - 1) * stretch.clamp(0.0, 1.0);
    return IkSolution(
      joint: root + direction * (upperLength * factor),
      end: root + direction * (maximum * factor),
      // Only a limb allowed to stretch the whole way actually arrives.
      reachable: stretch >= 1,
      stretch: factor,
    );
  }

  // Kept just inside the limits: exactly straight or exactly folded makes the
  // bend plane undefined, and the joint flips between frames as rounding
  // pushes it either side.
  const margin = 1e-4;
  final clamped = reach.clamp(minimum + margin, maximum - margin);
  final reachable = reach > minimum + margin && reach < maximum - margin;

  // The angle at the root of the triangle whose sides are the two bones and
  // the distance to the target.
  final cosRoot =
      ((upperLength * upperLength +
                  clamped * clamped -
                  lowerLength * lowerLength) /
              (2 * upperLength * clamped))
          .clamp(-1.0, 1.0);
  final rootAngle = math.acos(cosRoot);

  // The plane the limb bends in, set by the pole.
  var bendAxis = direction.cross(pole - root);
  if (bendAxis.length2 < 1e-12) {
    // The pole is on the line to the target, so it names no plane. Any
    // perpendicular will do and at least keeps the limb from collapsing.
    bendAxis = direction.cross(Vector3(0, 0, 1));
    if (bendAxis.length2 < 1e-12) bendAxis = direction.cross(Vector3(1, 0, 0));
  }
  bendAxis.normalize();

  final upperDirection = Quaternion.axisAngle(
    bendAxis,
    rootAngle,
  ).rotated(direction).normalized();

  final joint = root + upperDirection * upperLength;

  // The end lands on the target when it was reachable, and on the straightened
  // or folded limit when it was not.
  final end = reachable
      ? target.clone()
      : joint + (target - joint).normalized() * lowerLength;

  return IkSolution(joint: joint, end: end, reachable: reachable);
}

/// The rotation taking one direction to another by the shortest path.
Quaternion rotationBetween(Vector3 from, Vector3 to) {
  final a = from.normalized();
  final b = to.normalized();
  final dot = a.dot(b);

  if (dot > 0.999999) return Quaternion.identity();
  if (dot < -0.999999) {
    var axis = a.cross(Vector3(1, 0, 0));
    if (axis.length2 < 1e-6) axis = a.cross(Vector3(0, 0, 1));
    return Quaternion.axisAngle(axis.normalized(), math.pi);
  }

  final axis = a.cross(b);
  return Quaternion(axis.x, axis.y, axis.z, 1 + dot)..normalize();
}
