import 'dart:math' as math;

/// The shape of a change over its own span.
///
/// Nought to one in, nought to one out. Everything that eases in this package
/// — a clip blending in, a keyframe reaching the next, a shot handing over to
/// the next shot — goes through one of these, so a sequence eases the same way
/// wherever the easing happens to be.
enum Easing {
  /// No shaping at all. Right for anything mechanical, and wrong for almost
  /// everything a person is meant to watch.
  linear,

  /// Starts slowly. Something getting under way.
  in_,

  /// Ends slowly. Something arriving.
  out,

  /// Both. The default, and what almost every hand-animated move does
  /// without being asked.
  inOut,

  /// Smoothstep — gentler than [inOut] at the ends and quicker through the
  /// middle. What a camera move wants when it must not draw attention.
  smooth,

  /// Overshoots and comes back. A snap, a pop, a lid closing.
  back,

  /// Runs past and settles. Weight arriving.
  bounce,
}

/// Applies an easing to a fraction that is already between nought and one.
double ease(Easing shape, double at) {
  final t = at.clamp(0.0, 1.0);
  switch (shape) {
    case Easing.linear:
      return t;
    case Easing.in_:
      return t * t;
    case Easing.out:
      return 1 - (1 - t) * (1 - t);
    case Easing.inOut:
      return t < 0.5 ? 2 * t * t : 1 - math.pow(-2 * t + 2, 2) / 2;
    case Easing.smooth:
      return t * t * (3 - 2 * t);
    case Easing.back:
      // The constants are the usual ones: enough overshoot to read as a snap
      // without looking like a mistake.
      const overshoot = 1.70158;
      const scaled = overshoot + 1;
      return 1 + scaled * math.pow(t - 1, 3) + overshoot * math.pow(t - 1, 2);
    case Easing.bounce:
      const n = 7.5625;
      const d = 2.75;
      var x = t;
      if (x < 1 / d) return n * x * x;
      if (x < 2 / d) return n * (x -= 1.5 / d) * x + 0.75;
      if (x < 2.5 / d) return n * (x -= 2.25 / d) * x + 0.9375;
      return n * (x -= 2.625 / d) * x + 0.984375;
  }
}
