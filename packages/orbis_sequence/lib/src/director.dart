import 'sequence.dart';
import 'track.dart';

/// What happens when a sequence reaches its end.
enum WhenDone {
  /// Stops on the last frame and stays there. What a cutscene wants: the
  /// scene should be left where the sequence put it, not snapped back.
  hold,

  /// Starts again. An idle, an ambience, a looping shot.
  loop,

  /// Runs backwards to the start, then forwards again.
  bounce,

  /// Stops and lets go, so the scene returns to whatever else is driving it.
  release,
}

/// A sequence being played.
///
/// The only stateful thing in this package, and it holds exactly two numbers:
/// where the playhead is and whether it is moving. Everything else is asked of
/// the sequence, which means a director can be seeked anywhere at any time and
/// nothing has to be unwound.
class Director {
  Director(this.sequence, {this.whenDone = WhenDone.hold, this.speed = 1.0});

  final Sequence sequence;
  WhenDone whenDone;

  /// How fast sequence time runs against whatever clock is advancing it.
  /// Negative plays it backwards, which is a legitimate thing to ask for and
  /// which fires no marks.
  double speed;

  double _at = 0;
  bool _playing = false;
  int _direction = 1;

  /// Where the playhead is, in seconds.
  double get at => _at;

  bool get playing => _playing;

  /// Whether the playhead has run off the end and stopped.
  bool get finished =>
      !_playing && whenDone != WhenDone.loop && _at >= sequence.duration;

  void play() => _playing = true;
  void pause() => _playing = false;

  /// Back to the start, and stopped.
  void stop() {
    _playing = false;
    _direction = 1;
    _at = 0;
  }

  /// Moves the playhead without playing anything.
  ///
  /// Marks are **not** fired: a scrub is somebody looking, not the scene
  /// happening. That is the whole reason marks come out of [advance] and not
  /// out of a sample.
  void seek(double to) {
    _at = to.clamp(0.0, sequence.duration);
  }

  /// Moves the playhead on by [seconds] of wall time and hands back
  /// everything that happened on the way.
  ///
  /// The marks are the crossed ones, in order, however big the step: a frame
  /// dropped under load must not lose an event, and a slow machine must see
  /// the same things happen as a fast one.
  Advanced advance(double seconds) {
    if (!_playing || seconds == 0) {
      return Advanced(sequence.sampleAt(_at), const []);
    }

    final was = _at;
    final step = seconds * speed * _direction;
    var now = was + step;
    final duration = sequence.duration;
    final marks = <Mark>[];

    if (now >= duration && step > 0) {
      // Everything up to the end happens before whatever the wrap does, so a
      // mark on the last frame of a loop fires on every pass rather than only
      // the first.
      marks.addAll(sequence.marksBetween(was, duration));
      switch (whenDone) {
        case WhenDone.hold:
          now = duration;
          _playing = false;
        case WhenDone.release:
          now = duration;
          _playing = false;
        case WhenDone.loop:
          final over = duration <= 0 ? 0.0 : (now - duration) % duration;
          marks.addAll(sequence.marksBetween(-1e-9, over));
          now = over;
        case WhenDone.bounce:
          _direction = -1;
          now = duration - (now - duration);
          if (now < 0) now = 0;
      }
    } else if (now <= 0 && step < 0) {
      // Running backwards fires nothing on the way, by design.
      switch (whenDone) {
        case WhenDone.bounce:
          _direction = 1;
          now = -now;
          if (now > duration) now = duration;
        case WhenDone.loop:
          now = duration;
        case WhenDone.hold:
        case WhenDone.release:
          now = 0;
          _playing = false;
      }
    } else if (step > 0) {
      marks.addAll(sequence.marksBetween(was, now));
    }

    _at = now;
    return Advanced(sequence.sampleAt(_at), marks);
  }

  /// What the sequence says right now, without moving.
  SequenceFrame sample() => sequence.sampleAt(_at);
}

/// One step of a director: where the sequence now stands, and what happened
/// getting there.
class Advanced {
  const Advanced(this.frame, this.marks);

  final SequenceFrame frame;
  final List<Mark> marks;
}
