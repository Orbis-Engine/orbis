import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

/// How a stick's raw deflection becomes the number a game acts on.
///
/// Three things, and the engine owns all three because every game gets the
/// same three wrong in the same way.
///
/// **The dead zone is radial.** A stick at rest does not sit exactly at zero,
/// so something near the middle has to be thrown away — but throwing it away
/// per axis, which is the obvious way and the usual way, squares off the
/// middle of the stick. Push gently up and to the right on a pad with a
/// per-axis dead zone of 0.2 and nothing happens until one axis crosses 0.2,
/// at which point the character moves straight up rather than diagonally. The
/// stick can no longer do a slow diagonal at all. Measuring the distance from
/// the centre instead leaves the dead zone round, which is the shape the
/// hardware's problem actually has.
///
/// **What is left is rescaled.** Cutting out the middle and passing the rest
/// through unchanged means the first thing past the dead zone is a jump
/// straight to [inner] — a character that will not creep, because its slowest
/// possible walk is fifteen per cent of full speed. Rescaling the remainder
/// back onto nought-to-one is what makes the stick continuous.
///
/// **The outside saturates early.** A stick that has been used for a year
/// cannot quite reach its corners, and a game where full speed is unreachable
/// on a worn pad is a game that feels broken on exactly the pads that have
/// been played the most.
class Shaping {
  const Shaping({this.inner = 0.15, this.outer = 0.95, this.curve = 1.0});

  /// What a trigger wants: a much smaller dead zone, because a trigger rests
  /// against a stop rather than on a spring and does not drift, and a curve of
  /// one, because a trigger is usually a throttle and a throttle should be
  /// linear.
  static const Shaping triggers = Shaping(inner: 0.06, outer: 0.98);

  /// No shaping at all. For a calibration screen, and for tests.
  static const Shaping none = Shaping(inner: 0, outer: 1);

  /// How far from the middle is treated as the middle.
  final double inner;

  /// How far from the middle counts as all the way.
  final double outer;

  /// The shape of everything in between: one is linear, above one gives finer
  /// control near the middle at the cost of the ends, below one the reverse.
  ///
  /// Left at one by default. A curve is a feel, and a feel is a decision for
  /// the game rather than for the engine — what the engine owes it is the
  /// dial, applied in the right place, which is after the rescale rather than
  /// before it.
  final double curve;

  /// [magnitude], nought to one, with the zone taken out and the rest
  /// rescaled.
  double _shape(double magnitude) {
    if (magnitude <= inner) return 0;
    final span = outer - inner;
    if (span <= 0) return 1;
    final t = ((magnitude - inner) / span).clamp(0.0, 1.0);
    return curve == 1.0 ? t : math.pow(t, curve).toDouble();
  }

  /// One axis on its own — a trigger, or a stick axis a game insists on
  /// reading separately.
  ///
  /// Keeps the sign, so an axis that runs both ways still does.
  double scalar(double value) {
    if (!value.isFinite) return 0;
    final shaped = _shape(value.abs());
    return value.isNegative ? -shaped : shaped;
  }

  /// A stick, shaped as the one thing it is.
  ///
  /// The direction survives untouched and only the length is shaped, so the
  /// way somebody is pushing is never changed by how hard they are pushing.
  Vector2 stick(Vector2 value) {
    final length = value.length;
    if (!length.isFinite || length <= inner) return Vector2.zero();
    final shaped = _shape(length);
    if (shaped <= 0) return Vector2.zero();
    // Divided by the measured length rather than normalised in place, so a
    // caller's vector is never modified and a zero length never divides.
    return value * (shaped / length);
  }

  @override
  String toString() => 'Shaping($inner..$outer, curve $curve)';
}
