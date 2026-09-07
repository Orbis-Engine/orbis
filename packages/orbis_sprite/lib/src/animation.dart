import 'atlas.dart';

/// One frame of an animation, and how long it is held.
class Frame {
  const Frame(this.region, this.seconds);

  final Region region;

  /// How long this frame is on screen.
  ///
  /// Per frame rather than one rate for the whole animation, because an
  /// animator's timing is not even: a punch holds on the wind-up and flies
  /// through the strike, and an even rate flattens exactly the part that
  /// carries the weight.
  final double seconds;
}

/// A sequence of frames, sampled by time.
///
/// Sampled rather than stepped, like everything else here that has a clock:
/// asked what it looks like at a moment rather than advanced by a frame's
/// worth. The same animation at the same moment is the same frame however the
/// frames fell, which is what makes a replay match and lets a test ask about
/// the middle without running the beginning.
class SpriteAnimation {
  const SpriteAnimation(this.frames, {this.loop = true, this.pingPong = false});

  /// Every frame at one rate.
  factory SpriteAnimation.at(
    List<Region> regions, {
    double fps = 12,
    bool loop = true,
    bool pingPong = false,
  }) {
    final seconds = fps <= 0 ? 0.0 : 1 / fps;
    return SpriteAnimation(
      [for (final region in regions) Frame(region, seconds)],
      loop: loop,
      pingPong: pingPong,
    );
  }

  /// Every frame of an atlas whose name starts with [prefix], in order.
  factory SpriteAnimation.from(
    Atlas atlas,
    String prefix, {
    double fps = 12,
    bool loop = true,
    bool pingPong = false,
  }) => SpriteAnimation.at(
    atlas.sequence(prefix),
    fps: fps,
    loop: loop,
    pingPong: pingPong,
  );

  final List<Frame> frames;

  /// Whether it starts again at the end.
  final bool loop;

  /// Whether it runs back down instead of jumping to the start.
  ///
  /// For anything that has to end where it began — a breath, a hover, a
  /// blink — where a plain loop shows a jump on every repeat.
  final bool pingPong;

  bool get isEmpty => frames.isEmpty;
  int get length => frames.length;

  /// How long one run takes.
  double get duration =>
      frames.fold(0.0, (total, frame) => total + frame.seconds);

  /// How long a whole cycle takes, the way back included.
  double get cycle => pingPong && frames.length > 1 ? duration * 2 : duration;

  /// Which frame is showing at [seconds].
  int indexAt(double seconds) {
    if (frames.isEmpty) return 0;
    if (duration <= 0) return 0;

    var at = seconds;
    if (at < 0) at = 0;

    if (loop) {
      at = at % cycle;
      if (pingPong && at >= duration) {
        // Coming back down. The far end is not repeated, or the last frame
        // would be held for twice as long as every other.
        at = duration * 2 - at;
      }
    } else if (at >= duration) {
      return frames.length - 1;
    }

    var spent = 0.0;
    for (var i = 0; i < frames.length; i++) {
      spent += frames[i].seconds;
      if (at < spent) return i;
    }
    return frames.length - 1;
  }

  /// Which region is showing at [seconds], or null for an empty animation.
  Region? at(double seconds) =>
      frames.isEmpty ? null : frames[indexAt(seconds)].region;

  /// Whether a non-looping animation has run out.
  bool doneBy(double seconds) => !loop && seconds >= duration;
}

/// A named set of animations and which one is playing.
///
/// The small amount of state a sprite actually has. Kept apart from the
/// animations themselves so that one set of clips serves every copy of a
/// character — the same reason a behaviour tree is stateless.
class Flipbook {
  Flipbook(this.clips, {String? playing})
    : _playing = playing ?? (clips.keys.isEmpty ? '' : clips.keys.first);

  final Map<String, SpriteAnimation> clips;

  String _playing;
  double _since = 0;

  String get playing => _playing;
  double get since => _since;

  SpriteAnimation? get current => clips[_playing];

  /// Switches to [name], starting it from the beginning.
  ///
  /// Playing the same clip again is not a restart. A game says "walk" on
  /// every frame the stick is held, and restarting on each of those is a
  /// character stuck on frame one.
  void play(String name, {bool restart = false}) {
    if (name == _playing && !restart) return;
    if (!clips.containsKey(name)) return;
    _playing = name;
    _since = 0;
  }

  void advance(double seconds) => _since += seconds;

  /// What to draw now.
  Region? get frame => current?.at(_since);

  /// Whether the clip playing has finished. Always false for a loop.
  bool get done => current?.doneBy(_since) ?? true;
}
