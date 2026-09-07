import 'package:vector_math/vector_math_64.dart';

/// One plane of a scrolling background.
class Layer {
  const Layer({
    required this.image,
    this.depth = 1,
    this.size = 0,
    this.offset = 0,
    this.drift = 0,
  });

  final String image;

  /// How much of the camera's movement this layer takes, as a fraction.
  ///
  /// One moves with the camera exactly — the ground the player stands on.
  /// Nought does not move at all — the sky. Between them is the illusion:
  /// distant hills at a tenth, mid trees at a half. Above one is a foreground
  /// that rushes past, which is the same trick used the other way.
  final double depth;

  /// How wide the image is in world units, for wrapping. Zero does not wrap.
  final double size;

  /// A fixed shift, for lining a layer up.
  final double offset;

  /// How fast it moves on its own, in world units a second.
  ///
  /// Clouds crossing a sky the camera is not following. Without it every
  /// layer is still whenever the camera is, and a still sky reads as a
  /// painted backdrop rather than as weather.
  final double drift;
}

/// Several layers, and where each of them sits.
///
/// The oldest trick in two dimensions and still the most effective: things
/// further away move less. What makes it read as depth rather than as sliding
/// wallpaper is that the ratios are consistent — a layer at a tenth stays at a
/// tenth however fast the camera goes.
class Parallax {
  const Parallax(this.layers);

  final List<Layer> layers;

  int get length => layers.length;

  /// Where each layer should be drawn, given the camera and the clock.
  ///
  /// A list in the same order as [layers], so a caller can zip them without
  /// looking anything up.
  List<double> at(double camera, double seconds) => [
    for (final layer in layers) _place(layer, camera, seconds),
  ];

  /// Where one layer sits.
  double placeOf(int index, double camera, double seconds) =>
      index < 0 || index >= layers.length
      ? 0
      : _place(layers[index], camera, seconds);

  static double _place(Layer layer, double camera, double seconds) {
    final moved = -camera * layer.depth + layer.offset + layer.drift * seconds;
    if (layer.size <= 0) return moved;

    // Wrapped into one width, so a layer scrolled for an hour is drawn at the
    // same handful of coordinates as one scrolled for a second — and the
    // numbers never grow large enough to lose precision, which is what makes
    // a long-running background start to judder.
    final wrapped = moved % layer.size;
    return wrapped <= 0 ? wrapped : wrapped - layer.size;
  }

  /// How many copies of a layer are needed to cover [across] world units.
  ///
  /// Two more than fit: one for the part scrolled off and one for the part
  /// not yet on. Getting this wrong by one is a gap at the edge of the screen
  /// that appears once per wrap.
  static int copiesFor(Layer layer, double across) {
    if (layer.size <= 0) return 1;
    return (across / layer.size).ceil() + 2;
  }
}

/// A camera in two dimensions, with the bounds it will not leave.
class View2 {
  View2({Vector2? at, this.width = 16, this.height = 9, this.bounds});

  Vector2 at = Vector2.zero();

  final double width;
  final double height;

  /// Where it may go. Null lets it go anywhere.
  final ({Vector2 minimum, Vector2 maximum})? bounds;

  /// Moves the camera towards [target], keeping it inside its bounds.
  ///
  /// [ease] is how much of the remaining distance it covers each second: nought
  /// does not follow at all, and one is instant. A camera that snapped to its
  /// target would shake with the thing it is following.
  void follow(Vector2 target, double seconds, {double ease = 6}) {
    final blend = ease <= 0 ? 0.0 : (1 - _decay(ease, seconds));
    at = at + (target - at) * blend;
    _clamp();
  }

  void jumpTo(Vector2 target) {
    at = target.clone();
    _clamp();
  }

  void _clamp() {
    final limit = bounds;
    if (limit == null) return;
    final halfWide = width * 0.5;
    final halfTall = height * 0.5;

    // The room the camera has is the world minus half a screen on each side.
    // A world narrower than the screen has none, and clamping to a negative
    // range would put the camera outside the world it was being kept inside.
    final lowX = limit.minimum.x + halfWide;
    final highX = limit.maximum.x - halfWide;
    final lowY = limit.minimum.y + halfTall;
    final highY = limit.maximum.y - halfTall;

    at = Vector2(
      lowX > highX
          ? (limit.minimum.x + limit.maximum.x) * 0.5
          : at.x.clamp(lowX, highX),
      lowY > highY
          ? (limit.minimum.y + limit.maximum.y) * 0.5
          : at.y.clamp(lowY, highY),
    );
  }

  /// What is left after a second of decay, raised to the time.
  ///
  /// Framerate independence: following by a fixed fraction each frame follows
  /// twice as fast at twice the frame rate, which is the commonest reason a
  /// camera feels different on two machines.
  static double _decay(double rate, double seconds) {
    var left = 1.0;
    // exp(-rate * seconds) without dart:math, kept exact enough and monotone.
    final steps = (seconds * 240).ceil().clamp(1, 4096);
    final step = seconds / steps;
    for (var i = 0; i < steps; i++) {
      left *= 1 - rate * step;
      if (left <= 0) return 0;
    }
    return left;
  }
}
