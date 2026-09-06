import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart';

/// How the image is turned from light into pixels.
///
/// A renderer works in light: values that go far above one, because the sun
/// is thousands of times brighter than a lamp and both are in the same frame.
/// A screen takes numbers between nought and one. Tone mapping is the step
/// that decides how the first becomes the second, and it is the single
/// setting that most decides whether a scene looks like a photograph or like
/// a computer game.
enum ToneMapping {
  /// Filmic, and the one to use. Keeps colour in the highlights instead of
  /// letting everything bright slide to white.
  filmic('Filmic'),

  /// The academy's transform. More contrast and more saturation than filmic;
  /// what most films are graded through.
  aces('ACES'),

  /// ACES with the worst of its hue shifts taken out.
  acesLegacy('ACES (legacy)'),

  /// Straight through, clipped at one. For looking at what the renderer
  /// actually produced rather than at what it looks like.
  linear('Linear'),

  /// Nothing at all, not even the clip. For debugging a value.
  none('None');

  const ToneMapping(this.label);

  final String label;
}

/// How the jagged edges are dealt with.
enum AntiAliasing {
  /// None. Every edge is a staircase.
  off('Off'),

  /// One cheap pass over the finished image. Costs almost nothing and softens
  /// the picture slightly.
  fxaa('FXAA'),

  /// Samples spread across frames. The best-looking of the three and the one
  /// that smears if something moves quickly.
  temporal('Temporal');

  const AntiAliasing(this.label);

  final String label;
}

/// Light spilling out of the bright parts of the image.
///
/// Not an effect that makes things prettier: it is what a real lens does with
/// light it cannot contain, and without it a bright thing on screen is only as
/// bright as white — there is nowhere further for it to go.
class OrbisBloom {
  OrbisBloom({
    this.enabled = false,
    this.strength = 0.1,
    this.levels = 6,
    this.threshold = true,
    this.lensFlare = false,
    this.flareStrength = 0.02,
  });

  bool enabled;

  /// How much of it is added back, from nothing to all bloom and no image.
  double strength;

  /// How far the glow spreads, as the number of times the image is halved.
  /// More levels is a wider, softer spill.
  int levels;

  /// Whether only what is brighter than white blooms.
  ///
  /// On, a lamp glows and a white wall does not, which is what somebody
  /// expects. Off, everything glows a little, which is a look rather than a
  /// simulation.
  bool threshold;

  /// The streaks and ghosts a real lens adds around a bright light.
  bool lensFlare;
  double flareStrength;
}

/// What is out of focus.
///
/// A camera has one distance in focus and everything else is blurred by how
/// far it is from that. The strength of the effect is the aperture, which is
/// on the camera itself — this is only whether it is applied.
class OrbisDepthOfField {
  OrbisDepthOfField({
    this.enabled = false,
    this.focusDistance = 10,
    this.blurScale = 1,
    this.maxForeground = 1,
    this.maxBackground = 1,
  });

  bool enabled;

  /// How far away the sharp plane is, in metres.
  double focusDistance;

  /// How much bigger the blur is than the physical answer. One is what the
  /// lens would do; more is what a film would do.
  double blurScale;

  /// Caps on how blurred the near and far halves get, in pixels of circle of
  /// confusion. What stops a background dissolving into porridge.
  double maxForeground;
  double maxBackground;
}

/// The corners going dark.
class OrbisVignette {
  OrbisVignette({
    this.enabled = false,
    this.midPoint = 0.5,
    this.roundness = 0.5,
    this.feather = 0.5,
    Vector3? colour,
  }) : colour = colour ?? Vector3.zero();

  bool enabled;

  /// Where the darkening starts, from the middle out.
  double midPoint;

  /// Round or rectangular: nought is the shape of the screen, one is a circle.
  double roundness;

  /// How soft the edge of the darkening is.
  double feather;

  /// What the corners go towards. Black almost always.
  final Vector3 colour;
}

/// Contact shadows: the darkening where two surfaces meet.
///
/// What tells somebody a box is standing on the floor rather than floating a
/// centimetre above it. Cheap, and the difference between a scene that reads
/// as solid and one that does not.
class OrbisOcclusion {
  OrbisOcclusion({
    this.enabled = false,
    this.radius = 0.3,
    this.strength = 1,
    this.bias = 0.0005,
    this.quality = 1,
    this.bentNormals = false,
  });

  bool enabled;

  /// How far from a point the renderer looks for something blocking the light,
  /// in metres. Small is creases; large is whole rooms getting darker.
  double radius;

  /// How dark it goes.
  double strength;

  /// How far a surface has to be from itself before it counts as blocking
  /// itself. What stops a flat wall shadowing its own texture.
  double bias;

  /// Nought to three: how many samples. Three is worth it on a still shot and
  /// not on a game.
  int quality;

  /// Whether the occlusion also bends the direction light arrives from, which
  /// makes a crease read as a crease rather than as a smudge.
  bool bentNormals;
}

/// Reflections worked out from what is already on screen.
///
/// Cheap next to anything that traces rays, and limited in exactly the way
/// that implies: it can only reflect what is in the frame, so a puddle
/// reflects the wall behind it and not the sky above the camera.
class OrbisReflections {
  OrbisReflections({
    this.enabled = false,
    this.thickness = 0.1,
    this.bias = 0.01,
    this.maxDistance = 3,
    this.stride = 2,
  });

  bool enabled;

  /// How thick the renderer assumes everything is, since a depth buffer only
  /// says where a surface is and not how deep it goes.
  double thickness;

  double bias;

  /// How far a reflection is followed, in metres.
  double maxDistance;

  /// How many pixels a step covers. Bigger is faster and blockier.
  double stride;
}

/// The colour the whole image is pushed towards.
///
/// Grading is where a scene stops looking like data and starts looking like it
/// was shot on something. The parameters are the ones a colourist uses.
class OrbisGrading {
  OrbisGrading({
    this.enabled = false,
    this.toneMapping = ToneMapping.filmic,
    this.exposure = 0,
    this.contrast = 1,
    this.saturation = 1,
    this.vibrance = 1,
    this.temperature = 0,
    this.tint = 0,
    Vector3? shadows,
    Vector3? midtones,
    Vector3? highlights,
  })  : shadows = shadows ?? Vector3.all(1),
        midtones = midtones ?? Vector3.all(1),
        highlights = highlights ?? Vector3.all(1);

  bool enabled;

  /// How light becomes pixels. Applied whether or not the rest of the grading
  /// is: something has to decide, and filmic is a better default than a clip.
  ToneMapping toneMapping;

  /// In stops. One is twice the light.
  double exposure;

  double contrast;
  double saturation;

  /// Saturation that leaves what is already colourful alone. What keeps skin
  /// from going orange when a scene is pushed.
  double vibrance;

  /// White balance. Negative is cooler, positive is warmer.
  double temperature;

  /// The other axis of white balance: negative is magenta, positive is green.
  double tint;

  /// Per-channel multipliers for the three ranges of the image.
  final Vector3 shadows;
  final Vector3 midtones;
  final Vector3 highlights;
}

/// Everything done to the image after the scene is drawn.
///
/// One object rather than a dozen settings scattered over the scene, because
/// these are decisions about the *picture* rather than about what is in it —
/// and because a look somebody arrives at is a thing they want to save, copy
/// to another scene, and put back.
///
/// Everything is off by default. A renderer that arrives with bloom on is one
/// where the first question is how to turn it off.
class OrbisPostProcess {
  OrbisPostProcess({
    this.enabled = true,
    this.antiAliasing = AntiAliasing.fxaa,
    OrbisBloom? bloom,
    OrbisDepthOfField? depthOfField,
    OrbisVignette? vignette,
    OrbisOcclusion? occlusion,
    OrbisReflections? reflections,
    OrbisGrading? grading,
    this.dithering = true,
  })  : bloom = bloom ?? OrbisBloom(),
        depthOfField = depthOfField ?? OrbisDepthOfField(),
        vignette = vignette ?? OrbisVignette(),
        occlusion = occlusion ?? OrbisOcclusion(),
        reflections = reflections ?? OrbisReflections(),
        grading = grading ?? OrbisGrading();

  /// The one switch over all of it, for comparing against the raw image.
  bool enabled;

  final AntiAliasing antiAliasing;

  final OrbisBloom bloom;
  final OrbisDepthOfField depthOfField;
  final OrbisVignette vignette;
  final OrbisOcclusion occlusion;
  final OrbisReflections reflections;
  final OrbisGrading grading;

  /// Whether a little noise is added to hide banding.
  ///
  /// On by default, because eight bits per channel is not enough for a smooth
  /// gradient and the banding it produces is the most visible artefact in a
  /// dark scene.
  final bool dithering;

  /// How many floats [packed] holds.
  static const int stride = 49;

  /// Every number, in the order the renderer reads them.
  ///
  /// One flat array rather than a map: this crosses to native code on every
  /// frame, and a map of forty entries is forty string comparisons per frame
  /// to say nothing has changed.
  Float32List get packed {
    final out = Float32List(stride);
    var at = 0;

    void write(double value) => out[at++] = value;
    void flag(bool on) => out[at++] = on ? 1 : 0;

    flag(enabled);
    write(antiAliasing.index.toDouble());
    flag(dithering);

    flag(bloom.enabled);
    write(bloom.strength);
    write(bloom.levels.toDouble());
    flag(bloom.threshold);
    flag(bloom.lensFlare);
    write(bloom.flareStrength);

    flag(depthOfField.enabled);
    write(depthOfField.focusDistance);
    write(depthOfField.blurScale);
    write(depthOfField.maxForeground);
    write(depthOfField.maxBackground);

    flag(vignette.enabled);
    write(vignette.midPoint);
    write(vignette.roundness);
    write(vignette.feather);
    write(vignette.colour.x);
    write(vignette.colour.y);
    write(vignette.colour.z);

    flag(occlusion.enabled);
    write(occlusion.radius);
    write(occlusion.strength);
    write(occlusion.bias);
    write(occlusion.quality.toDouble());
    flag(occlusion.bentNormals);

    flag(reflections.enabled);
    write(reflections.thickness);
    write(reflections.bias);
    write(reflections.maxDistance);
    write(reflections.stride);

    flag(grading.enabled);
    write(grading.toneMapping.index.toDouble());
    write(grading.exposure);
    write(grading.contrast);
    write(grading.saturation);
    write(grading.vibrance);
    write(grading.temperature);
    write(grading.tint);
    for (final channel in [grading.shadows, grading.midtones, grading.highlights]) {
      write(channel.x);
      write(channel.y);
      write(channel.z);
    }

    assert(at == stride, 'packed $at of $stride');
    return out;
  }
}
