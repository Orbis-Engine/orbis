import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import 'environment.dart';
import 'post.dart';
import 'scene.dart';

/// The shape a volume occupies.
enum OrbisVolumeShape {
  /// A box, turned however it needs to be to line up with the room it stands
  /// for. Rooms, halls and corridors are boxes, and a sphere fitted round one
  /// either leaks out of the doorway or misses the corners.
  box,

  /// A ball. For the places that have no walls to line up with — a clearing,
  /// the glow round a fire, a pool of cold air at the bottom of a cave.
  sphere,
}

/// What a volume changes about the look of the scene, and nothing else.
///
/// Every field is optional, and null means *leave it alone*. That is the whole
/// design: a hall that only wants to be foggier says so and nothing more, and
/// the sunset the day cycle is writing into the sky's colour carries on
/// underneath it untouched. A volume that had to state every setting would
/// freeze everything it did not mean to, which is exactly the bug that makes
/// a time of day stop at a doorway.
///
/// Only settings the scene can already express are here. Each one is a field
/// of [OrbisFog], [OrbisSky], [OrbisEnvironment], [OrbisPostProcess] or the
/// camera, so a resolved volume is an ordinary scene and the renderer never
/// learns volumes exist.
class OrbisEnvironmentOverrides {
  const OrbisEnvironmentOverrides({
    this.fogDensity,
    this.fogColour,
    this.fogHeight,
    this.fogHeightFalloff,
    this.fogStart,
    this.fogMaximumOpacity,
    this.exposureCompensation,
    this.ambient,
    this.skyColour,
    this.environmentIntensity,
    this.environmentRotation,
    this.bloomStrength,
    this.saturation,
    this.contrast,
    this.temperature,
    this.tint,
    this.midtones,
  });

  /// [OrbisFog.density], per metre.
  final double? fogDensity;

  /// [OrbisFog.colour], linear RGB.
  final Vector3? fogColour;

  /// [OrbisFog.height] and [OrbisFog.heightFalloff].
  final double? fogHeight;
  final double? fogHeightFalloff;

  /// [OrbisFog.distance]: how far in front of the camera the fog begins.
  final double? fogStart;

  /// [OrbisFog.maximumOpacity].
  final double? fogMaximumOpacity;

  /// Stops of exposure added to the camera's own, so minus one is half the
  /// light reaching the sensor.
  ///
  /// Compensation rather than a setting, because the camera's aperture,
  /// shutter and sensitivity already say how it is set and a volume that
  /// replaced them would throw away whatever the host had chosen. Applied to
  /// the shutter, which is the one of the three that has no other visible
  /// effect in this renderer.
  final double? exposureCompensation;

  /// [OrbisSky.ambient]: how much light the sky casts, in lux.
  ///
  /// The single most useful override indoors. The flat ambient comes from
  /// every direction equally and nothing occludes it, so without this a room
  /// with a roof on it is lit exactly as brightly as the courtyard outside.
  /// Ignored by the renderer while an [OrbisEnvironment] is lighting the
  /// scene, as the sky's ambient always is — use [environmentIntensity] then.
  final double? ambient;

  /// [OrbisSky.colour]: the colour the ambient light is.
  final Vector3? skyColour;

  /// [OrbisEnvironment.intensity], in lux.
  final double? environmentIntensity;

  /// [OrbisEnvironment.rotation], in radians about the vertical.
  final double? environmentRotation;

  /// [OrbisBloom.strength]. Turns bloom on if the scene had it off, rising
  /// from nothing, so a volume can make its lamps glow without the courtyard
  /// outside starting to.
  final double? bloomStrength;

  /// The grade: [OrbisGrading.saturation], [OrbisGrading.contrast], the two
  /// white balance axes [OrbisGrading.temperature] and [OrbisGrading.tint],
  /// and [OrbisGrading.midtones] as a colour the middle of the image is
  /// multiplied by.
  ///
  /// Turns the grading on if the scene had it off, starting from neutral, so
  /// the grade outside is the ungraded picture and not whatever numbers a
  /// switched-off grading happened to be holding.
  final double? saturation;
  final double? contrast;
  final double? temperature;
  final double? tint;
  final Vector3? midtones;
}

/// A region of the world that looks different from the rest of it.
///
/// Step out of a sunny courtyard into a hall and the light should drop, the
/// air thicken and the colour warm — and it should do that as the camera goes
/// through the door, not at some line on the floor. A volume is where that
/// region is, how softly its edge is drawn, and what it changes.
///
/// Full strength inside the shape, fading to nothing across [blendDistance]
/// outside it. The fade is measured from the surface outwards, so the whole
/// of the room is the room: a volume that began fading at its own walls would
/// make every corner of it slightly less itself than the middle.
///
/// Resolved on this side of the channel, against the camera, before the scene
/// is sent. The renderer is told a fog and a sky and an exposure as it always
/// was, which is why a volume costs nothing on a platform that has never
/// heard of one.
class OrbisEnvironmentVolume {
  /// A box [halfExtents] from its [centre] along each of its own axes, turned
  /// by [rotation].
  OrbisEnvironmentVolume.box({
    required this.key,
    required this.centre,
    required Vector3 halfExtents,
    Quaternion? rotation,
    this.blendDistance = 1,
    this.priority = 0,
    this.weight = 1,
    required this.overrides,
  }) : shape = OrbisVolumeShape.box,
       halfExtents = halfExtents.clone(),
       radius = 0,
       rotation = (rotation ?? Quaternion.identity()).normalized();

  /// A ball of [radius] round [centre].
  OrbisEnvironmentVolume.sphere({
    required this.key,
    required this.centre,
    required this.radius,
    this.blendDistance = 1,
    this.priority = 0,
    this.weight = 1,
    required this.overrides,
  }) : shape = OrbisVolumeShape.sphere,
       halfExtents = Vector3.zero(),
       rotation = Quaternion.identity();

  /// This volume's identity. Also what breaks a tie between two volumes of
  /// the same [priority], so the order they are listed in never matters.
  final int key;

  final OrbisVolumeShape shape;

  /// The middle of the shape, in world space.
  final Vector3 centre;

  /// For a box: half its size along each of its own axes, in metres.
  final Vector3 halfExtents;

  /// For a box: which way it is turned.
  final Quaternion rotation;

  /// For a sphere: its radius, in metres.
  final double radius;

  /// How far outside the shape its influence reaches, in metres.
  ///
  /// Zero is a hard edge, which is right for a portal and wrong for nearly
  /// everything else: the look jumps in a single frame and the eye reads it
  /// as a cut. A doorway's width or so is where a hall starts to feel like a
  /// hall.
  final double blendDistance;

  /// Which volume wins where two overlap: higher is applied later, on top.
  ///
  /// A cave inside a mountain inside a valley is three volumes, and the
  /// innermost wants the last word without the others having to know it is
  /// there.
  final int priority;

  /// How much of the volume counts at full strength, from nothing to all of
  /// it. What lets a host fade a whole volume in and out — a storm arriving —
  /// without moving it.
  final double weight;

  /// What it changes.
  final OrbisEnvironmentOverrides overrides;

  /// How far [point] is outside the shape, in metres; zero anywhere inside.
  double distanceTo(Vector3 point) {
    final offset = point - centre;
    switch (shape) {
      case OrbisVolumeShape.sphere:
        return math.max(0, offset.length - radius);
      case OrbisVolumeShape.box:
        // Into the box's own frame, where it is axis-aligned. The conjugate
        // is the inverse for a unit quaternion, and this one was normalised
        // when it was made.
        final local = rotation.conjugated().rotated(offset);
        final dx = math.max(0.0, local.x.abs() - halfExtents.x);
        final dy = math.max(0.0, local.y.abs() - halfExtents.y);
        final dz = math.max(0.0, local.z.abs() - halfExtents.z);
        return math.sqrt(dx * dx + dy * dy + dz * dz);
    }
  }

  /// How much of this volume applies at [point], from nothing to [weight].
  ///
  /// A smoothstep across the blend band rather than a straight line. A
  /// straight line has a corner at each end of the band, and a camera
  /// walking through it at a steady pace sees the change start and stop with
  /// a jolt; the smoothstep eases in and out, so the rate of change is
  /// continuous as well as the value.
  double influenceAt(Vector3 point) {
    final strength = weight.clamp(0.0, 1.0);
    if (strength == 0) return 0;
    final outside = distanceTo(point);
    if (outside <= 0) return strength;
    if (blendDistance <= 0) return 0;
    final t = (1 - outside / blendDistance).clamp(0.0, 1.0);
    return strength * t * t * (3 - 2 * t);
  }
}

/// The settings a volume can move, as numbers, and the resolver that moves
/// them.
///
/// Pure and deterministic: the same scene, volumes and point always give the
/// same answer, bit for bit, whatever order the volumes were listed in. That
/// matters more than it sounds. The resolver runs on every frame for every
/// view, and an answer that depended on list order or on the last frame would
/// flicker when an editor reordered its outliner, and would draw two views of
/// one place differently.
///
/// Each quantity is blended in the space it is perceived in:
///
/// * colours component by component, which is correct because every colour
///   in the engine is already linear;
/// * light levels — the ambient and the environment, in lux — in log space,
///   because the eye sees ratios: halfway between a hundred lux and ten
///   thousand looks like a thousand, not like five thousand and fifty;
/// * exposure in stops, which is already a logarithm, so plainly;
/// * the environment's rotation round the circle, the short way, so that
///   blending 350 degrees towards 10 passes through 0 rather than 180.
class OrbisEnvironmentSettings {
  OrbisEnvironmentSettings({
    required this.fogDensity,
    required this.fogColour,
    required this.fogHeight,
    required this.fogHeightFalloff,
    required this.fogStart,
    required this.fogMaximumOpacity,
    required this.exposureCompensation,
    required this.ambient,
    required this.skyColour,
    required this.environmentIntensity,
    required this.environmentRotation,
    required this.bloomStrength,
    required this.saturation,
    required this.contrast,
    required this.temperature,
    required this.tint,
    required this.midtones,
  });

  /// What [scene] already says, before any volume has touched it.
  ///
  /// Effective values rather than stored ones. A switched-off bloom has a
  /// strength of nothing whatever its field says, and a switched-off grade
  /// is neutral, so a volume that turns either on starts from what was
  /// actually on screen and the edge of it does not jump.
  factory OrbisEnvironmentSettings.of(OrbisScene scene) {
    final fog = scene.fog;
    final bloom = scene.post.bloom;
    final grading = scene.post.grading;
    return OrbisEnvironmentSettings(
      fogDensity: fog.density,
      fogColour: fog.colour.clone(),
      fogHeight: fog.height,
      fogHeightFalloff: fog.heightFalloff,
      fogStart: fog.distance,
      fogMaximumOpacity: fog.maximumOpacity,
      exposureCompensation: 0,
      ambient: scene.sky.ambient,
      skyColour: scene.sky.colour.clone(),
      environmentIntensity: scene.environment.intensity,
      environmentRotation: scene.environment.rotation,
      bloomStrength: bloom.enabled ? bloom.strength : 0,
      saturation: grading.enabled ? grading.saturation : 1,
      contrast: grading.enabled ? grading.contrast : 1,
      temperature: grading.enabled ? grading.temperature : 0,
      tint: grading.enabled ? grading.tint : 0,
      midtones: grading.enabled ? grading.midtones.clone() : Vector3.all(1),
    );
  }

  final double fogDensity;
  final Vector3 fogColour;
  final double fogHeight;
  final double fogHeightFalloff;
  final double fogStart;
  final double fogMaximumOpacity;
  final double exposureCompensation;
  final double ambient;
  final Vector3 skyColour;
  final double environmentIntensity;
  final double environmentRotation;
  final double bloomStrength;
  final double saturation;
  final double contrast;
  final double temperature;
  final double tint;
  final Vector3 midtones;

  /// Every number, in a fixed order. For comparing two resolutions and for
  /// printing one, which is how a blend is checked for a step.
  List<double> get values => [
    fogDensity,
    ...fogColour.storage,
    fogHeight,
    fogHeightFalloff,
    fogStart,
    fogMaximumOpacity,
    exposureCompensation,
    ambient,
    ...skyColour.storage,
    environmentIntensity,
    environmentRotation,
    bloomStrength,
    saturation,
    contrast,
    temperature,
    tint,
    ...midtones.storage,
  ];

  /// These settings with [volumes] applied, as seen from [at].
  ///
  /// Lowest [OrbisEnvironmentVolume.priority] first and highest last, ties
  /// broken by key; each one moves every setting it names from wherever the
  /// volumes before it left it towards its own value, by its influence at
  /// [at]. Settings it does not name are not touched at all — not moved
  /// towards themselves, not rounded — so a volume that only fogs leaves the
  /// ambient exactly as it was.
  OrbisEnvironmentSettings resolve(
    List<OrbisEnvironmentVolume> volumes,
    Vector3 at,
  ) {
    final ordered = [...volumes]
      ..sort((a, b) {
        final byPriority = a.priority.compareTo(b.priority);
        return byPriority != 0 ? byPriority : a.key.compareTo(b.key);
      });

    var fogDensity = this.fogDensity;
    final fogColour = this.fogColour.clone();
    var fogHeight = this.fogHeight;
    var fogHeightFalloff = this.fogHeightFalloff;
    var fogStart = this.fogStart;
    var fogMaximumOpacity = this.fogMaximumOpacity;
    var exposure = exposureCompensation;
    var ambient = this.ambient;
    final skyColour = this.skyColour.clone();
    var environmentIntensity = this.environmentIntensity;
    var environmentRotation = this.environmentRotation;
    var bloomStrength = this.bloomStrength;
    var saturation = this.saturation;
    var contrast = this.contrast;
    var temperature = this.temperature;
    var tint = this.tint;
    final midtones = this.midtones.clone();

    for (final volume in ordered) {
      final w = volume.influenceAt(at);
      if (w <= 0) continue;
      final o = volume.overrides;
      // At full strength the answer is the volume's own number, exactly.
      // a + (b - a) * 1 is not always b in floating point, and "inside the
      // hall the fog is what the hall says" should be true to the last bit.
      final full = w >= 1;

      double linear(double from, double? to) => to == null
          ? from
          : full
          ? to
          : from + (to - from) * w;
      void colour(Vector3 from, Vector3? to) {
        if (to == null) return;
        full ? from.setFrom(to) : Vector3.mix(from, to, w, from);
      }

      fogDensity = linear(fogDensity, o.fogDensity);
      colour(fogColour, o.fogColour);
      fogHeight = linear(fogHeight, o.fogHeight);
      fogHeightFalloff = linear(fogHeightFalloff, o.fogHeightFalloff);
      fogStart = linear(fogStart, o.fogStart);
      fogMaximumOpacity = linear(fogMaximumOpacity, o.fogMaximumOpacity);
      exposure = linear(exposure, o.exposureCompensation);
      ambient = _logarithmic(ambient, o.ambient, w);
      colour(skyColour, o.skyColour);
      environmentIntensity = _logarithmic(
        environmentIntensity,
        o.environmentIntensity,
        w,
      );
      environmentRotation = _angular(
        environmentRotation,
        o.environmentRotation,
        w,
      );
      bloomStrength = linear(bloomStrength, o.bloomStrength);
      saturation = linear(saturation, o.saturation);
      contrast = linear(contrast, o.contrast);
      temperature = linear(temperature, o.temperature);
      tint = linear(tint, o.tint);
      colour(midtones, o.midtones);
    }

    return OrbisEnvironmentSettings(
      fogDensity: fogDensity,
      fogColour: fogColour,
      fogHeight: fogHeight,
      fogHeightFalloff: fogHeightFalloff,
      fogStart: fogStart,
      fogMaximumOpacity: fogMaximumOpacity,
      exposureCompensation: exposure,
      ambient: ambient,
      skyColour: skyColour,
      environmentIntensity: environmentIntensity,
      environmentRotation: environmentRotation,
      bloomStrength: bloomStrength,
      saturation: saturation,
      contrast: contrast,
      temperature: temperature,
      tint: tint,
      midtones: midtones,
    );
  }

  /// [scene] with these settings in it.
  ///
  /// Whatever came out equal to what [scene] already said is handed back as
  /// the very same object, not a copy of it. Outside every volume the scene
  /// that is sent is therefore the scene the host built, down to identity,
  /// and the renderer's own "nothing moved" checks see nothing move.
  OrbisScene applyTo(OrbisScene scene) {
    final base = OrbisEnvironmentSettings.of(scene);

    var fog = scene.fog;
    if (fogDensity != base.fogDensity ||
        fogColour != base.fogColour ||
        fogHeight != base.fogHeight ||
        fogHeightFalloff != base.fogHeightFalloff ||
        fogStart != base.fogStart ||
        fogMaximumOpacity != base.fogMaximumOpacity) {
      fog = OrbisFog(
        colour: fogColour.clone(),
        density: fogDensity,
        distance: fogStart,
        cutOffDistance: fog.cutOffDistance,
        maximumOpacity: fogMaximumOpacity,
        height: fogHeight,
        heightFalloff: fogHeightFalloff,
        structure: fog.structure,
        wind: fog.wind,
        featureSize: fog.featureSize,
        thickness: fog.thickness,
      );
    }

    var camera = scene.camera;
    if (exposureCompensation != 0) {
      // More stops is more light, and a longer shutter lets in more: one stop
      // up is the shutter open twice as long.
      camera = camera.copyWith(
        shutterSpeed:
            camera.shutterSpeed * math.pow(2, exposureCompensation).toDouble(),
      );
    }

    var sky = scene.sky;
    if (ambient != base.ambient || skyColour != base.skyColour) {
      sky = OrbisSky(
        colour: skyColour.clone(),
        zenith: sky.zenith,
        horizon: sky.horizon,
        ambient: ambient,
        showBody: sky.showBody,
        drawn: sky.drawn,
        quality: sky.quality,
        bodyDirection: sky.bodyDirection,
        bodyColour: sky.bodyColour,
        bodySize: sky.bodySize,
        flash: sky.flash,
        flashDirection: sky.flashDirection,
        flashSeed: sky.flashSeed,
        clouds: sky.clouds,
      );
    }

    var environment = scene.environment;
    if (environmentIntensity != base.environmentIntensity ||
        environmentRotation != base.environmentRotation) {
      environment = environment.copyWith(
        intensity: environmentIntensity,
        rotation: environmentRotation,
      );
    }

    var post = scene.post;
    final bloomMoved = bloomStrength != base.bloomStrength;
    final gradingMoved =
        saturation != base.saturation ||
        contrast != base.contrast ||
        temperature != base.temperature ||
        tint != base.tint ||
        midtones != base.midtones;
    if (bloomMoved || gradingMoved) {
      final bloom = post.bloom;
      final grading = post.grading;
      // New objects rather than the host's with a field changed: these are
      // mutable, and the host's scene is still the host's.
      post = OrbisPostProcess(
        enabled: post.enabled,
        antiAliasing: post.antiAliasing,
        dithering: post.dithering,
        depthOfField: post.depthOfField,
        vignette: post.vignette,
        occlusion: post.occlusion,
        reflections: post.reflections,
        bloom: bloomMoved
            ? OrbisBloom(
                enabled: bloom.enabled || bloomStrength > 0,
                strength: bloomStrength,
                levels: bloom.levels,
                threshold: bloom.threshold,
                lensFlare: bloom.lensFlare,
                flareStrength: bloom.flareStrength,
              )
            : bloom,
        grading: gradingMoved
            ? OrbisGrading(
                enabled: true,
                toneMapping: grading.toneMapping,
                exposure: grading.enabled ? grading.exposure : 0,
                contrast: contrast,
                saturation: saturation,
                vibrance: grading.enabled ? grading.vibrance : 1,
                temperature: temperature,
                tint: tint,
                shadows: grading.enabled ? grading.shadows : null,
                midtones: midtones.clone(),
                highlights: grading.enabled ? grading.highlights : null,
              )
            : grading,
      );
    }

    return scene.copyWith(
      fog: fog,
      camera: camera,
      sky: sky,
      environment: environment,
      post: post,
      volumes: const [],
    );
  }

  /// Towards [to] in log space, where the eye judges light.
  ///
  /// Nothing has no logarithm, so a blend to or from zero lux falls back to a
  /// straight line — which is also what it looks like: the last few lux of a
  /// light going out are invisible either way.
  static double _logarithmic(double from, double? to, double w) {
    if (to == null) return from;
    if (w >= 1) return to;
    if (from <= 0 || to <= 0) return from + (to - from) * w;
    return math.exp(math.log(from) + (math.log(to) - math.log(from)) * w);
  }

  /// Towards [to] the short way round the circle, in radians.
  static double _angular(double from, double? to, double w) {
    if (to == null) return from;
    if (w >= 1) return to;
    const turn = 2 * math.pi;
    // Into (-pi, pi]: Dart's % is never negative for a positive divisor.
    final difference = ((to - from + math.pi) % turn) - math.pi;
    return from + difference * w;
  }
}
