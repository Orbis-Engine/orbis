import 'dart:math' as math;

/// How one shot gives way to the next.
enum BlendStyle {
  /// Instant. What a film cut is, and what most transitions should be —
  /// blending everything is a common way to make a game feel sluggish.
  cut,

  linear,

  /// Slow to leave, slow to arrive. The default, because it is what a camera
  /// operator's hands do.
  easeInOut,

  /// Slow to leave, arrives at speed.
  easeIn,

  /// Leaves at speed, slows to arrive.
  easeOut,
}

/// A transition between two shots.
class Blend {
  const Blend(this.style, this.duration);

  const Blend.cut() : this(BlendStyle.cut, 0);

  final BlendStyle style;

  /// Seconds. Ignored for a cut.
  final double duration;

  /// Eased progress from a linear one.
  double ease(double t) {
    final clamped = t.clamp(0.0, 1.0);
    return switch (style) {
      BlendStyle.cut => 1,
      BlendStyle.linear => clamped,
      BlendStyle.easeIn => clamped * clamped,
      BlendStyle.easeOut => 1 - (1 - clamped) * (1 - clamped),
      BlendStyle.easeInOut => 0.5 - 0.5 * math.cos(clamped * math.pi),
    };
  }
}

/// Which blend to use between two named cameras.
///
/// Most transitions want the same treatment, so this is a default with
/// exceptions rather than a table anyone has to fill in. The exceptions are
/// where the direction matters: leaving a cutscene is often a cut, while
/// entering it is a slow ease.
class BlendTable {
  BlendTable({this.defaultBlend = const Blend(BlendStyle.easeInOut, 0.7)});

  final Blend defaultBlend;
  final Map<String, Blend> _specific = {};

  /// Sets the blend for one transition. A null name means "any".
  void set(String? from, String? to, Blend blend) {
    _specific['${from ?? '*'}->${to ?? '*'}'] = blend;
  }

  /// The blend for a transition, most specific rule first.
  Blend between(String? from, String? to) =>
      _specific['$from->$to'] ??
      _specific['$from->*'] ??
      _specific['*->$to'] ??
      defaultBlend;
}
