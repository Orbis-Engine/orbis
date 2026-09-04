import 'dart:math' as math;

/// How much of the way to a target one frame should travel.
///
/// Damping is stated in seconds — roughly how long the camera takes to close
/// most of a gap — rather than as a per-frame factor. A per-frame factor is
/// framerate-dependent: the same value gives a different feel at 30 and 120
/// frames per second, and a camera that drifts when the machine is busy is a
/// bug nobody can reproduce.
///
/// The exponential form here settles the same way at any timestep.
double dampingFactor(double damping, double delta) {
  if (damping <= 0) return 1;
  if (delta <= 0) return 0;
  return 1 - math.exp(-delta / damping);
}

/// Moves [current] towards [target] with [damping] seconds of lag.
double damp(double current, double target, double damping, double delta) =>
    current + (target - current) * dampingFactor(damping, delta);
