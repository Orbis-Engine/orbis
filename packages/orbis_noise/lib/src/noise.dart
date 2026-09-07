import 'dart:math' as math;

/// A field of numbers that varies smoothly and never changes.
///
/// Two properties matter and both are easy to lose. It is **smooth**: two
/// points close together give close answers, which is what separates noise
/// from a random number per sample — random numbers average to nothing and
/// look like static. And it is **the same every time**: the value at a point
/// depends only on the point and the seed, not on what was asked for before
/// it, so a world generated on one machine is the world generated on every
/// other, and a test can assert an exact number.
///
/// Nothing here allocates or holds state. A field is a function.
abstract class Noise {
  const Noise();

  /// The value at a point, between -1 and 1.
  double at(double x, [double y = 0, double z = 0]);

  /// The value scaled and shifted to run from 0 to 1.
  ///
  /// For everything that is a fraction — a probability, a mask, a height
  /// between two limits — where the signed form has to be corrected at every
  /// call site and is eventually corrected wrongly at one of them.
  double unit(double x, [double y = 0, double z = 0]) =>
      at(x, y, z) * 0.5 + 0.5;
}

/// Smooth noise from a value at every whole coordinate.
///
/// Cheap and slightly blocky: the extremes sit on the lattice points, so a
/// field of it has a faint square grain if you look for it. Right for masks,
/// jitter and anything that is going to be blurred or thresholded anyway.
class ValueNoise extends Noise {
  const ValueNoise({this.seed = 0});

  final int seed;

  @override
  double at(double x, [double y = 0, double z = 0]) {
    final xi = x.floor();
    final yi = y.floor();
    final zi = z.floor();
    final xf = _fade(x - xi);
    final yf = _fade(y - yi);
    final zf = _fade(z - zi);

    double corner(int dx, int dy, int dz) =>
        _valueAt(seed, xi + dx, yi + dy, zi + dz);

    final x00 = _mix(corner(0, 0, 0), corner(1, 0, 0), xf);
    final x10 = _mix(corner(0, 1, 0), corner(1, 1, 0), xf);
    final x01 = _mix(corner(0, 0, 1), corner(1, 0, 1), xf);
    final x11 = _mix(corner(0, 1, 1), corner(1, 1, 1), xf);

    return _mix(_mix(x00, x10, yf), _mix(x01, x11, yf), zf);
  }
}

/// Smooth noise from a direction at every whole coordinate.
///
/// Perlin's improvement on the above, and worth the extra work: the value is
/// nought *on* every lattice point and the variation happens between them, so
/// the grid stops being visible. This is the one to use for terrain, cloud and
/// anything a person will look at directly.
class GradientNoise extends Noise {
  const GradientNoise({this.seed = 0});

  final int seed;

  @override
  double at(double x, [double y = 0, double z = 0]) {
    final xi = x.floor();
    final yi = y.floor();
    final zi = z.floor();
    final xd = x - xi;
    final yd = y - yi;
    final zd = z - zi;
    final u = _fade(xd);
    final v = _fade(yd);
    final w = _fade(zd);

    double corner(int dx, int dy, int dz) => _dot(
      _gradientAt(seed, xi + dx, yi + dy, zi + dz),
      xd - dx,
      yd - dy,
      zd - dz,
    );

    final x00 = _mix(corner(0, 0, 0), corner(1, 0, 0), u);
    final x10 = _mix(corner(0, 1, 0), corner(1, 1, 0), u);
    final x01 = _mix(corner(0, 0, 1), corner(1, 0, 1), u);
    final x11 = _mix(corner(0, 1, 1), corner(1, 1, 1), u);

    // The dot products run to about 0.866 at their widest, so this brings the
    // field back to the -1..1 the contract promises.
    return _mix(_mix(x00, x10, v), _mix(x01, x11, v), w) * 1.1547;
  }
}

/// Noise that joins up with itself.
///
/// For anything laid end to end: a texture that tiles, a world that wraps, a
/// loop of animation that has to close. Sampled at a point and again one
/// period away, it gives the same answer — worked out by wrapping the lattice
/// rather than by fading two copies together, which is the usual trick and
/// leaves a visible seam where the fade is strongest.
class TilingNoise extends Noise {
  const TilingNoise(this.inner, {this.period = 16});

  final Noise inner;

  /// How far apart the repeats are, in the same units the field is sampled
  /// in. Whole numbers only: the lattice is at whole coordinates and a period
  /// between two of them cannot line up with it.
  final int period;

  @override
  double at(double x, [double y = 0, double z = 0]) {
    final p = period <= 0 ? 1 : period;
    return inner.at(_wrap(x, p), _wrap(y, p), _wrap(z, p));
  }

  /// Brings a coordinate into the first period, keeping its fraction.
  static double _wrap(double value, int period) {
    final wrapped = value % period;
    return wrapped < 0 ? wrapped + period : wrapped;
  }
}

/// Several octaves of a field added together.
///
/// One octave is a smooth swell; six is a landscape. Each is twice the
/// frequency and a fraction of the amplitude of the one before, so the first
/// gives the shape and the rest give the detail — which is how a mountain
/// range and a pebble come out of the same function.
class FractalNoise extends Noise {
  const FractalNoise(
    this.inner, {
    this.octaves = 4,
    this.gain = 0.5,
    this.lacunarity = 2.0,
  });

  final Noise inner;

  /// How many times it is added. Past about eight the octaves are finer than
  /// anything being sampled and cost without showing.
  final int octaves;

  /// How much quieter each octave is than the one before.
  final double gain;

  /// How much finer each octave is.
  ///
  /// Two is the usual, and deliberately not exactly two in some fields —
  /// exactly two lines every octave's lattice up with the last one's, and the
  /// grid comes back.
  final double lacunarity;

  @override
  double at(double x, [double y = 0, double z = 0]) {
    var total = 0.0;
    var amplitude = 1.0;
    var frequency = 1.0;
    var most = 0.0;

    for (var i = 0; i < octaves; i++) {
      total +=
          inner.at(x * frequency, y * frequency, z * frequency) * amplitude;
      most += amplitude;
      amplitude *= gain;
      frequency *= lacunarity;
    }

    // Divided by what it could have reached rather than by the octave count,
    // so the field still runs to the edges of -1..1 whatever the gain is.
    return most == 0 ? 0 : total / most;
  }
}

/// The absolute value of a field, turned upside down.
///
/// Where a smooth field has a zero crossing this has a crease, and a fractal
/// built on it has ridges rather than swells — which is what a mountain range
/// looks like and what plain fractal noise never does.
class RidgedNoise extends Noise {
  const RidgedNoise(this.inner);

  final Noise inner;

  @override
  double at(double x, [double y = 0, double z = 0]) =>
      1 - 2 * inner.at(x, y, z).abs();
}

/// Distance to the nearest of a scattering of points.
///
/// Worley's field: cells with a point in each, and the value is how far the
/// sample is from the nearest one. Gives cracked mud, scales, stone, foam and
/// cell structure — the shapes that come from packing rather than from
/// smoothness, which no amount of adding octaves produces.
class CellNoise extends Noise {
  const CellNoise({this.seed = 0});

  final int seed;

  @override
  double at(double x, [double y = 0, double z = 0]) {
    final xi = x.floor();
    final yi = y.floor();
    final zi = z.floor();
    var nearest = double.infinity;

    // The twenty-six cells around this one and this one. A point in a further
    // cell cannot be nearer than one in a neighbour, so this is the whole
    // search rather than an approximation of it.
    for (var dz = -1; dz <= 1; dz++) {
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          final cx = xi + dx;
          final cy = yi + dy;
          final cz = zi + dz;
          final px = cx + _unitAt(seed, cx, cy, cz, 0);
          final py = cy + _unitAt(seed, cx, cy, cz, 1);
          final pz = cz + _unitAt(seed, cx, cy, cz, 2);
          final distance =
              (px - x) * (px - x) + (py - y) * (py - y) + (pz - z) * (pz - z);
          if (distance < nearest) nearest = distance;
        }
      }
    }

    // Nought at a point and rising away from it, brought into -1..1. The
    // furthest a sample can be from every point is under one cell, so this
    // does not need clamping in practice — but a caller that scaled the field
    // would notice, so it is clamped.
    final away = math.sqrt(nearest);
    return (away * 2 - 1).clamp(-1.0, 1.0);
  }
}

// ---------------------------------------------------------------------------

/// Smoothstep's bigger brother, with zero slope *and* zero curvature at both
/// ends.
///
/// The curvature is what matters: a field faded with plain smoothstep has a
/// discontinuity in its second derivative at every lattice point, which is
/// invisible in the field itself and glaringly visible in anything derived
/// from its slope — a normal map, a lighting response, a flow.
double _fade(double t) => t * t * t * (t * (t * 6 - 15) + 10);

double _mix(double a, double b, double t) => a + (b - a) * t;

double _dot(int gradient, double x, double y, double z) {
  // Twelve directions to the edge midpoints of a cube. Not the axes: axis
  // gradients line every extreme up with the lattice and put a visible cross
  // through the field.
  return switch (gradient % 12) {
    0 => x + y,
    1 => -x + y,
    2 => x - y,
    3 => -x - y,
    4 => x + z,
    5 => -x + z,
    6 => x - z,
    7 => -x - z,
    8 => y + z,
    9 => -y + z,
    10 => y - z,
    _ => -y - z,
  };
}

/// One lattice point to one number between -1 and 1, always the same one.
double _valueAt(int seed, int x, int y, int z) =>
    _unitAt(seed, x, y, z, 0) * 2 - 1;

int _gradientAt(int seed, int x, int y, int z) => _hash(seed, x, y, z, 7) % 12;

/// One lattice point and a channel to a number between 0 and 1.
double _unitAt(int seed, int x, int y, int z, int channel) =>
    (_hash(seed, x, y, z, channel) & 0xFFFFFF) / 0x1000000;

/// A hash of four integers.
///
/// Written out rather than taken from a library because it has to give the
/// same answer on every machine and for ever: a field that changed with the
/// Dart version would be a world that regenerated differently after an
/// upgrade. The constants are large odd primes, and the shifts mix the high
/// bits back down where the low bits can see them.
int _hash(int seed, int x, int y, int z, int channel) {
  var h = seed & 0x7FFFFFFF;
  h = (h * 374761393 + x * 668265263) & 0x7FFFFFFF;
  h = (h * 2246822519 + y * 3266489917) & 0x7FFFFFFF;
  h = (h * 668265263 + z * 374761393) & 0x7FFFFFFF;
  h = (h * 2654435761 + channel * 40503) & 0x7FFFFFFF;
  h ^= h >> 15;
  h = (h * 2246822519) & 0x7FFFFFFF;
  h ^= h >> 13;
  return h & 0x7FFFFFFF;
}
