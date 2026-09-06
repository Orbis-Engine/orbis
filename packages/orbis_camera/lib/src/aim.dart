import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import 'camera_state.dart';
import 'guides.dart';
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
///
/// Built as a turn and then a tilt about the given up, rather than as the
/// shortest rotation from the centre of the frame to the wanted spot. The
/// shortest one is the obvious construction and it rolls the camera: its axis
/// is perpendicular to both directions, so a purely sideways offset turns
/// about the up axis and a purely vertical one tilts about the right axis,
/// but an offset that is both turns about something oblique — and the part of
/// that lying along the view direction is roll. A composer whose subject
/// wanders diagonally therefore leans, and goes on leaning, because the next
/// frame damps towards a rotation that is already tilted. Nineteen degrees of
/// it, on a subject following a figure of eight.
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

  // Solved with the up axis standing at Y, then taken back. A camera levelled
  // against something other than the world's own up is still levelled.
  final upward = (up ?? Vector3(0, 1, 0)).normalized();
  final toLevel = _shortestArc(upward, Vector3(0, 1, 0));
  final fromLevel = Quaternion.copy(toLevel)..conjugate();

  final t = rotateVector(toLevel, toTarget.normalized());

  // Where the wanted spot in the frame lies, as a direction in the camera's
  // own space.
  final tanHalf = math.tan(lens.fieldOfView * math.pi / 360);
  final d = Vector3(ndcX * tanHalf * aspect, ndcY * tanHalf, -1)..normalize();

  // The tilt. Rotating d about X leaves its x alone and has to bring its y to
  // the target's, and a cosine and a sine of one angle against a constant is
  // a single cosine with a phase — so it inverts rather than being searched.
  final reach = math.sqrt(d.y * d.y + d.z * d.z);
  final phase = math.atan2(-d.z, d.y);
  final swing = math.acos((t.y / reach).clamp(-1.0, 1.0));

  // Two tilts satisfy it: a camera upright, and the same camera upside down.
  final nearer = phase - swing;
  final further = phase + swing;
  final tilt = nearer.abs() <= further.abs() ? nearer : further;

  final ct = math.cos(tilt);
  final st = math.sin(tilt);
  final tilted = Vector3(d.x, ct * d.y - st * d.z, st * d.y + ct * d.z);

  // What is left is a rotation about Y, which in that plane is the difference
  // of two bearings.
  final turn = math.atan2(t.x, t.z) - math.atan2(tilted.x, tilted.z);

  final levelled =
      Quaternion.axisAngle(Vector3(0, 1, 0), turn) *
      Quaternion.axisAngle(Vector3(1, 0, 0), tilt);

  return (fromLevel * levelled)..normalize();
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

  /// The framing rules this aim works by, for something to draw over the
  /// frame, or null for an aim that has none.
  ///
  /// Null rather than an empty rectangle: an aim that points straight at its
  /// subject has no zones, and drawing a degenerate box for it would claim it
  /// has some that happen to be tiny.
  CameraGuides? get guides;
}

/// Keeps whatever rotation it was given.
class StaticAim implements CameraAim {
  /// A fixed rotation is not composing anything.
  @override
  CameraGuides? get guides => null;

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
  /// Pointed straight at the subject: no zones to draw.
  @override
  CameraGuides? get guides => null;

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

  /// The zones as fractions of the frame.
  ///
  /// The widths are half-extents in normalised coordinates, where the frame
  /// runs from minus one to one — so a half-extent of a tenth is a rectangle
  /// a fifth of the frame across. Getting that factor wrong draws a box half
  /// the size of the one the camera is actually using, which is worse than
  /// drawing none.
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
  /// Aimed by hand rather than at anything.
  @override
  CameraGuides? get guides => null;

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
