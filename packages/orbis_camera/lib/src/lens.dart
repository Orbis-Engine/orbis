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
  });

  /// Vertical field of view, in degrees.
  final double fieldOfView;

  final double near;
  final double far;

  /// Roll about the view axis, in degrees. Named as cinema names it.
  final double dutch;

  /// Blends two lenses. Field of view is interpolated logarithmically, since
  /// the perceived change between 20 and 30 degrees is far larger than between
  /// 90 and 100 — linear interpolation makes a zoom feel like it accelerates.
  static Lens lerp(Lens a, Lens b, double t) {
    if (t <= 0) return a;
    if (t >= 1) return b;
    return Lens(
      fieldOfView: math.exp(
        _lerp(math.log(a.fieldOfView), math.log(b.fieldOfView), t),
      ),
      near: _lerp(a.near, b.near, t),
      far: _lerp(a.far, b.far, t),
      dutch: _lerp(a.dutch, b.dutch, t),
    );
  }

  Lens copyWith({
    double? fieldOfView,
    double? near,
    double? far,
    double? dutch,
  }) => Lens(
    fieldOfView: fieldOfView ?? this.fieldOfView,
    near: near ?? this.near,
    far: far ?? this.far,
    dutch: dutch ?? this.dutch,
  );

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  @override
  String toString() => 'Lens(${fieldOfView.toStringAsFixed(1)}°)';
}
