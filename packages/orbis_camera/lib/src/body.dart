import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import 'camera_state.dart';
import 'damping.dart';

/// Where a camera puts itself.
///
/// Separated from where it points, because the two decisions are independent:
/// a camera can orbit a character while framing something else entirely, and
/// combining the two into one behaviour makes that impossible to express.
abstract interface class CameraBody {
  /// The position for this frame, given where the camera was.
  Vector3 solve(Vector3 current, CameraTarget? follow, double delta);
}

/// A camera that does not move itself.
class StaticBody implements CameraBody {
  const StaticBody(this.position);

  final Vector3 position;

  @override
  Vector3 solve(Vector3 current, CameraTarget? follow, double delta) =>
      position.clone();
}

/// Which space an offset is measured in.
enum FollowBinding {
  /// World axes. The camera keeps the same compass bearing however the target
  /// turns — a fixed isometric view.
  world,

  /// The target's full rotation. The camera sits behind a character's shoulder
  /// and rolls with them, which is right for a vehicle and wrong for a person.
  targetRotation,

  /// The target's heading only, ignoring pitch and roll. What a third-person
  /// camera almost always wants: it follows where a character faces without
  /// tipping when they walk up a slope.
  targetHeading,
}

/// Holds an offset from a target.
class FollowBody implements CameraBody {
  FollowBody({
    required this.offset,
    this.binding = FollowBinding.targetHeading,
    Vector3? damping,
  }) : damping = damping ?? Vector3(0.4, 0.4, 0.4);

  /// Where to sit relative to the target, in the space [binding] names.
  Vector3 offset;

  final FollowBinding binding;

  /// Seconds of lag per axis, in the same space as the offset.
  ///
  /// Per-axis rather than one number because the axes want different answers:
  /// a follow camera that is loose horizontally and tight vertically reads as
  /// smooth, while the reverse reads as seasick.
  Vector3 damping;

  @override
  Vector3 solve(Vector3 current, CameraTarget? follow, double delta) {
    if (follow == null) return current;

    final rotation = switch (binding) {
      FollowBinding.world => Quaternion.identity(),
      FollowBinding.targetRotation => follow.rotation,
      FollowBinding.targetHeading => _headingOf(follow.rotation),
    };

    final desired = follow.position + rotateVector(rotation, offset);
    final toDesired = desired - current;

    // Damped in the binding's own space, so "loose behind, tight above" stays
    // true as the target turns.
    final inverse = Quaternion.copy(rotation)..conjugate();
    final local = rotateVector(inverse, toDesired);

    local
      ..x *= dampingFactor(damping.x, delta)
      ..y *= dampingFactor(damping.y, delta)
      ..z *= dampingFactor(damping.z, delta);

    return current + rotateVector(rotation, local);
  }

  /// The rotation about world up alone, so a target leaning or pitching does
  /// not tilt the camera with it.
  static Quaternion _headingOf(Quaternion rotation) {
    final forward = rotateVector(rotation, Vector3(0, 0, -1));
    final flat = Vector3(forward.x, 0, forward.z);
    if (flat.length2 < 1e-8) return Quaternion.identity();
    return lookRotation(flat.normalized());
  }
}

/// Circles a target at a fixed radius.
class OrbitBody implements CameraBody {
  OrbitBody({
    this.radius = 6,
    this.azimuth = 0,
    this.elevation = 20,
    this.damping = 0.3,
    this.height = 0,
  });

  /// Distance from the target.
  double radius;

  /// Bearing around the target, in degrees.
  double azimuth;

  /// Angle above the horizon, in degrees. Clamped short of the poles, where
  /// the up vector becomes ambiguous and the camera rolls.
  double elevation;

  /// Raises the point being orbited, so the camera circles a character's head
  /// rather than their feet.
  double height;

  double damping;

  @override
  Vector3 solve(Vector3 current, CameraTarget? follow, double delta) {
    if (follow == null) return current;

    final pitch = elevation.clamp(-89.0, 89.0) * math.pi / 180;
    final yaw = azimuth * math.pi / 180;
    final horizontal = radius * math.cos(pitch);

    final desired =
        follow.position +
        Vector3(0, height, 0) +
        Vector3(
          horizontal * math.sin(yaw),
          radius * math.sin(pitch),
          horizontal * math.cos(yaw),
        );

    final factor = dampingFactor(damping, delta);
    return current + (desired - current) * factor;
  }
}

/// Keeps a target a chosen distance away, moving along the view axis only.
///
/// The dolly of a framing shot: the camera does not swing around the subject to
/// keep it the right size, it moves towards and away, which preserves whatever
/// composition the aim solver established.
class FramingBody implements CameraBody {
  FramingBody({
    required this.viewDirection,
    this.distance = 8,
    this.minimum = 2,
    this.maximum = 40,
    this.damping = 0.5,
  });

  /// The direction from the target to the camera.
  Vector3 viewDirection;

  double distance;
  double minimum;
  double maximum;
  double damping;

  @override
  Vector3 solve(Vector3 current, CameraTarget? follow, double delta) {
    if (follow == null) return current;

    final direction = viewDirection.normalized();
    final desired =
        follow.position + direction * distance.clamp(minimum, maximum);

    final factor = dampingFactor(damping, delta);
    return current + (desired - current) * factor;
  }
}
