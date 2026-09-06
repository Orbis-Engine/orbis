import 'easing.dart';

/// A span of a track, and how it fades at each end.
///
/// A clip is a placement rather than content: what it *does* is decided by
/// the track it is on. What it decides for itself is when it runs, how fast,
/// and how much say it has at any moment — which is the whole of blending.
class Clip {
  const Clip({
    required this.start,
    required this.duration,
    this.easeIn = 0.0,
    this.easeOut = 0.0,
    this.shapeIn = Easing.inOut,
    this.shapeOut = Easing.inOut,
    this.clipIn = 0.0,
    this.speed = 1.0,
    this.name,
  })  : assert(duration > 0, 'a clip with no length never runs'),
        assert(speed != 0, 'a clip at no speed never advances');

  /// Seconds from the start of the sequence.
  final double start;
  final double duration;

  /// How long the clip takes to reach full say, and to give it up. Two clips
  /// that overlap should have these matched to the overlap; a sequence does
  /// not enforce that, because a deliberate mismatch is a legitimate effect.
  final double easeIn;
  final double easeOut;
  final Easing shapeIn;
  final Easing shapeOut;

  /// How far into its own content the clip starts. Trimming the front of a
  /// take without moving where it sits in the sequence.
  final double clipIn;

  /// How fast the content runs against the sequence's clock. Two plays it at
  /// double; a half is slow motion.
  final double speed;

  /// What it is called on the track. Not an identity — two clips may share a
  /// name — just something to read.
  final String? name;

  double get end => start + duration;

  bool covers(double at) => at >= start && at < end;

  /// How far into the clip's own content [at] is.
  ///
  /// This is what a sub-sequence is sampled at and what a video is seeked to:
  /// where the sequence has reached is not where the clip's content has,
  /// because the clip may have been trimmed and may be running at a different
  /// rate.
  double localAt(double at) => clipIn + (at - start) * speed;

  /// How much say the clip has at [at], from nought outside it to one in the
  /// middle.
  ///
  /// The two fades are separate curves rather than one, because a clip can
  /// blend into the one after it while still holding against the one before.
  double weightAt(double at) {
    if (!covers(at)) return 0;
    var weight = 1.0;
    if (easeIn > 0 && at < start + easeIn) {
      weight = ease(shapeIn, (at - start) / easeIn);
    }
    if (easeOut > 0 && at > end - easeOut) {
      final out = ease(shapeOut, (end - at) / easeOut);
      weight = weight < out ? weight : out;
    }
    return weight.clamp(0.0, 1.0);
  }
}
