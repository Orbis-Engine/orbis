import 'package:vector_math/vector_math_64.dart';

import 'easing.dart';

/// How a value gets from one keyframe to the next.
enum Hold {
  /// It does not. The value jumps at the second key and holds until the one
  /// after. What a visibility flag, a material swap or a subtitle line wants.
  step,

  /// Straight there, at a constant rate. Corners at every key, which is
  /// exactly right for anything mechanical and wrong for anything alive.
  linear,

  /// Eased at both ends of each span, so the value arrives and leaves at
  /// rest. The default: it is what somebody means by "animate this".
  smooth,

  /// Eased with the *shape* the key names, so one span can snap and the next
  /// can settle.
  shaped,
}

/// One value at one moment.
class Key<T> {
  const Key(this.at, this.value, {this.hold = Hold.smooth, this.shape});

  /// Seconds from the start of the sequence.
  final double at;
  final T value;

  /// How the value travels from *this* key to the next. Held on the earlier
  /// key rather than the later one, because a span belongs to the key that
  /// starts it — inserting a key at the end should not change how the one
  /// before it behaves.
  final Hold hold;

  /// Which easing [Hold.shaped] uses. Ignored otherwise.
  final Easing? shape;
}

/// How two values of one kind are mixed.
///
/// Separate from the values because mixing is not always what an operator
/// would do: two rotations are mixed by turning between them, not by
/// averaging four numbers, and two flags are not mixed at all.
abstract class Mixer<T> {
  const Mixer();

  /// [a] at nought, [b] at one.
  T lerp(T a, T b, double t);

  /// Several at once, each with a weight. Used where clips overlap.
  T mix(List<T> values, List<double> weights);
}

class DoubleMixer extends Mixer<double> {
  const DoubleMixer();

  @override
  double lerp(double a, double b, double t) => a + (b - a) * t;

  @override
  double mix(List<double> values, List<double> weights) {
    var total = 0.0;
    var sum = 0.0;
    for (var i = 0; i < values.length; i++) {
      sum += values[i] * weights[i];
      total += weights[i];
    }
    return total == 0 ? 0 : sum / total;
  }
}

class Vector3Mixer extends Mixer<Vector3> {
  const Vector3Mixer();

  @override
  Vector3 lerp(Vector3 a, Vector3 b, double t) => a + (b - a) * t;

  @override
  Vector3 mix(List<Vector3> values, List<double> weights) {
    final sum = Vector3.zero();
    var total = 0.0;
    for (var i = 0; i < values.length; i++) {
      sum.addScaled(values[i], weights[i]);
      total += weights[i];
    }
    return total == 0 ? Vector3.zero() : sum / total;
  }
}

class QuaternionMixer extends Mixer<Quaternion> {
  const QuaternionMixer();

  @override
  Quaternion lerp(Quaternion a, Quaternion b, double t) {
    // The short way round. Without the sign check a turn of a hundred and
    // eighty-one degrees goes the other hundred and seventy-nine.
    final flipped = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w < 0
        ? Quaternion(-b.x, -b.y, -b.z, -b.w)
        : b;
    final out = Quaternion(
      a.x + (flipped.x - a.x) * t,
      a.y + (flipped.y - a.y) * t,
      a.z + (flipped.z - a.z) * t,
      a.w + (flipped.w - a.w) * t,
    );
    out.normalize();
    return out;
  }

  @override
  Quaternion mix(List<Quaternion> values, List<double> weights) {
    if (values.isEmpty) return Quaternion.identity();
    // Accumulated pairwise rather than summed, because the weighted sum of
    // four quaternions is only a rotation by accident.
    var out = values.first;
    var carried = weights.first;
    for (var i = 1; i < values.length; i++) {
      final total = carried + weights[i];
      if (total <= 0) continue;
      out = lerp(out, values[i], weights[i] / total);
      carried = total;
    }
    return out;
  }
}

/// Flags do not blend. Whichever clip has the most say decides.
class BoolMixer extends Mixer<bool> {
  const BoolMixer();

  @override
  bool lerp(bool a, bool b, double t) => t < 0.5 ? a : b;

  @override
  bool mix(List<bool> values, List<double> weights) {
    var best = false;
    var most = -1.0;
    for (var i = 0; i < values.length; i++) {
      if (weights[i] > most) {
        most = weights[i];
        best = values[i];
      }
    }
    return best;
  }
}

const doubleMixer = DoubleMixer();
const vector3Mixer = Vector3Mixer();
const quaternionMixer = QuaternionMixer();
const boolMixer = BoolMixer();

/// A value over time: keys, and the rule for getting between them.
///
/// Sampling is a pure function of the moment asked for. Nothing here
/// remembers where the playhead was, which is what makes scrubbing backwards
/// give the same answer as playing forwards to the same place.
class Channel<T> {
  Channel(this.keys, this.mixer)
    : assert(keys.isNotEmpty, 'a channel with no keys has no value');

  /// In ascending order of [Key.at]. Not sorted here: a channel is built once
  /// and sampled constantly, and sorting on every sample would be the most
  /// expensive thing in a sequence.
  final List<Key<T>> keys;
  final Mixer<T> mixer;

  double get start => keys.first.at;
  double get end => keys.last.at;

  /// The value at [at]. Before the first key it is the first key's value and
  /// after the last it is the last's — a channel does not extrapolate,
  /// because a curve run off its end is a value nobody chose.
  T at(double at) {
    if (at <= keys.first.at) return keys.first.value;
    if (at >= keys.last.at) return keys.last.value;

    var low = 0;
    var high = keys.length - 1;
    while (high - low > 1) {
      final middle = (low + high) ~/ 2;
      if (keys[middle].at <= at) {
        low = middle;
      } else {
        high = middle;
      }
    }

    final from = keys[low];
    final to = keys[high];
    if (from.hold == Hold.step) return from.value;

    final span = to.at - from.at;
    // Two keys at the same moment: the second wins, which is how a cut is
    // written.
    if (span <= 0) return to.value;

    final part = (at - from.at) / span;
    final shaped = switch (from.hold) {
      Hold.linear => part,
      Hold.smooth => ease(Easing.inOut, part),
      Hold.shaped => ease(from.shape ?? Easing.inOut, part),
      Hold.step => 0.0,
    };
    return mixer.lerp(from.value, to.value, shaped);
  }
}
