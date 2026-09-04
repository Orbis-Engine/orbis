import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

/// Procedural handheld movement.
///
/// A camera that holds perfectly still reads as a tripod, which is correct for
/// a menu and wrong for almost everything else. This is the difference between
/// a shot that looks rendered and one that looks filmed.
///
/// Deterministic: the same time and seed always give the same offset, so a
/// replay, a recording and a test all agree.
class CameraNoise {
  CameraNoise({
    Vector3? positionAmplitude,
    Vector3? positionFrequency,
    Vector3? rotationAmplitude,
    Vector3? rotationFrequency,
    this.seed = 0,
  }) : positionAmplitude = positionAmplitude ?? Vector3(0.05, 0.05, 0.02),
       positionFrequency = positionFrequency ?? Vector3(0.4, 0.5, 0.3),
       rotationAmplitude = rotationAmplitude ?? Vector3(0.6, 0.6, 0.3),
       rotationFrequency = rotationFrequency ?? Vector3(0.5, 0.4, 0.2);

  /// Metres of sway, per axis.
  Vector3 positionAmplitude;

  /// Cycles per second, per axis.
  Vector3 positionFrequency;

  /// Degrees of wobble: pitch, yaw, roll.
  Vector3 rotationAmplitude;

  Vector3 rotationFrequency;

  /// Distinguishes one camera's shake from another's, so two cameras in the
  /// same scene do not sway in unison.
  int seed;

  /// How far the camera should be displaced at [time] seconds.
  Vector3 positionAt(double time) => Vector3(
    positionAmplitude.x * _wave(time * positionFrequency.x, seed + 1),
    positionAmplitude.y * _wave(time * positionFrequency.y, seed + 2),
    positionAmplitude.z * _wave(time * positionFrequency.z, seed + 3),
  );

  /// Pitch, yaw and roll in degrees at [time] seconds.
  Vector3 rotationAt(double time) => Vector3(
    rotationAmplitude.x * _wave(time * rotationFrequency.x, seed + 4),
    rotationAmplitude.y * _wave(time * rotationFrequency.y, seed + 5),
    rotationAmplitude.z * _wave(time * rotationFrequency.z, seed + 6),
  );

  /// Sines at ratios that never line up, so the result never visibly repeats.
  ///
  /// Cheaper than gradient noise and indistinguishable at these amplitudes —
  /// nobody has ever noticed the spectrum of a camera wobble.
  static double _wave(double t, int seed) {
    final phase = seed * 1.61803398875;
    return (math.sin((t + phase) * 2 * math.pi) * 0.55 +
            math.sin((t * 2.176 + phase) * 2 * math.pi) * 0.3 +
            math.sin((t * 4.813 + phase) * 2 * math.pi) * 0.15) /
        1.0;
  }
}
