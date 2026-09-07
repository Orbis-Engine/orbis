import 'dart:typed_data';

/// The light a place brings with it, and the backdrop it is seen against.
///
/// A photograph of somewhere real, turned into light. Everything in the scene
/// is then lit by that place — a chrome ball reflects the room it is standing
/// in, a matte surface picks up the colour of the wall beside it, and a
/// shadow is filled by the sky rather than by a number somebody guessed.
///
/// It is the single largest difference between a render that looks computed
/// and one that looks photographed, and it costs nothing per frame: the
/// lighting is baked into a cubemap once and sampled thereafter.
///
/// **Baked, not decoded here.** What this names is what Filament's own
/// `cmgen` writes out of an equirectangular HDR:
///
/// ```
/// cmgen --format=ktx --size=256 --deploy=out kitchen.hdr
/// ```
///
/// which produces `out/kitchen/kitchen_ibl.ktx` — a prefiltered radiance
/// cubemap with the spherical harmonics for the diffuse part written into its
/// metadata — and `out/kitchen/kitchen_skybox.ktx`, the backdrop.
///
/// Baking is not a limitation to be lifted later. Prefiltering a cubemap is
/// minutes of work per environment, it produces the same answer every time,
/// and doing it while somebody waits for a scene to open would be minutes
/// they spend watching a progress bar for a result that was already known.
class OrbisEnvironment {
  const OrbisEnvironment({
    this.radiance,
    this.skybox,
    this.intensity = 30000,
    this.rotation = 0,
    this.showSkybox = true,
  });

  /// Nothing: the scene is lit by its lights and its flat ambient alone.
  static const OrbisEnvironment none = OrbisEnvironment();

  /// An absolute path to the prefiltered radiance cubemap — `*_ibl.ktx`.
  ///
  /// Both halves of the lighting come out of this one file. The mip chain is
  /// the reflection, rough surfaces reading the blurrier levels; the
  /// spherical harmonics in its metadata are the diffuse. A file with no
  /// harmonics in it still lights reflections and leaves matte surfaces dark,
  /// which is what an unbaked cubemap looks like and is reported rather than
  /// guessed at.
  final String? radiance;

  /// An absolute path to the backdrop cubemap — `*_skybox.ktx`.
  ///
  /// Separate from [radiance] because they are different pictures at
  /// different sizes: the backdrop is what the camera sees and wants to be
  /// sharp, the radiance is what surfaces sample and is deliberately blurred.
  /// One without the other is legitimate — a backdrop that lights nothing, or
  /// light with no visible sky, which is what an interior lit through a window
  /// wants.
  final String? skybox;

  /// How bright the place is, in lux.
  ///
  /// The same unit everything else in the engine states light in, so a
  /// daylight environment and a directional sun can be set from the same
  /// meter reading rather than balanced by eye.
  final double intensity;

  /// How far the environment is turned about the vertical, in radians.
  ///
  /// What lets one bake serve a scene facing any direction: the sun in a
  /// photographed sky is wherever it was when the photograph was taken, and
  /// turning the environment is how it comes to be behind the camera instead.
  final double rotation;

  /// Whether the backdrop is drawn as well as sampled.
  ///
  /// Off is an environment that lights the scene and is never seen — an
  /// interior where the windows look out onto geometry, or a shot composited
  /// over something else later.
  final bool showSkybox;

  /// Whether there is anything here at all.
  bool get isSet =>
      (radiance != null && radiance!.isNotEmpty) ||
      (skybox != null && skybox!.isNotEmpty);

  OrbisEnvironment copyWith({
    String? radiance,
    String? skybox,
    double? intensity,
    double? rotation,
    bool? showSkybox,
  }) => OrbisEnvironment(
    radiance: radiance ?? this.radiance,
    skybox: skybox ?? this.skybox,
    intensity: intensity ?? this.intensity,
    rotation: rotation ?? this.rotation,
    showSkybox: showSkybox ?? this.showSkybox,
  );

  /// How many floats [packed] holds.
  static const int stride = 4;

  Float32List get packed =>
      Float32List.fromList([intensity, rotation, showSkybox ? 1 : 0, 0]);
}
