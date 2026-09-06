import 'track.dart';

/// A cutscene, as a thing rather than as a playing of one.
///
/// A sequence holds no playhead and no bindings. It is the score, not the
/// performance: the same one plays on this scene's crate and the next
/// scene's, and neither exists when it is written. That separation is what
/// lets an editor scrub it, a game play it, and a test sample it at a
/// hundred moments in any order and get the same answers.
class Sequence {
  const Sequence({
    required this.tracks,
    this.name = 'sequence',
    this.rate = 30,
    double? duration,
  }) : _duration = duration;

  final String name;
  final List<Track> tracks;

  /// Frames a second, for an editor's ruler and for snapping. Sampling never
  /// uses it: a sequence is continuous, and quantising it would make a slow
  /// motion shot judder for no reason anybody asked for.
  final double rate;

  final double? _duration;

  /// How long it runs. Long enough for every track by default, and settable
  /// where a sequence is meant to hold on its last frame for a while.
  double get duration {
    if (_duration != null) return _duration;
    var end = 0.0;
    for (final track in tracks) {
      final theirs = track.end;
      if (theirs > end) end = theirs;
    }
    return end;
  }

  /// Everything the sequence has to say at [at].
  ///
  /// A pure function of the moment. Nothing is remembered between calls,
  /// which is what makes scrubbing backwards give the same answer as playing
  /// forwards to the same place — and what makes a replay of a recorded time
  /// identical on every machine that runs it.
  SequenceFrame sampleAt(double at) {
    final frame = SequenceFrame(at);
    for (final track in tracks) {
      track.contribute(at, frame);
    }
    return frame;
  }

  /// The marks crossed going from [from] to [to], in the order they happened.
  ///
  /// Empty when [to] is not after [from]: running a scene backwards should
  /// not open the door again. A step large enough to skip several fires all
  /// of them rather than only the last, so a dropped frame does not lose an
  /// event.
  List<Mark> marksBetween(double from, double to) {
    final crossed = <Mark>[];
    for (final track in tracks) {
      crossed.addAll(track.marksIn(from, to));
    }
    crossed.sort((a, b) => a.at.compareTo(b.at));
    return crossed;
  }

  /// The nearest frame boundary to [at], for an editor that snaps.
  double snap(double at) => (at * rate).round() / rate;
}
