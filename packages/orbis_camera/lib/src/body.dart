import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import 'aim.dart' show project;
import 'camera_state.dart';
import 'damping.dart';
import 'guides.dart';
import 'lens.dart';

/// Where a camera puts itself.
///
/// Separated from where it points, because the two decisions are independent:
/// a camera can orbit a character while framing something else entirely, and
/// combining the two into one behaviour makes that impossible to express.
abstract interface class CameraBody {
  /// The position for this frame, given where the camera was.
  ///
  /// The lens and the rotation are here because some bodies frame by moving
  /// rather than by turning — a camera over a game seen flat on cannot turn
  /// to bring anything into shot, since turning an orthographic view moves
  /// nothing. Those need to know what the frame actually shows. The ones that
  /// do not, ignore them.
  Vector3 solve(
    Vector3 current,
    CameraTarget? follow, {
    required Quaternion rotation,
    required Lens lens,
    required double aspect,
    required double delta,
  });

  /// The framing rules this body works by, for something to draw over the
  /// frame, or null for a body that frames by nothing.
  CameraGuides? get guides;
}

/// A camera that does not move itself.
class StaticBody implements CameraBody {
  /// It does not frame anything; it stands where it stands.
  @override
  CameraGuides? get guides => null;

  const StaticBody(this.position);

  final Vector3 position;

  @override
  Vector3 solve(
    Vector3 current,
    CameraTarget? follow, {
    required Quaternion rotation,
    required Lens lens,
    required double aspect,
    required double delta,
  }) =>
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
  /// It holds an offset. What that puts on screen is the aim's business.
  @override
  CameraGuides? get guides => null;

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
  Vector3 solve(
    Vector3 current,
    CameraTarget? follow, {
    required Quaternion rotation,
    required Lens lens,
    required double aspect,
    required double delta,
  }) {
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
  /// It holds a distance and an angle, not a place in the frame.
  @override
  CameraGuides? get guides => null;

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
  Vector3 solve(
    Vector3 current,
    CameraTarget? follow, {
    required Quaternion rotation,
    required Lens lens,
    required double aspect,
    required double delta,
  }) {
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
  /// It holds a distance along a fixed direction.
  @override
  CameraGuides? get guides => null;

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
  Vector3 solve(
    Vector3 current,
    CameraTarget? follow, {
    required Quaternion rotation,
    required Lens lens,
    required double aspect,
    required double delta,
  }) {
    if (follow == null) return current;

    final direction = viewDirection.normalized();
    final desired =
        follow.position + direction * distance.clamp(minimum, maximum);

    final factor = dampingFactor(damping, delta);
    return current + (desired - current) * factor;
  }
}

/// Frames a target by moving, rather than by turning to face it.
///
/// The difference matters more than it sounds. A composer turns the camera
/// until the subject sits where it should in the frame, which works because
/// turning a perspective view sweeps it across the world. A camera over a game
/// seen flat on cannot do that: turning an orthographic view does not move
/// anything through the frame, it rotates the whole picture. The only way to
/// bring a subject to a place in a flat frame is to move the camera there.
///
/// So this is the body a two-dimensional game wants, and it is also what a
/// third-person camera often wants in three: keeping a character a third of
/// the way up the frame by sliding rather than by tilting is steadier to look
/// at, because the horizon does not move.
///
/// The dead zone and the soft zone mean what they mean everywhere else: inside
/// the first the camera holds still, between the two it eases after the
/// subject, past the second it is dragged, because by then keeping them in
/// frame matters more than holding the shot.
class ScreenFollowBody implements CameraBody {
  ScreenFollowBody({
    this.distance = 10,
    this.screenX = 0.5,
    this.screenY = 0.5,
    this.deadZoneWidth = 0.1,
    this.deadZoneHeight = 0.1,
    this.softZoneWidth = 0.4,
    this.softZoneHeight = 0.4,
    this.damping = 0.4,
    this.bounds,
  });

  /// How far in front of the target the camera sits, along its own view
  /// direction. For a flat game this is only what keeps the subject in front
  /// of the near plane; for one with perspective it is the shot size.
  double distance;

  /// Where in the frame the subject belongs, in fractions of it.
  double screenX;
  double screenY;

  double deadZoneWidth;
  double deadZoneHeight;
  double softZoneWidth;
  double softZoneHeight;

  /// Seconds of lag while catching up inside the soft zone.
  double damping;

  /// A box the camera is kept inside, or null for a world without edges.
  ///
  /// What stops a camera following a character to the edge of a level and
  /// showing whatever is past it. Applied last, after the framing, because a
  /// wall is not a preference.
  ({Vector3 minimum, Vector3 maximum})? bounds;

  @override
  CameraGuides get guides => CameraGuides(
    screenX: screenX,
    screenY: screenY,
    dead: ScreenRect(
      screenX - deadZoneWidth,
      screenY - deadZoneHeight,
      deadZoneWidth * 2,
      deadZoneHeight * 2,
    ),
    soft: ScreenRect(
      screenX - softZoneWidth,
      screenY - softZoneHeight,
      softZoneWidth * 2,
      softZoneHeight * 2,
    ),
  );

  @override
  Vector3 solve(
    Vector3 current,
    CameraTarget? follow, {
    required Quaternion rotation,
    required Lens lens,
    required double aspect,
    required double delta,
  }) {
    if (follow == null) return current;

    final forward = rotateVector(rotation, Vector3(0, 0, -1));
    final right = rotateVector(rotation, Vector3(1, 0, 0));
    final up = rotateVector(rotation, Vector3(0, 1, 0));

    // Where the camera would have to stand for the subject to sit dead in the
    // middle: back along its own view direction by the shot distance.
    final centred = follow.position - forward * distance;

    // Where the subject is in the frame from where the camera is now.
    final seen = project(
      current,
      rotation,
      follow.position,
      lens: lens,
      aspect: aspect,
    );

    // Behind the camera there is nothing to frame, only something to recover
    // from: go straight to where it should be rather than reading a
    // projection that has folded over.
    if (!seen.inFront) return _within(centred + _offsetFor(right, up, lens, aspect, 0, 0));

    final idealX = (screenX - 0.5) * 2;
    final idealY = (0.5 - screenY) * 2;

    // How far off it is, and how much of that is worth correcting: nothing
    // inside the dead zone, everything past the soft one.
    final errorX = seen.x - idealX;
    final errorY = seen.y - idealY;

    final overX = _beyond(errorX, deadZoneWidth);
    final overY = _beyond(errorY, deadZoneHeight);

    final hardX = _beyond(errorX, softZoneWidth);
    final hardY = _beyond(errorY, softZoneHeight);

    // Eased inside the soft zone, taken in full outside it.
    final follows = dampingFactor(damping, delta);
    final moveX = hardX + (overX - hardX) * follows;
    final moveY = hardY + (overY - hardY) * follows;

    final wanted =
        current + _offsetFor(right, up, lens, aspect, moveX, moveY);

    // Held at the shot distance along the view direction, so framing sideways
    // never drifts the camera closer or further away.
    final along = (wanted - follow.position).dot(forward);
    return _within(wanted - forward * (along + distance));
  }

  /// How far in the world a correction of [x] and [y] in the frame is.
  Vector3 _offsetFor(
    Vector3 right,
    Vector3 up,
    Lens lens,
    double aspect,
    double x,
    double y,
  ) {
    // Half the frame, in metres, at the distance being framed. For a flat lens
    // that is fixed; for one with perspective it grows with distance, which is
    // why the same fraction of the frame is a different distance to move.
    final halfHeight = lens.orthographic
        ? lens.height / 2
        : distance * math.tan(lens.fieldOfView * math.pi / 360);

    return right * (x * halfHeight * aspect) + up * (y * halfHeight);
  }

  /// Kept inside its bounds, if it has any.
  Vector3 _within(Vector3 at) {
    final box = bounds;
    if (box == null) return at;
    return Vector3(
      at.x.clamp(box.minimum.x, box.maximum.x),
      at.y.clamp(box.minimum.y, box.maximum.y),
      at.z.clamp(box.minimum.z, box.maximum.z),
    );
  }

  /// How far past a zone's edge something is, and zero inside it.
  static double _beyond(double error, double zone) {
    if (error > zone) return error - zone;
    if (error < -zone) return error + zone;
    return 0;
  }
}
