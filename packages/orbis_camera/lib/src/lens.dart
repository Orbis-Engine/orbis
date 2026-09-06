import 'dart:math' as math;

/// The optics of a shot.
///
/// Field of view is vertical and in degrees, because that is what every tool an
/// artist will have used states it in — a camera set from a reference should
/// mean the same thing here as it did there.
class Lens {
  const Lens({
    this.fieldOfView = 50,
    this.near = 0.1,
    this.far = 1000,
    this.dutch = 0,
    this.orthographic = false,
    this.height = 10,
  });

  /// A lens for a game seen flat on: no perspective, and a height in world
  /// units rather than an angle.
  const Lens.flat({
    required this.height,
    this.near = -100,
    this.far = 100,
    this.dutch = 0,
  }) : fieldOfView = 50,
       orthographic = true;

  /// Vertical field of view, in degrees.
  final double fieldOfView;

  final double near;
  final double far;

  /// Roll about the view axis, in degrees. Named as cinema names it.
  final double dutch;

  /// Whether parallel lines stay parallel.
  ///
  /// A flat lens is not a very long one. Perspective at a narrow angle still
  /// converges, so a sprite at the edge of the frame is still seen slightly
  /// from the side — which is exactly the thing a game seen flat on must not
  /// do, because its art was drawn face on.
  final bool orthographic;

  /// How much of the world fits in the frame from top to bottom, in metres.
  ///
  /// The flat lens's answer to a field of view, and the reason it is a
  /// separate number: an angle means nothing without a distance, and a flat
  /// lens has no distance. Ignored when the lens has perspective.
  final double height;

  /// Blends two lenses. Field of view is interpolated logarithmically, since
  /// the perceived change between 20 and 30 degrees is far larger than between
  /// 90 and 100 — linear interpolation makes a zoom feel like it accelerates.
  static Lens lerp(Lens a, Lens b, double t) {
    if (t <= 0) return a;
    if (t >= 1) return b;
    return Lens(
      // Interpolated through its logarithm, because a zoom looks even when
      // the angle halves in equal times rather than falling by equal amounts.
      fieldOfView: math.exp(
        _lerp(math.log(a.fieldOfView), math.log(b.fieldOfView), t),
      ),
      near: _lerp(a.near, b.near, t),
      far: _lerp(a.far, b.far, t),
      dutch: _lerp(a.dutch, b.dutch, t),
      // A blend from a flat lens to one with perspective has no honest middle,
      // so it takes the destination's kind from the start and only the numbers
      // move. Crossing between them is a cut, not a blend.
      orthographic: b.orthographic,
      height: math.exp(_lerp(math.log(a.height), math.log(b.height), t)),
    );
  }

  Lens copyWith({
    double? fieldOfView,
    double? near,
    double? far,
    double? dutch,
    bool? orthographic,
    double? height,
  }) => Lens(
    fieldOfView: fieldOfView ?? this.fieldOfView,
    near: near ?? this.near,
    far: far ?? this.far,
    dutch: dutch ?? this.dutch,
    orthographic: orthographic ?? this.orthographic,
    height: height ?? this.height,
  );

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  @override
  String toString() => orthographic
      ? 'Lens.flat(${height.toStringAsFixed(1)} m)'
      : 'Lens(${fieldOfView.toStringAsFixed(1)}°)';
}
