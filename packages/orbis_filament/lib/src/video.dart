/// A moving picture, playing.
///
/// Described the same way as everything else here: the host says what state
/// the video should be in and the renderer works out what to do about it. A
/// video that is already playing the right file at the right rate costs
/// nothing to say again, which is what lets a scene be published whole on
/// every frame.
class OrbisVideo {
  const OrbisVideo({
    required this.key,
    required this.path,
    this.playing = true,
    this.loop = true,
    this.rate = 1.0,
    this.volume = 1.0,
    this.seekTo,
    this.seekToken = 0,
  });

  /// This video's identity, stable for as long as it exists.
  final int key;

  /// An absolute path to the file, or a URL. What can be decoded is whatever
  /// the platform decodes: on macOS that is H.264 and HEVC in mp4 and mov,
  /// which between them is nearly everything anybody has.
  final String path;

  final bool playing;

  /// Whether it starts again at the end. False leaves it on its last frame,
  /// which is what a cutscene wants.
  final bool loop;

  /// How fast, as a multiple. Half is slow motion.
  final double rate;

  final double volume;

  /// Where to jump to, in seconds.
  ///
  /// A jump is an event and this message is a description, so the two are
  /// reconciled by [seekToken]: the renderer only acts on this when the token
  /// has moved. Saying the same seek again is not a second seek, and a scene
  /// published sixty times a second does not fight the playhead.
  final double? seekTo;
  final int seekToken;

  /// How many floats one video contributes to the message.
  static const int stride = 4;

  int get flags => (playing ? 1 : 0) | (loop ? 2 : 0);
}
