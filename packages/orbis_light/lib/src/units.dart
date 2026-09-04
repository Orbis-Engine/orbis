import 'dart:math' as math;

/// Converting between how a light is stated and how it is rendered.
///
/// An artist states a light in watts, because that is what the tool they came
/// from states it in and what a real fixture is labelled with. A renderer works
/// in lumens and lux, because those describe what the eye receives rather than
/// what the source emits. The two differ by how efficiently radiant power
/// becomes visible light, and getting that conversion wrong is why imported
/// scenes so often arrive blown out or black.
abstract final class Photometry {
  /// Lumens per watt at the wavelength the eye is most sensitive to, 555 nm.
  ///
  /// The maximum possible luminous efficacy of radiation. Using the peak means
  /// a watt is treated as if every photon were perfectly visible, which is the
  /// same simplification Blender's own glTF export makes — so a scene round
  /// trips at the brightness it was authored with rather than at a physically
  /// truer one nobody asked for.
  static const double luminousEfficacy = 683.0;

  /// Radiant power in watts to luminous power in lumens.
  ///
  /// For a point or spot light, which emit into the whole sphere. The
  /// steradians cancel: intensity is watts over four pi steradians, and
  /// luminous power is that intensity back over the same sphere.
  static double wattsToLumens(double watts) => watts * luminousEfficacy;

  /// Irradiance in watts per square metre to illuminance in lux.
  ///
  /// For a sun, whose rays are parallel and whose strength is stated per unit
  /// area rather than in total.
  static double irradianceToLux(double irradiance) =>
      irradiance * luminousEfficacy;

  /// Luminous power to intensity, for a source radiating in every direction.
  static double lumensToCandela(double lumens) => lumens / (4 * math.pi);

  /// Intensity back to luminous power.
  static double candelaToLumens(double candela) => candela * 4 * math.pi;

  /// How far light of a given power falls to a threshold.
  ///
  /// Light never actually reaches zero — it falls off with the square of
  /// distance forever — so a renderer needs a distance to stop caring at, or
  /// every light would have to be considered for every surface. This is that
  /// distance for a chosen cutoff.
  static double influenceRadius(double lumens, {double cutoffLux = 0.1}) {
    if (lumens <= 0 || cutoffLux <= 0) return 0;
    return math.sqrt(lumensToCandela(lumens) / cutoffLux);
  }
}
