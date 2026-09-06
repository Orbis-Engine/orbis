import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

/// A strike of lightning: how bright it is this instant, where it is, and
/// which strike it is.
///
/// Worked out from the clock rather than rolled. The same second of the same
/// storm looks the same twice, which is what lets a scene be reopened, a frame
/// be compared, and a test hold any of it to account — none of which a random
/// number generator allows.
///
/// A strike is three things and not one, because a flash with no place is a
/// lamp being switched: the sky needs to know where the bolt is to draw it,
/// and the bolt needs a seed of its own so that one strike is a different
/// shape from the next.
class Strike {
  const Strike({
    required this.flash,
    required this.direction,
    required this.seed,
  });

  /// Nothing happening.
  static final Strike none = Strike(
    flash: 0,
    direction: Vector3(0, 0.35, 1),
    seed: 0,
  );

  /// The strike at [clock] seconds, for a storm striking at [frequency].
  ///
  /// Frequency is a rate rather than a period: zero is a dry storm and one is
  /// close to continuous. Strikes land at most once in a window and not every
  /// window has one, because a storm that struck on the beat would be a
  /// metronome.
  factory Strike.at(double clock, double frequency) {
    if (frequency <= 0 || clock < 0) return none;

    final window = 14 / (0.2 + frequency * 3);
    final index = (clock / window).floor();
    final into = clock - index * window;

    // Not every window has a strike in it.
    if (_scatter(index) > 0.3 + frequency * 0.65) {
      return Strike(flash: 0, direction: _placeOf(index), seed: _seedOf(index));
    }

    final at = _scatter(index * 7 + 3) * math.max(window - 0.8, 0.1);
    final since = into - at;

    // Each is a stroke and then a weaker one a moment behind it, which is
    // what makes it read as lightning rather than as a lamp being switched.
    final stroke = since < 0
        ? 0.0
        : math.exp(-since * 14) +
            (since > 0.18 ? 0.45 * math.exp(-(since - 0.18) * 10) : 0);

    return Strike(
      flash: (stroke * (0.6 + 0.4 * _scatter(index * 13 + 5))).clamp(0.0, 1.0),
      direction: _placeOf(index),
      seed: _seedOf(index),
    );
  }

  /// How bright the sky is this instant, from nothing to one.
  final double flash;

  /// Which way the strike is. Scattered around the sky rather than always
  /// ahead, so a storm is something happening around the scene instead of a
  /// light on a stand.
  final Vector3 direction;

  /// What the bolt's shape is drawn from.
  final double seed;

  /// Where a strike stands, from its index alone.
  static Vector3 _placeOf(int index) {
    final bearing = _scatter(index * 17 + 11) * 2 * math.pi;
    final height = 0.12 + _scatter(index * 23 + 4) * 0.34;
    return Vector3(
      math.cos(height) * math.sin(bearing),
      math.sin(height),
      math.cos(height) * math.cos(bearing),
    );
  }

  static double _seedOf(int index) => _scatter(index * 31 + 7) * 100;

  /// A number between zero and one that is always the same for the same
  /// input. Not a good random source and a perfectly good one for weather.
  static double _scatter(int step) {
    final value = math.sin(step * 12.9898) * 43758.5453;
    return value - value.floorToDouble();
  }
}
