import 'dart:math' as math;

import 'package:orbis_light/orbis_light.dart';
import 'package:vector_math/vector_math_64.dart';

/// What is lighting a scene from above.
///
/// One at a time, because a renderer draws one directional light and a sky has
/// one thing in it that everything else is lit by. A scene with a day cycle
/// switches at the horizon; a scene without one is told which.
enum CelestialBody {
  sun('Sun'),
  moon('Moon');

  const CelestialBody(this.label);

  /// What it is called, which is also what a light of this body is named while
  /// nobody has renamed it.
  final String label;
}

/// The sky at one moment: where the light comes from, what colour it is, and
/// what a camera has to do to see by it.
///
/// A record of one instant rather than a thing that ticks. The clock belongs
/// to the editor, the hour belongs to the scene, and this is the function
/// between them — which is what makes it something a test can pin down.
class SkyState {
  const SkyState({
    required this.body,
    required this.direction,
    required this.altitude,
    required this.lightColour,
    required this.power,
    required this.skyColour,
    required this.ambient,
    required this.exposure,
  });

  final CelestialBody body;

  /// The direction light travels: from the body towards the scene.
  final Vector3 direction;

  /// How high the body sits, in radians. Negative is below the horizon, which
  /// only the sun ever is — when it goes down the moon comes up.
  final double altitude;

  final Tint lightColour;

  /// Watts per square metre, the unit a sun's strength is stated in.
  final double power;

  final Tint skyColour;

  /// How much light the sky itself casts, in lux.
  final double ambient;

  /// What the camera has to be set to for any of this to be visible.
  final CameraExposure exposure;
}

/// A camera's three settings, which together decide how much light reaches it.
///
/// Needed because a day cycle spans about seventeen stops. Moonlight is a
/// quarter of a lux and midday is a hundred thousand: on one fixed exposure,
/// either the night is pure black or the day is pure white. Every camera and
/// every eye solves this by changing sensitivity, and so does this one.
class CameraExposure {
  const CameraExposure({
    required this.aperture,
    required this.shutterSpeed,
    required this.sensitivity,
  });

  /// Sunny sixteen: what a camera is set to outdoors at midday, and what
  /// Filament assumes when nobody says otherwise.
  static const CameraExposure daylight = CameraExposure(
    aperture: 16,
    shutterSpeed: 1 / 125,
    sensitivity: 100,
  );

  /// What a camera would be set to for a scene with this much light falling
  /// on it, in lux.
  ///
  /// Incident metering, the way a hand-held meter works: the light landing on
  /// the scene decides the exposure. This replaced two hand-tuned ramps — one
  /// for how bright the day was and one for how open the lens should be — and
  /// the reason is that they have to agree exactly, and when they did not the
  /// night came out pure white. A meter cannot disagree with itself.
  factory CameraExposure.forIlluminance(double lux) {
    // Puts sunny sixteen at EV 15, which is where a century of film boxes say
    // it goes.
    const double calibration = 250;
    final wanted = _log2(math.max(lux, 1e-5) * 100 / calibration);
    final light = math.pow(2, wanted).toDouble();

    // A photographer's own order: stop down while there is light to spare,
    // then open up, then hold the shutter open, and only then raise the
    // sensitivity — because grain is the price you pay last. Doing it in that
    // order is what keeps these numbers ones somebody would recognise.
    var aperture = math.sqrt(light * _defaultShutter);
    var shutter = _defaultShutter;
    var sensitivity = 100.0;

    if (aperture > _widestAperture) {
      // Brighter than the lens can stop down for: shorten the shutter.
      aperture = _widestAperture;
      shutter = (aperture * aperture / light).clamp(_fastestShutter, 1.0);
    } else if (aperture < _fastestAperture) {
      aperture = _fastestAperture;
      shutter = aperture * aperture / light;
      if (shutter > _slowestShutter) {
        // Wide open and as slow as anybody would hand-hold. What is left goes
        // into the sensor.
        shutter = _slowestShutter;
        sensitivity = (100 * aperture * aperture / (shutter * light)).clamp(
          50,
          25600,
        );
      }
    }

    return CameraExposure(
      aperture: aperture,
      shutterSpeed: shutter,
      sensitivity: sensitivity,
    );
  }

  static const double _defaultShutter = 1 / 125;
  static const double _slowestShutter = 1 / 30;
  static const double _fastestShutter = 1 / 4000;
  static const double _fastestAperture = 1.4;
  static const double _widestAperture = 22;

  static double _log2(double value) => math.log(value) / math.ln2;

  /// F-number.
  final double aperture;

  /// Seconds.
  final double shutterSpeed;

  /// ISO.
  final double sensitivity;

  /// The exposure value these three add up to, at ISO 100.
  ///
  /// One number for what three describe, which is what makes two different
  /// settings comparable — and what a test can hold to account.
  double get ev100 =>
      _log2(aperture * aperture / shutterSpeed) - _log2(sensitivity / 100);
}

/// Where the sun and moon are through a day, and what that does to everything.
///
/// Not an ephemeris. A real one needs a date, a latitude and a longitude, and
/// it would buy a scene nothing that this does not: an arc that rises, crosses
/// and sets, with the light going warm at both ends. What matters here is that
/// it is smooth, that it repeats, and that midnight and midday are opposite.
abstract final class DayCycle {
  /// How high the sun climbs at noon. Sixty-five degrees is a summer's day at
  /// a temperate latitude — high enough for short shadows, low enough that
  /// they still point somewhere.
  static const double peakAltitude = 65 * math.pi / 180;

  /// Direct sun at noon, in watts per square metre, as the light package takes
  /// it. About seventy-five thousand lux.
  static const double noonPower = 110;

  /// Moonlight, in the same unit — about a lux.
  ///
  /// Brighter than the real thing, which is a quarter of a lux and looks like
  /// almost nothing. Every night scene ever filmed is lit well above what the
  /// moon actually gives, for the same reason: a night has to be dark and
  /// legible at once, and the real number is only the first of those.
  static const double moonPower = 0.0015;

  /// What the sun is down to as it touches the horizon.
  ///
  /// The moon's, exactly. The two swap at that moment, and if the light they
  /// give did not match there the scene would step brighter or darker in a
  /// single frame — a flicker at every dawn and every dusk.
  static const double twilightPower = moonPower;

  /// How much of what the body gives comes back off the sky.
  ///
  /// A third, roughly, which is what a clear day measures: seventy-five
  /// thousand lux of sun and twenty-eight of sky. Tying the two together
  /// rather than authoring them apart is what keeps the shadows the right
  /// depth at every hour instead of only at noon.
  static const double skyShare = 0.35;

  /// Starlight, in lux, so a night is dark rather than a hole.
  static const double starlight = 0.2;

  /// The sky at [hour], which runs from zero to twenty-four and wraps.
  static SkyState at(double hour) {
    final time = hour % 24;

    // Zero at six in the morning, pi at six in the evening, so the sun is up
    // for exactly half of it and highest at noon.
    final swing = math.sin((time - 6) / 12 * math.pi);
    final sunAltitude = swing * peakAltitude;

    // Turns once a day, so it rises on one side and sets on the other rather
    // than going back the way it came.
    final azimuth = (time / 24) * 2 * math.pi;

    final isDay = sunAltitude > 0;
    final body = isDay ? CelestialBody.sun : CelestialBody.moon;

    // The moon is opposite the sun. Not true of the real one, which is why it
    // has phases — but a moon that is up all night is the one a scene wants.
    final altitude = isDay ? sunAltitude : -sunAltitude;
    final facing = isDay ? azimuth : azimuth + math.pi;

    final toBody = Vector3(
      math.cos(altitude) * math.sin(facing),
      math.sin(altitude),
      math.cos(altitude) * math.cos(facing),
    );

    // Low sun is red because its light has come a long way through the air.
    // The same reason the sky is blue, seen from the other end.
    final horizon = _smooth(swing.clamp(0.0, 1.0) / 0.18);

    // Full strength at noon, down to the moon's own by the time it reaches
    // the horizon — so the handover is a change of direction rather than a
    // change of how much light there is.
    final power = isDay
        ? twilightPower + (noonPower - twilightPower) * swing * swing
        : moonPower;
    final bodyLux = Photometry.irradianceToLux(power);
    final ambient = math.max(starlight, skyShare * bodyLux);

    return SkyState(
      body: body,
      // Light travels from the body to the scene, which is the way the body
      // is not.
      direction: -toBody
        ..normalize(),
      altitude: altitude,
      lightColour: isDay ? Tint.lerp(_lowSun, _highSun, horizon) : _moonlight,
      power: power,
      skyColour: _skyAt(swing),
      ambient: ambient,
      // Metered off what is actually falling on the scene: the body, angled
      // by how high it is, plus the sky. Anything from a moonlit field to a
      // noon desert then lands in the middle of the range rather than at one
      // end of it.
      exposure: CameraExposure.forIlluminance(
        bodyLux * math.max(0, math.sin(altitude)) + ambient,
      ),
    );
  }

  /// The sky's own colour through the day.
  ///
  /// Four stops rather than a formula: night, the minute before dawn, an hour
  /// after it, and midday. A gradient between three of them looks like a
  /// filter being turned; the dawn stop is what makes it read as a sunrise.
  static Tint _skyAt(double swing) {
    if (swing <= 0) {
      // Below the horizon, deepening for the first part of the night.
      return Tint.lerp(_duskSky, _nightSky, _smooth(-swing / 0.25));
    }
    if (swing < 0.18) return Tint.lerp(_duskSky, _dawnSky, swing / 0.18);
    return Tint.lerp(_dawnSky, _daySky, _smooth((swing - 0.18) / 0.5));
  }

  /// Smoothstep, clamped. Turns a straight ramp into one that eases out of
  /// both ends, which is the difference between a sunrise and a switch.
  static double _smooth(double t) {
    final x = t.clamp(0.0, 1.0);
    return x * x * (3 - 2 * x);
  }

  static const Tint _lowSun = Tint.hex(0xFF8A3D);
  static const Tint _highSun = Tint.hex(0xFFF4E5);
  static const Tint _moonlight = Tint.hex(0xC3D4FF);

  static const Tint _nightSky = Tint.hex(0x05070F);
  static const Tint _duskSky = Tint.hex(0x2A2438);
  static const Tint _dawnSky = Tint.hex(0x7A5A63);
  static const Tint _daySky = Tint.hex(0x6E96C8);
}
