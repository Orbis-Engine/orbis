import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:orbis_weather/orbis_weather.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../example.dart';
import 'surface.dart' show linearOf;

/// Air with something in it.
///
/// Three separate things that read as one: an even haze for distance, banks
/// of cloud for shape, and a curtain of drops for what is coming down. The
/// first cannot look like anything in particular, the second cannot tell you
/// how far away something is, and the third is nothing without either.
class WeatherExample extends Example {
  WeatherExample();

  @override
  String get name => 'Weather';

  @override
  String get blurb =>
      'Haze, banks of cloud and falling weather, carried by one wind.';

  @override
  ViewPoint get viewpoint =>
      const ViewPoint(distance: 16, pitch: -0.06, height: 1.5);

  String condition = 'Fair';

  double density = 0.006;
  double structure = 0.05;
  double cloudSize = 50;
  double height = 0;
  double windSpeed = 4;
  double windBearing = 135;
  double rain = 0;
  double snow = 0;
  double cover = 0.38;
  double cloudAltitude = 900;
  String shape = 'Cumulus';
  double lightning = 0;
  SkyQuality quality = SkyQuality.fair;

  /// The shapes on offer, each a real one rather than a preset of the same
  /// one: they differ in how high the base sits, how deep the layer is, how
  /// large its lumps are, and how far the noise is folded.
  static final _shapes =
      <String, OrbisClouds Function({double cover, Vector2? wind})>{
        'Cumulus': OrbisClouds.cumulus,
        'Stratocumulus': OrbisClouds.stratocumulus,
        'Stratus': OrbisClouds.stratus,
        'Cirrus': OrbisClouds.cirrus,
        'Cumulonimbus': OrbisClouds.cumulonimbus,
      };

  // haze, mist, mist size, height, wind, rain, snow, cloud cover
  static const _presets = {
    'Clear': [0.004, 0.0, 40.0, 0.0, 1.5, 0.0, 0.0, 0.06],
    'Fair': [0.006, 0.05, 50.0, 0.0, 4.0, 0.0, 0.0, 0.38],
    'Storm': [0.07, 0.9, 45.0, 0.0, 12.0, 0.95, 0.0, 1.0],
    'Misty': [0.055, 0.75, 22.0, -1.5, 2.5, 0.0, 0.0, 0.45],
    'Rain': [0.035, 0.2, 70.0, 0.0, 5.0, 0.65, 0.0, 0.85],
    'Snow': [0.04, 0.25, 60.0, 0.0, 2.2, 0.0, 0.75, 0.8],
  };

  void _apply(String name) {
    final preset = _presets[name]!;
    condition = name;
    density = preset[0];
    structure = preset[1];
    cloudSize = preset[2];
    height = preset[3];
    windSpeed = preset[4];
    rain = preset[5];
    snow = preset[6];
    cover = preset[7];
    lightning = name == 'Storm' ? 0.85 : 0;
    if (name == 'Storm') {
      shape = 'Cumulonimbus';
      cloudAltitude = OrbisClouds.cumulonimbus().altitude;
    }
  }

  @override
  OrbisScene scene(OrbisCamera camera, double seconds) {
    final bearing = windBearing * math.pi / 180;
    final wind = Vector2(math.sin(bearing), math.cos(bearing)) * windSpeed;

    final falling = rain + snow;
    final asSnow = falling <= 0 ? 0.0 : (snow / falling).clamp(0.0, 1.0);
    double between(double wet, double white) => wet + (white - wet) * asSnow;

    final strike = Strike.at(seconds, lightning);

    return OrbisScene(
      objects: [
        for (var i = 0; i < 7; i++)
          OrbisObject(
            key: 400 + i,
            transform: Matrix4.identity()
              ..setTranslation(
                Vector3(
                  math.cos(i * 1.9) * (3 + i * 0.7),
                  -0.9 + (i % 3) * 0.4,
                  math.sin(i * 1.9) * (3 + i * 0.7),
                ),
              )
              ..rotateY(i * 0.6)
              ..scaleByDouble(0.8, 1.4 + (i % 3) * 0.7, 0.8, 1),
            colour: linearOf(
              i.isEven ? const Color(0xFF6E6A63) : const Color(0xFF8A8279),
            ),
          ),
        OrbisObject(
          key: 390,
          transform: Matrix4.identity()
            ..setTranslation(Vector3(0, -1.9, 0))
            ..scaleByDouble(40.0, 0.06, 40.0, 1),
          colour: linearOf(const Color(0xFF4A4E52)),
          castShadows: false,
        ),
      ],
      lights: [
        OrbisLight(
          key: 410,
          kind: OrbisLightKind.directional,
          // Dimmer than a clear day, because there is cloud in the way of it.
          intensity: 30000,
          direction: Vector3(-0.42, -0.36, -0.52)..normalize(),
          colour: linearOf(const Color(0xFFEFEFEA)),
          sunAngularRadius: 6,
        ),
      ],
      // The sky, the body in it and the cloud are one object because they
      // are one shader on one dome: the cloud covers the sun, the sun lights
      // the cloud, and a strike would light both.
      sky: OrbisSky(
        colour: linearOf(const Color(0xFF6E757D)),
        zenith: linearOf(const Color(0xFF3E6FA8)),
        horizon: linearOf(const Color(0xFFBCCBD8)),
        ambient: 22000,
        quality: quality,
        // The way the light comes from, which is the way the light goes, the
        // other way round.
        bodyDirection: Vector3(0.42, 0.36, 0.52)..normalize(),
        bodyColour: linearOf(const Color(0xFFFFF6E8)),
        bodySize: 0.011,
        // Worked out from the clock rather than rolled, so the same second
        // of the same storm strikes the same way twice.
        flash: strike.flash,
        flashDirection: strike.direction,
        flashSeed: strike.seed,
        // Cloud is a layer overhead rather than anything to do with the fog:
        // a scene can have either without the other.
        clouds: cover <= 0.01
            ? OrbisClouds.none
            : _shapes[shape]!(
                cover: cover,
                wind: wind,
              ).copyWith(altitude: cloudAltitude),
      ),
      fog: OrbisFog(
        colour: linearOf(const Color(0xFFD3D8DD)),
        density: density,
        height: height,
        heightFalloff: 0.4,
        // Above zero, the same air is also drawn as banks of cloud.
        structure: structure,
        wind: wind,
        // Turns of the noise per metre: the reciprocal of how big a cloud is.
        featureSize: 1 / math.max(cloudSize, 0.5),
        thickness: 6,
      ),
      precipitation: falling <= 0
          ? OrbisPrecipitation.none
          : OrbisPrecipitation(
              colour: linearOf(
                Color.lerp(
                  const Color(0xFFB8C6D6),
                  const Color(0xFFF2F5F8),
                  asSnow,
                )!,
              ),
              amount: falling.clamp(0.0, 1.0),
              // Nine metres a second for rain, under one for snow.
              fall: between(9, 0.8),
              // Snow is taken by the wind far more: it weighs nothing and it
              // has all day.
              wind: wind * between(0.6, 1.6),
              dropsPerMetre: between(8, 3.5),
              // How far a drop travels while the shutter is open. A streak,
              // or a flake.
              stretch: between(30, 5),
              threshold: between(0.7, 0.55),
            ),
      camera: camera,
    );
  }

  @override
  Widget settings(BuildContext context, VoidCallback changed) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Choice(
          label: 'Condition',
          options: _presets.keys.toList(),
          selected: condition,
          onSelect: (option) {
            _apply(option);
            changed();
          },
        ),
        Choice(
          label: 'Sky detail',
          options: const ['Lean', 'Fair', 'Full'],
          selected: switch (quality) {
            SkyQuality.lean => 'Lean',
            SkyQuality.fair => 'Fair',
            SkyQuality.full => 'Full',
          },
          onSelect: (option) {
            quality = switch (option) {
              'Lean' => SkyQuality.lean,
              'Fair' => SkyQuality.fair,
              _ => SkyQuality.full,
            };
            changed();
          },
        ),
        Setting(
          label: 'Lightning',
          value: lightning,
          min: 0,
          max: 1,
          onChanged: (value) {
            lightning = value;
            changed();
          },
        ),
        Setting(
          label: 'Cloud cover',
          value: cover,
          min: 0,
          max: 1,
          onChanged: (value) {
            cover = value;
            changed();
          },
        ),
        if (cover > 0.01)
          Choice(
            label: 'Cloud shape',
            options: _shapes.keys.toList(),
            selected: shape,
            onSelect: (option) {
              shape = option;
              cloudAltitude = _shapes[option]!().altitude;
              changed();
            },
          ),
        if (cover > 0.01)
          Setting(
            label: 'Cloud height',
            value: cloudAltitude,
            min: 40,
            max: 600,
            unit: ' m',
            decimals: 0,
            onChanged: (value) {
              cloudAltitude = value;
              changed();
            },
          ),
        Setting(
          label: 'Haze',
          value: density,
          min: 0,
          max: 0.2,
          decimals: 3,
          onChanged: (value) {
            density = value;
            changed();
          },
        ),
        Setting(
          label: 'Ground mist',
          value: structure,
          min: 0,
          max: 1,
          onChanged: (value) {
            structure = value;
            changed();
          },
        ),
        if (structure > 0)
          Setting(
            label: 'Mist size',
            value: cloudSize,
            min: 4,
            max: 120,
            unit: ' m',
            decimals: 0,
            onChanged: (value) {
              cloudSize = value;
              changed();
            },
          ),
        Setting(
          label: 'Height',
          value: height,
          min: -8,
          max: 8,
          unit: ' m',
          decimals: 1,
          onChanged: (value) {
            height = value;
            changed();
          },
        ),
        Setting(
          label: 'Rain',
          value: rain,
          min: 0,
          max: 1,
          onChanged: (value) {
            rain = value;
            changed();
          },
        ),
        Setting(
          label: 'Snow',
          value: snow,
          min: 0,
          max: 1,
          onChanged: (value) {
            snow = value;
            changed();
          },
        ),
        Setting(
          label: 'Wind',
          value: windSpeed,
          min: 0,
          max: 20,
          unit: ' m/s',
          decimals: 1,
          onChanged: (value) {
            windSpeed = value;
            changed();
          },
        ),
        Setting(
          label: 'Bearing',
          value: windBearing,
          min: 0,
          max: 360,
          unit: '°',
          decimals: 0,
          onChanged: (value) {
            windBearing = value;
            changed();
          },
        ),
      ],
    );
  }

  @override
  String get code => '''
// Haze for distance, banks for shape. One setting, because weather with no
// haze behind it reads as cut-outs hanging in clear air.
fog: OrbisFog(
  colour: Vector3(0.65, 0.69, 0.73),
  density: 0.055,           // per metre
  height: -1.5,             // where the layer lies
  heightFalloff: 0.4,       // how fast it thins going up
  structure: 0.75,          // above zero, banks of cloud are drawn as well
  wind: Vector2(1.8, -1.8), // metres a second, across the ground
  featureSize: 1 / 22,      // one over how big a cloud is, in metres
  thickness: 6,             // how deep the bank is
),

// Rain and snow are one curtain at different settings: what separates them is
// how far a drop travels while the shutter is open.
precipitation: OrbisPrecipitation(
  amount: 0.65,
  fall: 9,                  // metres a second; snow is under one
  wind: wind,
  dropsPerMetre: 6,
  stretch: 30,              // a streak. 1.2 is a flake.
),

// The renderer moves both on its own clock, so a still scene keeps raining
// without the host sending another frame.
''';
}
