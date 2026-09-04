import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import 'camera_state.dart';
import 'damping.dart';
import 'lens.dart';

/// Where a point lands on screen.
///
/// Normalised device coordinates: the visible area runs from -1 to 1 on both
/// axes, with the origin at the centre and y upwards. Used rather than pixels
/// because composition rules are about proportions of the frame, and a rule
/// written in pixels breaks the moment the window is resized.
class ScreenPoint {
  const ScreenPoint(this.x, this.y, {required this.inFront});

  final double x;
  final double y;

  /// False when the point is behind the camera, where projection lies: a point
  /// directly behind maps to the same coordinates as one directly ahead.
  final bool inFront;
}

/// Projects a world point into the frame.
ScreenPoint project(
  Vector3 cameraPosition,
  Quaternion cameraRotation,
  Vector3 worldPoint, {
  required Lens lens,
  required double aspect,
}) {
  final inverse = Quaternion.copy(cameraRotation)..conjugate();
  final local = rotateVector(inverse, worldPoint - cameraPosition);

  // The camera looks down its own negative Z, so a visible point has negative
  // z here and the depth used for the divide is its negation.
  final depth = -local.z;
  if (depth <= 1e-6) return const ScreenPoint(0, 0, inFront: false);

  final tanHalf = math.tan(lens.fieldOfView * math.pi / 360);
  return ScreenPoint(
    local.x / depth / (tanHalf * aspect),
    local.y / depth / tanHalf,
    inFront: true,
  );
}

/// The rotation that makes [worldPoint] appear at a given place in the frame.
///
/// Solved rather than approached: given where the point should land, there is
/// exactly one upright rotation that puts it there, so a composer can aim at
/// the edge of its dead zone directly instead of easing towards it and
/// overshooting.
Quaternion rotationPlacing(
  Vector3 cameraPosition,
  Vector3 worldPoint, {
  required double ndcX,
  required double ndcY,
  required Lens lens,
  required double aspect,
  Vector3? up,
}) {
  final toTarget = worldPoint - cameraPosition;
  if (toTarget.length2 < 1e-9) return Quaternion.identity();

  final centred = lookRotation(toTarget, up);

  final tanHalf = math.tan(lens.fieldOfView * math.pi / 360);
  final direction = Vector3(ndcX * tanHalf * aspect, ndcY * tanHalf, -1)
    ..normalize();

  // Centring puts the target along -Z; this takes it from there to where it
  // should sit, which is the same rotation applied to the camera in reverse.
  return centred * _shortestArc(direction, Vector3(0, 0, -1));
}

Quaternion _shortestArc(Vector3 from, Vector3 to) {
  final a = from.normalized();
  final b = to.normalized();
  final dot = a.dot(b);

  if (dot > 0.999999) return Quaternion.identity();
  if (dot < -0.999999) {
    // Opposed: any perpendicular axis is a valid half turn.
    final axis = a.cross(Vector3(1, 0, 0));
    final chosen = axis.length2 < 1e-6 ? a.cross(Vector3(0, 1, 0)) : axis;
    return Quaternion.axisAngle(chosen.normalized(), math.pi);
  }

  final axis = a.cross(b);
  return Quaternion(axis.x, axis.y, axis.z, 1 + dot)..normalize();
}

/// Where a camera points.
abstract interface class CameraAim {
  Quaternion solve(
    Quaternion current,
    Vector3 cameraPosition,
    CameraTarget? lookAt, {
    required Lens lens,
    required double aspect,
    required double delta,
  });
}

/// Keeps whatever rotation it was given.
class StaticAim implements CameraAim {
  const StaticAim(this.rotation);

  final Quaternion rotation;

  @override
  Quaternion solve(
    Quaternion current,
    Vector3 cameraPosition,
    CameraTarget? lookAt, {
    required Lens lens,
    required double aspect,
    required double delta,
  }) => rotation.clone();
}

/// Points straight at the target, with no lag.
///
/// Correct and rarely what you want: a camera that tracks perfectly reads as
/// mechanical, because a real operator is always a little behind.
class HardLookAt implements CameraAim {
  const HardLookAt({this.up});

  final Vector3? up;

  @override
  Quaternion solve(
    Quaternion current,
    Vector3 cameraPosition,
    CameraTarget? lookAt, {
    required Lens lens,
    required double aspect,
    required double delta,
  }) {
    if (lookAt == null) return current;
    final toTarget = lookAt.position - cameraPosition;
    if (toTarget.length2 < 1e-9) return current;
    return lookRotation(toTarget, up);
  }
}

/// Frames a target, with room to move before the camera reacts.
///
/// Two rectangles centred on where the subject should sit. Inside the **dead
/// zone** the camera does not move at all, which is what stops it twitching at
/// every small motion and is most of why a composed shot feels operated rather
/// than computed. Between the dead zone and the **soft zone** the camera
/// follows with lag. At the soft zone edge it stops lagging and holds the
/// subject there, so nothing important ever leaves the frame.
class ComposerAim implements CameraAim {
  ComposerAim({
    this.screenX = 0.5,
    this.screenY = 0.5,
    this.deadZoneWidth = 0.1,
    this.deadZoneHeight = 0.1,
    this.softZoneWidth = 0.8,
    this.softZoneHeight = 0.8,
    this.damping = 0.5,
    this.up,
  });

  /// Where the subject should sit, as a fraction of the frame. A half is the
  /// centre; a third is the composition rule most shots actually use.
  double screenX;
  double screenY;

  /// The rectangle the subject may move inside without the camera reacting,
  /// as a fraction of the frame.
  double deadZoneWidth;
  double deadZoneHeight;

  /// The rectangle the subject may never leave.
  double softZoneWidth;
  double softZoneHeight;

  /// Seconds of lag while catching up.
  double damping;

  Vector3? up;

  /// The ideal position, in normalised device coordinates.
  double get _idealX => (screenX - 0.5) * 2;
  double get _idealY => (0.5 - screenY) * 2;

  @override
  Quaternion solve(
    Quaternion current,
    Vector3 cameraPosition,
    CameraTarget? lookAt, {
    required Lens lens,
    required double aspect,
    required double delta,
  }) {
    if (lookAt == null) return current;

    final seen = project(
      cameraPosition,
      current,
      lookAt.position,
      lens: lens,
      aspect: aspect,
    );

    // A subject behind the camera cannot be composed, only recovered: swing to
    // it directly rather than interpreting a projection that has folded over.
    if (!seen.inFront) {
      return rotationPlacing(
        cameraPosition,
        lookAt.position,
        ndcX: _idealX,
        ndcY: _idealY,
        lens: lens,
        aspect: aspect,
        up: up,
      );
    }

    final errorX = seen.x - _idealX;
    final errorY = seen.y - _idealY;

    // Aim for the nearest point on the dead zone edge, not for the centre.
    // Aiming at the centre and stopping early is the same motion with an
    // arbitrary threshold; this is the motion the rectangle actually describes.
    final wantedX = _idealX + errorX.clamp(-deadZoneWidth, deadZoneWidth);
    final wantedY = _idealY + errorY.clamp(-deadZoneHeight, deadZoneHeight);

    final wanted = rotationPlacing(
      cameraPosition,
      lookAt.position,
      ndcX: wantedX,
      ndcY: wantedY,
      lens: lens,
      aspect: aspect,
      up: up,
    );

    var result = slerpShortest(current, wanted, dampingFactor(damping, delta));

    // The soft zone is a promise rather than a preference, so it is enforced
    // after the damping rather than folded into it.
    final after = project(
      cameraPosition,
      result,
      lookAt.position,
      lens: lens,
      aspect: aspect,
    );
    final outsideX = (after.x - _idealX).abs() > softZoneWidth;
    final outsideY = (after.y - _idealY).abs() > softZoneHeight;

    if (!after.inFront || outsideX || outsideY) {
      result = rotationPlacing(
        cameraPosition,
        lookAt.position,
        ndcX:
            _idealX + (after.x - _idealX).clamp(-softZoneWidth, softZoneWidth),
        ndcY:
            _idealY +
            (after.y - _idealY).clamp(-softZoneHeight, softZoneHeight),
        lens: lens,
        aspect: aspect,
        up: up,
      );
    }

    return result;
  }
}

/// Aim driven by the player rather than by a target.
class PovAim implements CameraAim {
  PovAim({
    this.yaw = 0,
    this.pitch = 0,
    this.minimumPitch = -85,
    this.maximumPitch = 85,
    this.damping = 0,
  });

  /// Degrees about world up.
  double yaw;

  /// Degrees above the horizon, clamped short of straight up and down where
  /// the horizon would flip.
  double pitch;

  double minimumPitch;
  double maximumPitch;
  double damping;

  @override
  Quaternion solve(
    Quaternion current,
    Vector3 cameraPosition,
    CameraTarget? lookAt, {
    required Lens lens,
    required double aspect,
    required double delta,
  }) {
    final clamped = pitch.clamp(minimumPitch, maximumPitch);
    final wanted =
        Quaternion.axisAngle(Vector3(0, 1, 0), yaw * math.pi / 180) *
        Quaternion.axisAngle(Vector3(1, 0, 0), clamped * math.pi / 180);

    if (damping <= 0) return wanted;
    return slerpShortest(current, wanted, dampingFactor(damping, delta));
  }
}
