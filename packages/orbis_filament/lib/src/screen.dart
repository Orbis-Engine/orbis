import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart';

/// Light scattered towards the eye by the air between it and the sun: the
/// shafts through a gap in the trees, the beams across a dusty hall.
///
/// The method is Mitchell's, from "Volumetric Light Scattering as a
/// Post-Process" (GPU Gems 3, chapter 13). Each pixel walks towards the
/// sun's place on the screen and adds up how much of the way is open sky,
/// each step counting a little less than the one before. Where a pillar
/// stands between the pixel and the sun the walk crosses it and gathers
/// nothing, and that dark wedge in a bright one is what reads as a shaft.
///
/// What counts as open sky comes from the depth buffer rather than from how
/// bright the picture is, so a sunlit white wall is an occluder like any
/// other instead of throwing shafts of its own. Only the sky near the sun
/// sends light, which is the difference between shafts and a haze over the
/// whole frame.
///
/// Driven by the scene's own directional light — the first one, which is the
/// one the renderer draws — so the shafts point where the shadows do without
/// being told twice. They fade out as the light leaves the frame or turns
/// side-on to the camera, vanish when it is behind the camera, and thin under
/// cloud: overcast is the sun spread across the whole sky, with nothing left
/// to make a shaft from.
///
/// Off by default, and free when off: a scene that never mentions god rays
/// draws exactly the frame it drew before. Turned on in a scene with no
/// render graph of its own, the renderer draws the world into a texture and
/// adds the shafts on the way to the screen. A scene with its own graph puts
/// an [OrbisEffect.godRays] pass wherever it wants them, and this says how
/// strong they are.
///
/// Not free when on. Measured on the God rays example at 1600 by 1200 on
/// Metal: 64 samples takes the frame from about 2.2 ms, drawn through a
/// texture and a copy, to 3.8–4.1 ms — so the shafts themselves cost 1.6 to
/// 1.9 ms, near enough in proportion to the number of pixels. Running the
/// walk into a half-size target would cut that by three quarters and is not
/// built yet.
class OrbisGodRays {
  const OrbisGodRays({
    this.strength = 0,
    this.decay = 0.97,
    this.density = 0.9,
    this.samples = 64,
    this.tint,
  });

  /// No shafts at all.
  static const OrbisGodRays off = OrbisGodRays();

  /// How bright the shafts are. Nought is off; one adds as much light as the
  /// sky around the sun already has.
  ///
  /// Mitchell's exposure and weight, folded into one. His weight is worked
  /// out rather than asked for: it is whatever makes the walk's weights add
  /// up to one, so [samples] and [decay] change the shape of the shafts and
  /// never how bright they are.
  final double strength;

  /// How much each step of the walk counts relative to the one before. One
  /// is long shafts all the way from the sun; lower is shafts that fade out
  /// close to whatever cast them.
  final double decay;

  /// How far towards the sun each pixel walks, as a fraction of the way.
  /// Lower is shorter, tighter shafts; above one reaches past the sun.
  final double density;

  /// How many steps each pixel takes. More is smoother and slower; at most
  /// 128. The walk starts a different fraction of a step along per pixel, so
  /// too few reads as grain rather than as rings.
  final int samples;

  /// The shafts' colour, or null for the light's own.
  final Vector3? tint;

  /// Whether there is anything to draw.
  bool get isOn => strength > 0 && samples > 0;

  /// How many floats the settings take on the wire.
  static const int stride = 12;

  /// The settings as the renderer reads them, for a light shining towards
  /// [towardLight] in [lightColour] under [cloudCover].
  ///
  /// All nought when off or when there is no light, which the renderer takes
  /// as nothing to add — a god-ray pass in a graph then copies its input.
  Float32List pack({
    Vector3? towardLight,
    Vector3? lightColour,
    double cloudCover = 0,
  }) {
    final out = Float32List(stride);
    if (!isOn || towardLight == null || towardLight.length2 == 0) return out;
    final colour = tint ?? lightColour ?? Vector3(1, 1, 1);
    final toward = towardLight.normalized();
    out[0] = strength;
    out[1] = decay;
    out[2] = density;
    out[3] = samples.toDouble();
    out[4] = colour.x;
    out[5] = colour.y;
    out[6] = colour.z;
    out[7] = toward.x;
    out[8] = toward.y;
    out[9] = toward.z;
    out[10] = cloudCover;
    out[11] = 1;
    return out;
  }
}

/// What a distortion is.
///
/// In this order because the renderer reads the index; nought is kept for
/// "none" so a row of zeros is a distortion that does nothing.
enum OrbisDistortionKind {
  none,

  /// A shell of air running out from a point.
  shockwave,

  /// A box of hot air with the shimmer rising through it.
  haze,

  /// The whole frame warped about its middle.
  lens,
}

/// Air that bends the light passing through it.
///
/// On the screen, bending light is reading the picture from a little way
/// off, so every distortion is an offset added to where each pixel is read
/// from. The renderer sums them in one pass over the finished frame, which
/// can also split the channels apart where the bending is strongest — the
/// fringe a real lens gives when it bends red and blue by different amounts.
///
/// Depth-aware: a haze or a wave only bends what is behind it, and a pixel is
/// never moved to read a surface standing in front of it. So a heat haze
/// behind a pillar shimmers around the pillar without bending the pillar.
///
/// Free when nothing distorts. A scene whose distortions all have a strength
/// of nought — or that has none — draws no extra pass at all.
class OrbisDistortion {
  const OrbisDistortion._({
    required this.kind,
    required this.strength,
    this.chromatic = 0,
    this.centre,
    this.radius = 0,
    this.thickness = 0,
    this.halfSize,
    this.scale = 0,
    this.rise = 0,
  });

  /// A shell of air [radius] metres out from [centre], [thickness] metres
  /// through.
  ///
  /// Surfaces the shell passes through are pushed outwards from its centre by
  /// up to [strength] — a fraction of the frame's height, so the same wave
  /// bends the same amount in a small window and a large one. On a floor it
  /// reads as a ring running across it.
  factory OrbisDistortion.shockwave({
    required Vector3 centre,
    required double radius,
    double thickness = 0.6,
    double strength = 0.03,
    double chromatic = 0,
  }) => OrbisDistortion._(
    kind: OrbisDistortionKind.shockwave,
    strength: strength,
    chromatic: chromatic,
    centre: centre,
    radius: radius,
    thickness: thickness,
  );

  /// A shockwave [age] seconds after it went off: grown at [speed] metres a
  /// second, and weakening until it is gone after [lifetime].
  ///
  /// The clock is the host's rather than the renderer's, so a frame drawn at
  /// a given moment is always the same frame — which is what makes one
  /// possible to test.
  factory OrbisDistortion.expanding({
    required Vector3 centre,
    required double age,
    double speed = 5,
    double lifetime = 2,
    double thickness = 0.6,
    double strength = 0.03,
    double chromatic = 0,
  }) {
    final left = age < 0 || age >= lifetime ? 0.0 : 1 - age / lifetime;
    return OrbisDistortion.shockwave(
      centre: centre,
      radius: speed * age.clamp(0, lifetime),
      thickness: thickness,
      strength: strength * left,
      chromatic: chromatic,
    );
  }

  /// Hot air in a box [halfSize] either side of [centre], shimmering upwards.
  ///
  /// [strength] is the most any pixel moves, as a fraction of the frame's
  /// height; [scale] is the size of the shimmer's features in metres. The
  /// pattern rises at [speed] metres a second on the host's own clock,
  /// [seconds], and is strongest at the bottom of the box, where the heat
  /// comes from.
  factory OrbisDistortion.haze({
    required Vector3 centre,
    required Vector3 halfSize,
    double strength = 0.006,
    double scale = 0.25,
    double speed = 0.8,
    double seconds = 0,
    double chromatic = 0,
  }) => OrbisDistortion._(
    kind: OrbisDistortionKind.haze,
    strength: strength,
    chromatic: chromatic,
    centre: centre,
    halfSize: halfSize,
    scale: scale,
    rise: speed * seconds,
  );

  /// The whole frame warped about its middle: barrel for a positive
  /// [strength], pincushion for a negative one.
  ///
  /// Each pixel reads from further out or further in by the square of its
  /// distance from the middle, so the top and bottom edges move by half of
  /// [strength] of the frame's height and the middle does not move at all.
  factory OrbisDistortion.lens({
    required double strength,
    double chromatic = 0,
  }) => OrbisDistortion._(
    kind: OrbisDistortionKind.lens,
    strength: strength,
    chromatic: chromatic,
  );

  final OrbisDistortionKind kind;

  /// How far it moves the picture. What the number means depends on [kind].
  final double strength;

  /// How far the red and blue channels are pulled apart, as a fraction of how
  /// far the picture is moved. Nought keeps the channels together.
  final double chromatic;

  final Vector3? centre;
  final double radius;
  final double thickness;
  final Vector3? halfSize;
  final double scale;

  /// How far a haze's shimmer has risen, in metres.
  final double rise;

  /// Whether it moves anything at all.
  bool get isActive =>
      kind != OrbisDistortionKind.none && strength != 0 && strength.isFinite;

  /// How many floats one distortion takes on the wire.
  static const int stride = 12;

  /// The most one frame draws. The renderer's loop is bounded by it.
  static const int capacity = 8;

  void _pack(Float32List into, int at) {
    final c = centre ?? Vector3.zero();
    into[at] = kind.index.toDouble();
    into[at + 1] = strength;
    into[at + 2] = chromatic;
    into[at + 3] = c.x;
    into[at + 4] = c.y;
    into[at + 5] = c.z;
    switch (kind) {
      case OrbisDistortionKind.shockwave:
        into[at + 6] = radius;
        into[at + 7] = thickness;
      case OrbisDistortionKind.haze:
        final size = halfSize ?? Vector3(1, 1, 1);
        into[at + 6] = size.x;
        into[at + 7] = size.y;
        into[at + 8] = size.z;
        into[at + 9] = scale;
        into[at + 10] = rise;
      case OrbisDistortionKind.lens:
      case OrbisDistortionKind.none:
        break;
    }
  }

  /// The ones that move anything, packed end to end — at most [capacity].
  static Float32List packAll(List<OrbisDistortion> distortions) {
    final active = distortions.where((one) => one.isActive).take(capacity);
    final out = Float32List(active.length * stride);
    var i = 0;
    for (final one in active) {
      one._pack(out, i * stride);
      i++;
    }
    return out;
  }
}
