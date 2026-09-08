import 'dart:math' as math;

import 'package:orbis_light/orbis_light.dart';

import 'strike.dart';

/// The kinds of weather a scene can be put into.
///
/// Named states rather than a pile of sliders, because that is how anybody
/// thinks about weather: somebody wants an overcast afternoon, not a cloud
/// cover of 0.9 and a fog density of 0.03. The sliders are still there
/// underneath — a condition is a place to start from, not a cage.
enum WeatherCondition {
  clear('Clear'),
  fair('Fair'),
  hazy('Hazy'),
  misty('Misty'),
  overcast('Overcast'),
  rain('Rain'),
  storm('Storm'),
  snow('Snow');

  const WeatherCondition(this.label);

  final String label;
}

/// The shapes a sky's cloud can take.
///
/// A separate choice from the weather, because the same conditions produce
/// very different skies and a scene should be able to say which it wants. A
/// fair afternoon can be cauliflower cumulus with blue between them or one
/// flat sheet of stratocumulus, and those are not the same picture at all.
///
/// Each is a real shape rather than a preset of the same shape: they differ in
/// how high the base sits, how deep the layer is, how large its lumps are and
/// how far the noise is folded, and folding is what separates a cauliflower
/// from a sheet.
enum CloudKind {
  none('None'),

  /// Flat bases at the condensation level, cauliflower tops, blue between.
  cumulus('Cumulus'),

  /// The lumps run together into a layer with breaks in it.
  stratocumulus('Stratocumulus'),

  /// The grey lid: low, shallow, and with almost no shape to it.
  stratus('Stratus'),

  /// Ice seven kilometres up, drawn into streaks by a wind nothing slows.
  cirrus('Cirrus'),

  /// Deep enough that its own base is in its own shadow.
  cumulonimbus('Cumulonimbus');

  const CloudKind(this.label);

  final String label;

  /// What a condition puts in the sky when nobody has said otherwise.
  static CloudKind forCondition(WeatherCondition condition) =>
      switch (condition) {
        WeatherCondition.clear => CloudKind.none,
        WeatherCondition.fair => CloudKind.cumulus,
        WeatherCondition.hazy => CloudKind.cirrus,
        WeatherCondition.misty => CloudKind.stratus,
        WeatherCondition.overcast => CloudKind.stratocumulus,
        WeatherCondition.rain => CloudKind.stratus,
        WeatherCondition.storm => CloudKind.cumulonimbus,
        WeatherCondition.snow => CloudKind.stratus,
      };
}

/// What the air is doing.
///
/// One value class for the whole of it, so a change of weather is one thing
/// that can be interpolated rather than eight that have to be kept in step.
/// That is the entire reason this is not a handful of fields on the scene:
/// weather is a thing that *changes*, and a change needs both ends of it in
/// one place.
class WeatherState {
  const WeatherState({
    required this.cloudCover,
    required this.fogColour,
    required this.fogDensity,
    required this.fogHeight,
    required this.fogFalloff,
    required this.mist,
    required this.mistSize,
    required this.windSpeed,
    this.rain = 0,
    this.snow = 0,
    this.lightning = 0,
    this.cloudHeight = 900,
  });

  /// How much of the sky is covered, from nothing to everything.
  ///
  /// The setting with the longest reach. Cloud takes the strength out of
  /// whatever is above the scene, spreads it across the sky instead, and
  /// widens the source until the shadows go soft and then disappear — which
  /// is what an overcast day actually is.
  final double cloudCover;

  final Tint fogColour;

  /// How thick the air is, per metre.
  final double fogDensity;

  /// Where the layer sits, and how quickly it thins going up.
  final double fogHeight;
  final double fogFalloff;

  /// How much shape the air has, and how large that shape is in metres.
  final double mist;
  final double mistSize;

  /// Metres a second.
  final double windSpeed;

  /// How much is coming down, from nothing to a downpour.
  ///
  /// Two amounts rather than a kind and an amount, so a change from rain to
  /// snow is one crossing the other rather than a switch — which is what
  /// happens on the day, at the temperature where both are falling at once.
  final double rain;
  final double snow;

  /// How often it strikes, from never to every few seconds.
  final double lightning;

  /// How high the cloud hangs, in metres.
  ///
  /// Low cloud is weather sitting on top of you and high cloud is a ceiling a
  /// long way off; the same cover at two heights is two different days.
  final double cloudHeight;

  /// Whether anything is falling.
  bool get isWet => rain + snow > 0;

  /// The same weather with one thing about it changed.
  WeatherState copyWith({
    double? cloudCover,
    Tint? fogColour,
    double? fogDensity,
    double? fogHeight,
    double? fogFalloff,
    double? mist,
    double? mistSize,
    double? windSpeed,
    double? rain,
    double? snow,
    double? lightning,
    double? cloudHeight,
  }) => WeatherState(
    cloudCover: cloudCover ?? this.cloudCover,
    fogColour: fogColour ?? this.fogColour,
    fogDensity: fogDensity ?? this.fogDensity,
    fogHeight: fogHeight ?? this.fogHeight,
    fogFalloff: fogFalloff ?? this.fogFalloff,
    mist: mist ?? this.mist,
    mistSize: mistSize ?? this.mistSize,
    windSpeed: windSpeed ?? this.windSpeed,
    rain: rain ?? this.rain,
    snow: snow ?? this.snow,
    lightning: lightning ?? this.lightning,
    cloudHeight: cloudHeight ?? this.cloudHeight,
  );

  /// What each condition is made of.
  ///
  /// Tuned as a set rather than one at a time: fog that is thick without
  /// being white reads as dirt on the lens, and cloud cover with no haze
  /// under it reads as a sky that has nothing to do with the ground.
  static const Map<WeatherCondition, WeatherState> presets = {
    WeatherCondition.clear: WeatherState(
      // None at all. A wisp of cover was in here as a nicety, and now that
      // cover draws something it made a clear sky one with cloud in it.
      cloudCover: 0,
      fogColour: Tint.hex(0xAFC2D6),
      fogDensity: 0.004,
      fogHeight: 0,
      fogFalloff: 0.15,
      mist: 0,
      mistSize: 40,
      windSpeed: 1.5,
    ),
    WeatherCondition.fair: WeatherState(
      cloudCover: 0.25,
      fogColour: Tint.hex(0xB6C4D2),
      fogDensity: 0.008,
      fogHeight: 0,
      fogFalloff: 0.2,
      mist: 0.15,
      mistSize: 55,
      windSpeed: 2.5,
      // Where fair-weather cumulus condense on a summer afternoon. It is the
      // one height everybody has seen and nobody has measured.
      cloudHeight: 900,
    ),
    WeatherCondition.hazy: WeatherState(
      cloudCover: 0.35,
      fogColour: Tint.hex(0xC8CDD3),
      fogDensity: 0.022,
      fogHeight: 1,
      fogFalloff: 0.12,
      mist: 0.3,
      mistSize: 70,
      windSpeed: 2,
      // Cirrus is ice, and ice needs the cold at seven kilometres.
      cloudHeight: 7000,
    ),
    WeatherCondition.misty: WeatherState(
      cloudCover: 0.55,
      fogColour: Tint.hex(0xDCE0E4),
      fogDensity: 0.055,
      // Below the ground the scene stands on, so the bank lies in the low
      // places and the tops of things come out of it.
      fogHeight: -1.5,
      fogFalloff: 0.4,
      mist: 0.75,
      mistSize: 22,
      windSpeed: 1.2,
      // Low, because a misty morning is cloud that has come down to the
      // ground rather than a ceiling a long way off.
      cloudHeight: 320,
    ),
    WeatherCondition.overcast: WeatherState(
      cloudCover: 0.92,
      fogColour: Tint.hex(0xA8AEB6),
      fogDensity: 0.03,
      fogHeight: 0,
      fogFalloff: 0.1,
      mist: 0.4,
      mistSize: 90,
      windSpeed: 4,
      cloudHeight: 700,
    ),
    WeatherCondition.rain: WeatherState(
      cloudCover: 0.85,
      fogColour: Tint.hex(0x9AA4AE),
      fogDensity: 0.035,
      fogHeight: 0,
      fogFalloff: 0.12,
      mist: 0.35,
      mistSize: 70,
      windSpeed: 5,
      rain: 0.65,
      cloudHeight: 450,
    ),
    WeatherCondition.storm: WeatherState(
      cloudCover: 1,
      fogColour: Tint.hex(0x7C838C),
      fogDensity: 0.07,
      fogHeight: 0,
      fogFalloff: 0.14,
      mist: 0.9,
      mistSize: 45,
      windSpeed: 12,
      rain: 0.95,
      lightning: 0.6,
      // The base of a thunderhead is low and the top of it is five kilometres
      // higher. What makes a storm sky dark is its depth, not its height.
      cloudHeight: 600,
    ),
    WeatherCondition.snow: WeatherState(
      cloudCover: 0.82,
      fogColour: Tint.hex(0xD3D8DD),
      fogDensity: 0.04,
      fogHeight: 0,
      fogFalloff: 0.1,
      mist: 0.4,
      mistSize: 60,
      cloudHeight: 500,
      // Snow falls in still air more often than not, and wind is what turns
      // it from weather into a problem.
      windSpeed: 2.2,
      snow: 0.75,
    ),
  };

  static WeatherState of(WeatherCondition condition) =>
      presets[condition] ?? presets[WeatherCondition.clear]!;

  /// Part of the way from one weather to another.
  ///
  /// Straight lines through every value. Weather has no business easing: air
  /// thickens at whatever rate it thickens, and a curve here would only be a
  /// curve somebody has to undo when they want the plain one.
  static WeatherState lerp(WeatherState from, WeatherState to, double t) {
    final at = t.clamp(0.0, 1.0);
    double mix(double a, double b) => a + (b - a) * at;

    return WeatherState(
      cloudCover: mix(from.cloudCover, to.cloudCover),
      fogColour: Tint.lerp(from.fogColour, to.fogColour, at),
      fogDensity: mix(from.fogDensity, to.fogDensity),
      fogHeight: mix(from.fogHeight, to.fogHeight),
      fogFalloff: mix(from.fogFalloff, to.fogFalloff),
      mist: mix(from.mist, to.mist),
      mistSize: mix(from.mistSize, to.mistSize),
      windSpeed: mix(from.windSpeed, to.windSpeed),
      rain: mix(from.rain, to.rain),
      snow: mix(from.snow, to.snow),
      lightning: mix(from.lightning, to.lightning),
      cloudHeight: mix(from.cloudHeight, to.cloudHeight),
    );
  }

  /// How bright a flash of lightning is this instant, from nothing to one.
  ///
  /// The strike itself lives in the engine, because when it happens and where
  /// it stands are the same facts the sky needs to draw the bolt — and two
  /// implementations of that would be two storms.
  static double flashAt(double clock, double frequency) =>
      Strike.at(clock, frequency).flash;

  /// The whole strike: how bright, which way, and what shape.
  static Strike strikeAt(double clock, double frequency) =>
      Strike.at(clock, frequency);

  /// How much of what is above the scene still reaches it.
  ///
  /// Cloud does not switch the sun off. A heavy overcast still passes a good
  /// tenth of the light, which is why a rainy afternoon is grey rather than
  /// dark — the meter opens up and the world stays legible.
  double get transmitted => 1 - 0.88 * cloudCover;

  /// How much wider the source becomes, as a multiplier on its angle.
  ///
  /// This is the whole difference between a bright day and a dull one: the
  /// sun is a disc a half-degree across, and cloud turns it into a source the
  /// size of the sky. Shadows lose their edges long before they lose their
  /// darkness.
  double get spread => 1 + cloudCover * cloudCover * 60;

  /// How much more of the light arrives from everywhere rather than from one
  /// direction. A covered sky is one enormous diffuser.
  double get scattered => 1 + cloudCover * 2.5;

  /// How far towards a flat grey the light and the sky are dragged.
  double get greying => cloudCover * 0.7;

  /// Which way the wind is blowing, as a direction on the ground.
  static ({double x, double z}) windFrom(double degrees) {
    final radians = degrees * math.pi / 180;
    return (x: math.sin(radians), z: math.cos(radians));
  }
}
