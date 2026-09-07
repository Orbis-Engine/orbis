import 'dart:math' as math;

/// How a value gets from one end of a change to the other.
///
/// A curve takes a fraction of the way through and returns a fraction of the
/// way there. Linear is a machine moving something; everything else is the
/// difference between an interface that feels made and one that feels
/// generated.
typedef Ease = double Function(double t);

/// The named curves, so a call site says what it wants rather than a formula.
abstract final class Eases {
  /// Straight through. For anything mechanical, and for a value that has to
  /// meet another one exactly.
  static double linear(double t) => t;

  /// Slow away, fast arrival. Something falling, or being dropped.
  static double inQuad(double t) => t * t;
  static double inCubic(double t) => t * t * t;

  /// Fast away, slow arrival. The default for anything a person asked for:
  /// it answers immediately and settles rather than stopping dead.
  static double outQuad(double t) => 1 - (1 - t) * (1 - t);
  static double outCubic(double t) => 1 - math.pow(1 - t, 3).toDouble();

  /// Slow at both ends. For something moving of its own accord.
  static double inOutQuad(double t) =>
      t < 0.5 ? 2 * t * t : 1 - math.pow(-2 * t + 2, 2).toDouble() / 2;

  static double inOutCubic(double t) =>
      t < 0.5 ? 4 * t * t * t : 1 - math.pow(-2 * t + 2, 3).toDouble() / 2;

  /// Overshoots and comes back. A small exaggeration reads as weight.
  static double outBack(double t) {
    const overshoot = 1.70158;
    final u = t - 1;
    return 1 + (overshoot + 1) * u * u * u + overshoot * u * u;
  }

  /// Settles with a wobble. Sparingly: it is charming once and tiring twice.
  static double outElastic(double t) {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    const period = 2 * math.pi / 3;
    return math.pow(2, -10 * t) * math.sin((t * 10 - 0.75) * period) + 1;
  }

  /// Lands, bounces, lands.
  static double outBounce(double t) {
    const n = 7.5625;
    const d = 2.75;
    if (t < 1 / d) return n * t * t;
    if (t < 2 / d) {
      final u = t - 1.5 / d;
      return n * u * u + 0.75;
    }
    if (t < 2.5 / d) {
      final u = t - 2.25 / d;
      return n * u * u + 0.9375;
    }
    final u = t - 2.625 / d;
    return n * u * u + 0.984375;
  }

  /// Any curve, run backwards.
  static Ease reversed(Ease ease) =>
      (t) => 1 - ease(1 - t);

  /// Any curve, out and back within one run.
  ///
  /// For a pulse, a flash, a nudge — where the value has to end where it
  /// started and writing that as two effects is twice the work and twice the
  /// chance of them disagreeing about the middle.
  static Ease thereAndBack(Ease ease) =>
      (t) => t < 0.5 ? ease(t * 2) : ease((1 - t) * 2);
}
