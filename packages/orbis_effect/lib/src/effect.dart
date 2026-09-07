import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import 'ease.dart';

/// What an effect has done, at a moment.
///
/// A difference rather than a state: an offset from where something was, a
/// turn from how it was facing, a multiplier on how big it was. That is what
/// lets two effects run at once — moving and spinning, fading and growing —
/// and be added together without either needing to know about the other.
class Change {
  Change({
    Vector3? move,
    Quaternion? turn,
    Vector3? grow,
    Vector4? tint,
    this.fade = 1,
  }) : move = move ?? Vector3.zero(),
       turn = turn ?? Quaternion.identity(),
       grow = grow ?? Vector3.all(1),
       tint = tint ?? Vector4(1, 1, 1, 1);

  /// Nothing has happened.
  static Change get none => Change();

  /// How far it has moved from where it was.
  final Vector3 move;

  /// How far it has turned from how it was facing.
  ///
  /// Apply it with [applied], not with `Quaternion.rotated`: vector_math's
  /// own vector rotation turns the opposite way from composing the same
  /// quaternion into a matrix, and the matrix is what a renderer uses.
  final Quaternion turn;

  /// How much bigger it is than it was. One is unchanged.
  final Vector3 grow;

  /// What its colour is multiplied by.
  final Vector4 tint;

  /// What its opacity is multiplied by.
  final double fade;

  /// Two changes, both applied.
  ///
  /// Offsets add, turns compose, scales and tints multiply — each combined
  /// the way that quantity actually combines, which is why this cannot be one
  /// loop over a list of doubles.
  Change and(Change other) => Change(
    move: move + other.move,
    turn: turn * other.turn,
    grow: Vector3(
      grow.x * other.grow.x,
      grow.y * other.grow.y,
      grow.z * other.grow.z,
    ),
    tint: Vector4(
      tint.x * other.tint.x,
      tint.y * other.tint.y,
      tint.z * other.tint.z,
      tint.w * other.tint.w,
    ),
    fade: fade * other.fade,
  );

  /// Whether this changes anything at all.
  bool get isNothing =>
      move.length2 < 1e-18 &&
      (grow - Vector3.all(1)).length2 < 1e-18 &&
      (fade - 1).abs() < 1e-9 &&
      (turn.w - 1).abs() < 1e-9;

  @override
  String toString() => 'Change(move: $move, grow: $grow, fade: $fade)';
}

/// A change stated as a function of time.
///
/// **Sampled, not stepped.** An effect is asked what it looks like at a
/// moment, rather than being advanced by a frame's worth. That is the same
/// choice the sequencer makes, and for the same reasons: it can be scrubbed
/// backwards, it gives the same answer at the same moment however the frames
/// fell, and a test can ask about the middle without running the beginning.
///
/// The cost is that an effect cannot depend on where the thing currently is.
/// `MoveBy` is expressible and "move towards whatever is nearest" is not —
/// that is steering, and it lives in a different package on purpose.
abstract class Effect {
  const Effect();

  /// How long it lasts, in seconds. Infinite for one that never ends.
  double get duration;

  /// What it has done by [at] seconds in.
  ///
  /// Before it starts and after it ends the answer is still defined: an
  /// effect holds its end state rather than snapping back, because a sequence
  /// asks its earlier members what they finished as while a later one runs.
  Change at(double seconds);

  /// Whether it has finished by [seconds].
  bool doneBy(double seconds) => seconds >= duration;
}

/// Nothing, for a while.
///
/// The join in a sequence, and the only way to say "then, after a pause".
class Wait extends Effect {
  const Wait(this.duration);

  @override
  final double duration;

  @override
  Change at(double seconds) => Change.none;
}

/// A straight change from nothing to something.
///
/// The base every concrete effect below is: a curve over a fraction, and a
/// quantity scaled by it.
abstract class _Tween extends Effect {
  const _Tween(this.duration, this.ease);

  @override
  final double duration;
  final Ease ease;

  /// How far through, curved, clamped at both ends.
  double progress(double seconds) {
    if (duration <= 0) return 1;
    return ease((seconds / duration).clamp(0.0, 1.0));
  }
}

/// Moved by an offset.
class MoveBy extends _Tween {
  const MoveBy(this.offset, double duration, {Ease ease = Eases.outQuad})
    : super(duration, ease);

  final Vector3 offset;

  @override
  Change at(double seconds) => Change(move: offset * progress(seconds));
}

/// Turned by an angle about an axis, in radians.
class TurnBy extends _Tween {
  TurnBy(
    this.angle, {
    required double duration,
    Vector3? axis,
    Ease ease = Eases.inOutQuad,
  }) : axis = axis ?? Vector3(0, 1, 0),
       super(duration, ease);

  final double angle;
  final Vector3 axis;

  @override
  Change at(double seconds) => Change(
    turn: Quaternion.axisAngle(axis.normalized(), angle * progress(seconds)),
  );
}

/// Grown or shrunk towards a multiplier.
class GrowTo extends _Tween {
  GrowTo(this.factor, double duration, {Ease ease = Eases.outBack})
    : super(duration, ease);

  final Vector3 factor;

  @override
  Change at(double seconds) {
    final t = progress(seconds);
    // From one towards the factor, so a half-finished grow is halfway there
    // rather than half the size.
    return Change(
      grow: Vector3(
        1 + (factor.x - 1) * t,
        1 + (factor.y - 1) * t,
        1 + (factor.z - 1) * t,
      ),
    );
  }
}

/// Faded towards an opacity.
class FadeTo extends _Tween {
  const FadeTo(this.opacity, double duration, {Ease ease = Eases.linear})
    : super(duration, ease);

  final double opacity;

  @override
  Change at(double seconds) =>
      Change(fade: 1 + (opacity - 1) * progress(seconds));
}

/// Tinted towards a colour.
class TintTo extends _Tween {
  TintTo(this.colour, double duration, {Ease ease = Eases.linear})
    : super(duration, ease);

  final Vector4 colour;

  @override
  Change at(double seconds) {
    final t = progress(seconds);
    return Change(
      tint: Vector4(
        1 + (colour.x - 1) * t,
        1 + (colour.y - 1) * t,
        1 + (colour.z - 1) * t,
        1 + (colour.w - 1) * t,
      ),
    );
  }
}

/// One after another.
///
/// Each member's end is held while the ones after it run, so the whole is the
/// sum of everything that has happened rather than only of what is happening.
/// Without that, a move followed by a turn would snap back to the start of
/// the move the moment the turn began.
class Then extends Effect {
  const Then(this.steps);

  final List<Effect> steps;

  @override
  double get duration =>
      steps.fold(0.0, (total, step) => total + step.duration);

  @override
  Change at(double seconds) {
    var change = Change.none;
    var spent = 0.0;

    for (final step in steps) {
      // Every member that has finished contributes its end; the one running
      // contributes where it is; the ones after contribute nothing.
      if (seconds >= spent + step.duration) {
        change = change.and(step.at(step.duration));
      } else if (seconds > spent) {
        change = change.and(step.at(seconds - spent));
        return change;
      } else {
        return change;
      }
      spent += step.duration;
    }
    return change;
  }
}

/// All at once.
class Both extends Effect {
  const Both(this.parts);

  final List<Effect> parts;

  @override
  double get duration => parts.fold(
    0.0,
    (longest, part) => part.duration > longest ? part.duration : longest,
  );

  @override
  Change at(double seconds) {
    var change = Change.none;
    for (final part in parts) {
      change = change.and(part.at(seconds));
    }
    return change;
  }
}

/// The same thing again, a number of times or for ever.
class Again extends Effect {
  const Again(this.inner, {this.times});

  final Effect inner;

  /// How many runs. Null never stops.
  final int? times;

  @override
  double get duration =>
      times == null ? double.infinity : inner.duration * times!;

  @override
  Change at(double seconds) {
    if (inner.duration <= 0) return inner.at(0);
    if (times != null && seconds >= duration) return inner.at(inner.duration);
    // The modulo is what makes a repeat cost nothing to scrub to: the
    // thousandth run is as cheap to ask about as the first.
    return inner.at(seconds % inner.duration);
  }
}

/// Out, and back the way it came.
class OutAndBack extends Effect {
  const OutAndBack(this.inner);

  final Effect inner;

  @override
  double get duration => inner.duration * 2;

  @override
  Change at(double seconds) {
    final half = inner.duration;
    if (seconds <= half) return inner.at(seconds);
    if (seconds >= duration) return inner.at(0);
    return inner.at(half - (seconds - half));
  }
}

/// Nothing until it starts.
class After extends Effect {
  const After(this.delay, this.inner);

  final double delay;
  final Effect inner;

  @override
  double get duration => delay + inner.duration;

  @override
  Change at(double seconds) =>
      seconds <= delay ? Change.none : inner.at(seconds - delay);
}

/// Somebody's effects, and the clock they are on.
///
/// A thin thing on purpose: it holds a time and a list, and everything
/// interesting is in the effects. What it adds is the two questions a host
/// actually asks — what does everything come to right now, and what has
/// finished and can be dropped.
class Playing {
  Playing();

  final List<Effect> _running = [];
  final List<double> _startedAt = [];
  Change _settled = Change.none;
  double _now = 0;

  double get now => _now;
  int get length => _running.length;

  /// What the effects that have finished came to.
  ///
  /// Kept rather than dropped, and this is the part that is easy to get
  /// wrong: a change is a *difference* from where something was, so an
  /// effect removed the moment it finishes takes its offset with it and the
  /// thing snaps back to where it started. It stays here until a host folds
  /// it into the transform with [bake].
  Change get settled => _settled;

  /// Starts [effect] at the current moment.
  void start(Effect effect) {
    _running.add(effect);
    _startedAt.add(_now);
  }

  /// Moves the clock on and drops anything that has finished.
  ///
  /// Returns what has just finished, because "it has stopped" is the moment a
  /// host wants to do the next thing and polling for it is worse.
  List<Effect> advance(double seconds) {
    _now += seconds;
    final done = <Effect>[];
    for (var i = _running.length - 1; i >= 0; i--) {
      if (_running[i].doneBy(_now - _startedAt[i])) {
        final finished = _running.removeAt(i);
        _startedAt.removeAt(i);
        // Its end is kept, not dropped. See [settled].
        _settled = _settled.and(finished.at(finished.duration));
        done.add(finished);
      }
    }
    return done.reversed.toList();
  }

  /// Everything running and everything finished, added together.
  Change get change {
    var total = _settled;
    for (var i = 0; i < _running.length; i++) {
      total = total.and(_running[i].at(_now - _startedAt[i]));
    }
    return total;
  }

  /// Takes what has finished, so a host can fold it into the transform.
  ///
  /// After this, [change] is only what is still running — which is what a
  /// host wants once it has moved the thing itself. Without it the settled
  /// part grows for as long as the object lives.
  Change bake() {
    final taken = _settled;
    _settled = Change.none;
    return taken;
  }

  void clear() {
    _running.clear();
    _startedAt.clear();
    _settled = Change.none;
  }
}

/// A change applied to a transform.
///
/// Here rather than in the renderer because it is the same arithmetic
/// wherever it happens, and a host that wrote it itself would be a host that
/// composed the rotation in a different order.
Matrix4 applied(Matrix4 to, Change change) {
  final translation = to.getTranslation();
  final rotation = Quaternion.fromRotation(to.getRotation());
  final scale = Vector3(
    to.getColumn(0).length,
    to.getColumn(1).length,
    to.getColumn(2).length,
  );

  return Matrix4.compose(
    translation + change.move,
    rotation * change.turn,
    Vector3(
      scale.x * change.grow.x,
      scale.y * change.grow.y,
      scale.z * change.grow.z,
    ),
  );
}

/// A shake, as a function of time.
///
/// Worked out from the clock rather than rolled, so the same second of the
/// same shake looks the same twice — which is what makes a replay a replay
/// and lets a test assert on it.
class Shake extends _Tween {
  const Shake(
    this.strength,
    double duration, {
    this.rate = 24,
    this.seed = 0,
    Ease ease = Eases.linear,
  }) : super(duration, ease);

  /// How far it moves, in metres.
  final double strength;

  /// How many times a second.
  final double rate;
  final int seed;

  @override
  Change at(double seconds) {
    if (seconds >= duration) return Change.none;
    // Fading out over its life, so a shake ends rather than stops.
    final left = 1 - progress(seconds);
    final step = seconds * rate;
    return Change(
      move: Vector3(
        _wobble(seed, step) * strength * left,
        _wobble(seed + 977, step) * strength * left,
        _wobble(seed + 1699, step) * strength * left,
      ),
    );
  }

  static double _wobble(int seed, double t) {
    final floor = t.floor();
    final f = t - floor;
    final a = _point(seed, floor);
    final b = _point(seed, floor + 1);
    final blend = f * f * (3 - 2 * f);
    return a + (b - a) * blend;
  }

  static double _point(int seed, int at) {
    var h = (at * 374761393 + seed * 668265263) & 0x7FFFFFFF;
    h = (h ^ (h >> 13)) * 1274126177 & 0x7FFFFFFF;
    h ^= h >> 16;
    return (h % 20001) / 10000.0 - 1.0;
  }
}

/// A number eased between two values — the smallest useful effect there is.
double lerp(double from, double to, double t) => from + (to - from) * t;

/// The angle between two directions, the short way round.
double shortestTurn(double from, double to) {
  var difference = (to - from) % (2 * math.pi);
  if (difference > math.pi) difference -= 2 * math.pi;
  if (difference < -math.pi) difference += 2 * math.pi;
  return difference;
}
