import 'channel.dart';
import 'clip.dart';

/// What a sequence has to say at one moment.
///
/// Filled in by the tracks and handed to whoever is driving the scene. It
/// carries values rather than effects: nothing here has touched an object,
/// so the same frame can be applied to a live scene, compared against another
/// take, or thrown away by a scrub that has already moved on.
class SequenceFrame {
  SequenceFrame(this.at);

  /// The moment it describes, in sequence time.
  final double at;

  /// Binding, then property, then the value — already mixed across every
  /// clip that had something to say about it.
  final Map<String, Map<String, Object?>> values = {};

  /// Bindings a sequence says should exist right now. Absent means "not
  /// mentioned", which is not the same as false: a track that has ended
  /// stops asking rather than switching things off.
  final Map<String, bool> active = {};

  /// Sounds that should be playing, and how far into each one the sequence
  /// has reached.
  final List<SoundAt> sounds = [];

  /// Camera shots and how much say each has. Adjacent clips give one at a
  /// time, which is a cut; overlapping clips give two, which is a blend.
  final List<ShotAt> shots = [];

  /// Sub-sequences running inside this one, already resolved into this frame.
  final List<String> running = [];

  void put(String binding, String property, Object? value) {
    (values[binding] ??= {})[property] = value;
  }

  Object? get(String binding, String property) => values[binding]?[property];
}

/// A sound the sequence wants playing, and where in it the playhead is.
class SoundAt {
  const SoundAt(this.sound, this.at, this.gain, {this.binding});

  final String sound;
  final double at;
  final double gain;

  /// Where it is coming from, or null for a sound that is simply playing —
  /// music, narration, a stinger.
  final String? binding;
}

/// A camera the sequence is looking through, and how much.
class ShotAt {
  const ShotAt(this.camera, this.weight);

  final String camera;
  final double weight;
}

/// Something that happened at a moment rather than over a span.
class Mark {
  const Mark(this.at, this.name, {this.payload});

  final double at;
  final String name;

  /// Whatever the receiver needs. Deliberately untyped: a sequence should not
  /// have to know what a door opening takes as an argument.
  final Object? payload;
}

/// One row of a sequence.
abstract class Track {
  const Track({this.name, this.binding, this.muted = false});

  /// What it is called in an editor.
  final String? name;

  /// What it drives, resolved by whoever is applying the frame. A name rather
  /// than an object, because a sequence is an asset: the same cutscene plays
  /// on this scene's crate and on the next scene's crate, and neither of them
  /// exists when it is written.
  final String? binding;

  /// Off, but still in the sequence. What an editor toggles while working.
  final bool muted;

  /// When it stops having anything to say.
  double get end;

  /// Adds what it has to say at [at] to [frame].
  void contribute(double at, SequenceFrame frame);

  /// Every mark strictly inside the span, in order. Only event tracks have
  /// any; the rest answer with nothing.
  Iterable<Mark> marksIn(double from, double to) => const [];
}

/// A clip that carries a curve.
class Keyed<T> {
  const Keyed(this.clip, this.channel);

  final Clip clip;

  /// Sampled in the clip's own time, so trimming the front of a clip does not
  /// shift its keys and changing its speed does not rewrite them.
  final Channel<T> channel;
}

/// A track that drives one named property.
///
/// Generic so that a rotation is mixed as a rotation. The frame it writes into
/// is not, which is deliberate: whoever applies it knows what a `rotation` is
/// and the frame is only carrying it.
class PropertyTrack<T> extends Track {
  const PropertyTrack({
    required this.property,
    required this.clips,
    required this.mixer,
    super.name,
    super.binding,
    super.muted,
  });

  final String property;
  final List<Keyed<T>> clips;
  final Mixer<T> mixer;

  @override
  double get end => clips.fold(0.0, (most, one) => one.clip.end > most ? one.clip.end : most);

  /// The value at [at], or null where no clip covers it.
  ///
  /// Null rather than a default, because "this track says nothing here" and
  /// "this track says zero here" have to be different — the first leaves the
  /// object where the scene put it.
  T? valueAt(double at) {
    List<T>? values;
    List<double>? weights;
    for (final one in clips) {
      final weight = one.clip.weightAt(at);
      if (weight <= 0) continue;
      (values ??= []).add(one.channel.at(one.clip.localAt(at)));
      (weights ??= []).add(weight);
    }
    if (values == null) return null;
    if (values.length == 1) return values.first;
    return mixer.mix(values, weights!);
  }

  @override
  void contribute(double at, SequenceFrame frame) {
    if (muted || binding == null) return;
    final value = valueAt(at);
    if (value == null) return;
    frame.put(binding!, property, value);
  }
}

/// A track that says whether the thing it is bound to is there.
class ActivationTrack extends Track {
  const ActivationTrack({
    required this.clips,
    super.name,
    super.binding,
    super.muted,
  });

  final List<Clip> clips;

  @override
  double get end => clips.fold(0.0, (most, one) => one.end > most ? one.end : most);

  /// Whether the thing should be there at [at], or null where the track has
  /// no opinion.
  ///
  /// Three answers rather than two, and the third is the important one.
  /// Before the first clip and after the last, a sequence that has finished
  /// should leave the scene as it found it rather than switching everything
  /// off. The gaps *between* clips are the part where it does say off.
  bool? contributionAt(double at) {
    if (clips.isEmpty) return null;
    var from = double.infinity;
    var to = double.negativeInfinity;
    var covered = false;
    for (final clip in clips) {
      if (clip.start < from) from = clip.start;
      if (clip.end > to) to = clip.end;
      covered = covered || clip.covers(at);
    }
    if (at < from || at >= to) return null;
    return covered;
  }

  @override
  void contribute(double at, SequenceFrame frame) {
    if (muted || binding == null) return;
    final says = contributionAt(at);
    if (says == null) return;
    frame.active[binding!] = says;
  }
}

/// A track of things that happen rather than things that last.
///
/// Marks are the only part of a sequence that is not a function of the moment,
/// because "it happened" is about an interval and not a point. They come out
/// of [marksIn] rather than out of a frame, which is what keeps a scrub
/// backwards from firing a door open.
class MarkTrack extends Track {
  const MarkTrack({
    required this.marks,
    super.name,
    super.binding,
    super.muted,
  });

  /// In ascending order of [Mark.at].
  final List<Mark> marks;

  @override
  double get end => marks.isEmpty ? 0 : marks.last.at;

  @override
  void contribute(double at, SequenceFrame frame) {}

  @override
  Iterable<Mark> marksIn(double from, double to) sync* {
    if (muted || to <= from) return;
    for (final mark in marks) {
      if (mark.at > from && mark.at <= to) yield mark;
    }
  }
}

/// A track of sounds.
class SoundTrack extends Track {
  const SoundTrack({
    required this.clips,
    this.gain = 1.0,
    super.name,
    super.binding,
    super.muted,
  });

  /// The clip's own time is where in the sound the playhead is, so trimming a
  /// clip's front starts the sound part-way in and slowing it down is a
  /// slowed sound.
  final List<(Clip, String)> clips;
  final double gain;

  @override
  double get end =>
      clips.fold(0.0, (most, one) => one.$1.end > most ? one.$1.end : most);

  @override
  void contribute(double at, SequenceFrame frame) {
    if (muted) return;
    for (final (clip, sound) in clips) {
      if (!clip.covers(at)) continue;
      frame.sounds.add(SoundAt(
        sound,
        clip.localAt(at),
        gain * clip.weightAt(at),
        binding: binding,
      ));
    }
  }
}

/// A track of camera shots.
///
/// Two clips that touch are a cut and two that overlap are a blend, which is
/// the whole of the grammar. Nothing here decides where a camera goes — that
/// is the camera's own business — only which one is being looked through and
/// how much.
class ShotTrack extends Track {
  const ShotTrack({required this.shots, super.name, super.muted});

  final List<(Clip, String)> shots;

  @override
  double get end =>
      shots.fold(0.0, (most, one) => one.$1.end > most ? one.$1.end : most);

  @override
  void contribute(double at, SequenceFrame frame) {
    if (muted) return;
    for (final (clip, camera) in shots) {
      final weight = clip.weightAt(at);
      if (weight <= 0) continue;
      frame.shots.add(ShotAt(camera, weight));
    }
  }
}
