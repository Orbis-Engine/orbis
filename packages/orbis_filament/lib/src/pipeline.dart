import 'dart:typed_data';

/// How a shadow's edge is worked out.
enum OrbisShadowKind {
  /// A fixed pattern of samples around each pixel. The edge is as soft as the
  /// pattern is wide and no softer, wherever the caster is. Cheapest, and
  /// perfectly good for a scene that is mostly sunlight.
  sharp('Sharp'),

  /// The penumbra grows with the gap between the caster and what it lands on,
  /// which is what a real shadow does: sharp where a chair leg meets the
  /// floor, soft under the seat.
  ///
  /// Draws the same picture as [area] on Filament 1.76, which is worth saying
  /// so that nobody spends an afternoon looking for the difference. This asks
  /// Filament for DPCF, and its own header marks DPCF deprecated and falls it
  /// back to PCSS — measured in the Shadows example, where the two kinds came
  /// out byte-identical across all 1.92M pixels. Kept as its own name because
  /// it says what is wanted rather than which technique happens to serve it,
  /// and because the cheaper path may come back.
  soft('Soft'),

  /// The penumbra is worked out from how big the light actually is, so a
  /// strip light and a bare bulb do not cast the same shadow. The dearest of
  /// the three, and the only one where the light's size means anything.
  area('Area'),

  /// Shadows kept as a distribution rather than a depth, so they can be
  /// blurred and filtered like any other texture. Very soft, very cheap to
  /// filter, and prone to light leaking through thin walls.
  variance('Variance');

  const OrbisShadowKind(this.label);

  final String label;
}

/// How much of everything a machine is asked to do.
///
/// Not different pipelines. There is one pipeline, and these are settings of
/// it — which is the whole point: a scene that looks right on a laptop is the
/// same scene, drawn the same way, with smaller numbers. Nothing appears or
/// disappears between tiers, so nothing has to be authored twice or checked
/// twice.
enum OrbisDetail {
  /// Enough to be playable on anything. One shadow cascade at half the map
  /// size, no multisampling, and the frame allowed to shrink to hold its
  /// rate.
  low('Low'),

  /// The default. Two cascades, a kilobyte map, and a fixed resolution.
  medium('Medium'),

  /// Three cascades, soft shadows, and four samples of multisampling.
  high('High'),

  /// Everything on and nothing shrinking. Four cascades at four kilobytes,
  /// area shadows, and a high-precision colour buffer.
  ultra('Ultra');

  const OrbisDetail(this.label);

  final String label;
}

/// Everything about shadows that is not a property of one light.
///
/// Not here, and not for want of trying: holding a shadow map still between
/// frames. Filament redraws every map every frame, and the machinery that
/// would keep one — its shadow atlas and the per-light decision to reuse a
/// slot — is entirely inside `ShadowMapManager`, which is not a public
/// header. There is no `ShadowOptions` field and no `View` call that asks for
/// it, so a scene of a hundred static lights pays for a hundred maps every
/// frame whatever Orbis does. It would have to be Filament's change.
class OrbisShadows {
  OrbisShadows({
    this.enabled = true,
    this.kind = OrbisShadowKind.sharp,
    this.mapSize = 1024,
    this.cascades = 2,
    this.distance = 0,
    this.lambda = 0.5,
    this.constantBias = 0.001,
    this.normalBias = 1.0,
    this.stable = false,
    this.contact = false,
    this.softness = 1.0,
    this.splits,
    this.softnessFalloff = 1.0,
    this.contactDistance = 0.3,
    this.contactSteps = 8,
    OrbisVarianceShadows? variance,
  }) : variance = variance ?? OrbisVarianceShadows();

  /// The one switch. Off is not "no shadow maps drawn cheaply" — it is no
  /// shadow pass at all, which on a scene of any size is the single largest
  /// saving available.
  bool enabled;

  OrbisShadowKind kind;

  /// How many pixels across the shadow map is. Doubling it quarters the size
  /// of the smallest thing a shadow can show and quadruples what it costs.
  int mapSize;

  /// How many maps the distance is divided between, so that things near the
  /// camera get a map to themselves.
  ///
  /// The single most effective shadow setting there is: one cascade over a
  /// hundred metres puts about a centimetre in each pixel, and four cascades
  /// over the same hundred metres puts a millimetre in the first one.
  int cascades;

  /// How far shadows are drawn, in metres. Nought means as far as the camera
  /// sees, which is honest and often much further than anybody needs.
  double distance;

  /// How the cascades are spread between near and far, from evenly at nought
  /// to logarithmically at one. Half is the usual compromise and is what a
  /// perspective camera actually wants.
  double lambda;

  /// How far a surface is pushed away from its own shadow. Too little and a
  /// surface shadows itself in stripes; too much and a shadow floats away
  /// from what casts it.
  double constantBias;
  double normalBias;

  /// Whether the shadow map is locked to the world rather than to the camera.
  ///
  /// Steadier — a shadow edge stops crawling as the camera moves — at the
  /// cost of resolution, because a map that cannot rotate with the camera has
  /// to be big enough for every angle.
  bool stable;

  /// Whether short-range shadows are traced in screen space as well.
  ///
  /// Catches what a shadow map cannot: the contact between a foot and the
  /// ground, a pen and the desk it lies on. Small, cheap and the difference
  /// between an object standing on a floor and hovering over it.
  ///
  /// Not free of its own artefact, and the artefact is Filament's rather than
  /// this engine's: on a large flat floor seen at a grazing angle far from
  /// the camera, the march finds the floor itself and lays a grain over it.
  /// Measured in the Shadows example — 187k of 1.92M pixels change by more
  /// than one level when the switch goes on, and almost all of that is the
  /// grain rather than any object's contact. Shortening [contactDistance] to
  /// 0.05 m does not remove it: the pattern gets finer (mean neighbouring-
  /// pixel step 3.7 levels down to 2.1) and spreads wider (740k pixels), and
  /// there is no thickness or bias exposed to tighten it with. So this is off
  /// by default and is worth turning on for a close, cluttered scene rather
  /// than for an open one.
  bool contact;

  /// How wide the penumbra is, for [OrbisShadowKind.soft] and
  /// [OrbisShadowKind.area] — the two that work one out rather than filtering
  /// a fixed width.
  ///
  /// A multiplier over the physical answer rather than a size: one is what
  /// the light's own radius says, and everything else is a mood.
  double softness;

  /// Where each cascade hands over to the next, as rising fractions of
  /// [distance] — one fewer than [cascades]. Null lets [lambda] place them.
  ///
  /// Worth setting by hand when the scene says where the detail is: a
  /// third-person camera wants its first cascade to end just past the
  /// character, wherever the practical split would have put it. A list that
  /// does not rise, or is too short, is ignored rather than half-used.
  List<double>? splits;

  /// For [OrbisShadowKind.area]: how much faster the penumbra widens with the
  /// gap between caster and receiver. One is physical; above it exaggerates
  /// the contact hardening, below it evens the edge out.
  double softnessFalloff;

  /// How far a [contact] shadow is traced from each pixel, in metres, and in
  /// how many steps. Longer finds more; fewer steps misses thin things.
  double contactDistance;
  int contactSteps;

  /// The settings only [OrbisShadowKind.variance] reads.
  final OrbisVarianceShadows variance;
}

/// How variance shadow maps are blurred and filtered.
///
/// A variance map keeps the mean and the spread of depth rather than the
/// depth itself, which is what lets it be blurred like a picture — and what
/// makes it leak light through a thin wall, because a spread says nothing
/// about what is in the middle of it. Every dial here is a trade between
/// those two.
class OrbisVarianceShadows {
  OrbisVarianceShadows({
    this.blur = 0,
    this.anisotropy = 0,
    this.samples = 1,
    this.lightBleedReduction = 0.15,
    this.highPrecision = false,
    this.mipmapping = false,
    this.exponential = false,
  });

  /// How wide the blur is, in texels. Nought is none.
  double blur;

  /// Anisotropic filtering of the map, as a power of two: nought is off, and
  /// each step doubles how steep a surface can be before its shadow smears.
  int anisotropy;

  /// Multisampling of the map itself: one, two or four.
  int samples;

  /// How much of a leak is cut away, nought to one. Higher removes light
  /// bleeding through thin walls and hardens every edge with it.
  double lightBleedReduction;

  // Not here: a floor under the variance, which older writing about VSM
  // describes as the dial that stops acne on flat ground. Filament 1.76 marks
  // `VsmShadowOptions::minVarianceScale` deprecated and says outright that it
  // has no effect, so there is nothing behind it to expose. A dial that moves
  // and changes nothing is worse than no dial.

  /// Thirty-two bits a channel rather than sixteen — fewer artefacts over a
  /// long shadow distance, at twice the memory.
  bool highPrecision;

  /// Whether the map has mipmaps, so a distant shadow is filtered rather
  /// than aliased.
  bool mipmapping;

  /// Exponential variance: fewer leaks, at a second pair of channels.
  bool exponential;
}

/// How many pixels are actually drawn before the frame is shown.
///
/// The most direct dial there is: everything a renderer does per pixel costs
/// what it costs, and drawing three quarters as many is drawing three
/// quarters as much.
class OrbisResolution {
  OrbisResolution({
    this.scale = 1.0,
    this.adaptive = false,
    this.minScale = 0.5,
    this.maxScale = 1.0,
    this.sharpness = 0.9,
  });

  /// A fixed fraction of the view. One is every pixel.
  double scale;

  /// Whether the renderer is allowed to move [scale] between [minScale] and
  /// [maxScale] to hold its frame rate.
  ///
  /// The honest answer to a machine that cannot quite keep up. A frame that
  /// arrives on time slightly soft is better than one that arrives late
  /// sharp, and the alternative — asking the player to find a settings menu —
  /// is worse than both.
  bool adaptive;

  double minScale;
  double maxScale;

  /// How much the upscale is sharpened on the way back. Nought is a plain
  /// stretch.
  double sharpness;
}

/// How the renderer works out which lights reach a pixel.
///
/// A scene with two hundred lamps in it does not shade two hundred lights per
/// pixel. The view is cut into cells running away from the camera, each light
/// is put in the cells it actually reaches, and a pixel consults its own cell
/// — so a lamp at the far end of a corridor costs nothing at this end.
///
/// What is worth setting is where that grid starts and stops, because the
/// cells are not evenly spaced: they are fine near the camera and coarse far
/// away, and these two numbers are where that distribution is anchored. A
/// grid that stops at a hundred metres in a scene whose lights are two
/// hundred metres out puts every distant light in one cell, which is the
/// case this exists to avoid.
class OrbisLighting {
  OrbisLighting({this.clusterNear = 5, this.clusterFar = 100});

  /// Where the cells start, in metres from the camera. Nearer than this is
  /// one cell, which is the right answer for the few metres in front of a
  /// face.
  double clusterNear;

  /// Where they stop, in metres. Everything beyond is one cell, so this wants
  /// to be about as far as the furthest light that matters.
  double clusterFar;
}

/// How a frame gets drawn.
///
/// One pipeline, not a choice of them. Every frame goes the same way: shadow
/// maps, then the depth the whole frame is sorted and occluded by, then the
/// opaque objects lit, then the sky behind what is left, then everything
/// see-through back to front, then the image work. The order is not
/// negotiable, because a renderer that lets it be negotiated has to be
/// correct for every ordering anybody might choose and can therefore optimise
/// for none of them.
///
/// What *is* negotiable is how much of each step happens, which is what this
/// describes. [OrbisDetail] gives four settings of those dials that have
/// names; everything can also be set by hand.
///
/// The deliberate omission is a way for somebody to add a pass. That is the
/// hole an extension point would fill, and it is left open on purpose until
/// there is a real second user for it: a plugin surface invented before
/// anybody has plugged anything into it is a guess at what they will need.
class OrbisPipeline {
  OrbisPipeline({
    OrbisShadows? shadows,
    OrbisResolution? resolution,
    OrbisLighting? lighting,
    this.samples = 1,
    this.precise = false,
    this.culling = true,
    this.refraction = true,
  }) : shadows = shadows ?? OrbisShadows(),
       lighting = lighting ?? OrbisLighting(),
       resolution = resolution ?? OrbisResolution();

  /// The pipeline at one of the four named settings.
  factory OrbisPipeline.at(OrbisDetail detail) {
    switch (detail) {
      case OrbisDetail.low:
        return OrbisPipeline(
          shadows: OrbisShadows(mapSize: 512, cascades: 1, distance: 40),
          resolution: OrbisResolution(adaptive: true, minScale: 0.5),
        );
      case OrbisDetail.medium:
        return OrbisPipeline(
          shadows: OrbisShadows(mapSize: 1024, cascades: 2, distance: 80),
        );
      case OrbisDetail.high:
        return OrbisPipeline(
          shadows: OrbisShadows(
            kind: OrbisShadowKind.soft,
            mapSize: 2048,
            cascades: 3,
            contact: true,
          ),
          samples: 4,
        );
      case OrbisDetail.ultra:
        return OrbisPipeline(
          shadows: OrbisShadows(
            kind: OrbisShadowKind.area,
            mapSize: 4096,
            cascades: 4,
            contact: true,
            stable: true,
          ),
          samples: 4,
          precise: true,
        );
    }
  }

  final OrbisShadows shadows;
  final OrbisResolution resolution;
  final OrbisLighting lighting;

  /// How many samples an edge is worked out from, before any of the image
  /// work happens. One is none.
  ///
  /// Distinct from the anti-aliasing in post: this one runs while the frame is
  /// being drawn and costs memory bandwidth on everything; that one runs on
  /// the finished image and costs almost nothing. Multisampling is sharper
  /// where they disagree, which is why both exist.
  int samples;

  /// Whether the frame is kept at sixteen bits a channel rather than eleven.
  ///
  /// Worth it for a scene with a very bright light and very dark shadow in
  /// the same shot, where the cheaper format bands in the falloff. Costs half
  /// as much again in bandwidth for every pixel of every pass.
  bool precise;

  /// Whether what the camera cannot see is skipped. Off only for finding out
  /// whether a missing object was culled or was never there.
  bool culling;

  /// Whether see-through surfaces bend what is behind them.
  bool refraction;

  /// How many floats [packed] holds.
  ///
  /// The renderer names every one of these offsets in `OrbisShadows.h`, and
  /// `native_contract_test` compares this number against the one there — a
  /// block a float short reads a nought where a dial should be, and for the
  /// contact distance that is a shadow traced nowhere.
  static const int stride = 28;

  /// Every number, in the order the renderer reads them.
  Float32List get packed {
    final out = Float32List(stride);
    out[0] = shadows.enabled ? 1 : 0;
    out[1] = shadows.kind.index.toDouble();
    out[2] = shadows.mapSize.toDouble();
    out[3] = shadows.cascades.toDouble();
    out[4] = shadows.distance;
    out[5] = shadows.lambda;
    out[6] = shadows.constantBias;
    out[7] = shadows.normalBias;
    final variance = shadows.variance;
    out[8] =
        ((shadows.stable ? 1 : 0) |
                (shadows.contact ? 2 : 0) |
                (variance.highPrecision ? 4 : 0) |
                (variance.mipmapping ? 8 : 0) |
                (variance.exponential ? 16 : 0))
            .toDouble();
    out[9] = shadows.softness;
    out[10] = resolution.adaptive ? 1 : 0;
    // A fixed scale is the adaptive one with nowhere to go, which is one
    // path in the renderer rather than two that have to agree.
    out[11] = resolution.adaptive ? resolution.minScale : resolution.scale;
    out[12] = resolution.adaptive ? resolution.maxScale : resolution.scale;
    out[13] = resolution.sharpness;
    out[14] = samples.toDouble();
    out[15] = (precise ? 1 : 0) + (culling ? 2 : 0) + (refraction ? 4 : 0);
    out[16] = lighting.clusterNear;
    out[17] = lighting.clusterFar;
    // Nought where no split is given, which the renderer reads as "let lambda
    // place them" — a split at nought would be a cascade of no depth.
    final splits = shadows.splits;
    if (splits != null) {
      for (var i = 0; i < 3 && i < splits.length; i++) {
        out[18 + i] = splits[i];
      }
    }
    out[21] = shadows.softnessFalloff;
    out[22] = variance.anisotropy.toDouble();
    out[23] = variance.blur;
    out[24] = variance.lightBleedReduction;
    out[25] = variance.samples.toDouble();
    out[26] = shadows.contactDistance;
    out[27] = shadows.contactSteps.toDouble();
    return out;
  }
}
