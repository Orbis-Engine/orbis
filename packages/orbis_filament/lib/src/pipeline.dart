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
  });

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
  bool contact;

  /// How wide the penumbra is, for the two kinds that have one.
  double softness;
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
    this.samples = 1,
    this.precise = false,
    this.culling = true,
    this.refraction = true,
  }) : shadows = shadows ?? OrbisShadows(),
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
  static const int stride = 16;

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
    out[8] = (shadows.stable ? 1 : 0) + (shadows.contact ? 2 : 0);
    out[9] = shadows.softness;
    out[10] = resolution.adaptive ? 1 : 0;
    // A fixed scale is the adaptive one with nowhere to go, which is one
    // path in the renderer rather than two that have to agree.
    out[11] = resolution.adaptive ? resolution.minScale : resolution.scale;
    out[12] = resolution.adaptive ? resolution.maxScale : resolution.scale;
    out[13] = resolution.sharpness;
    out[14] = samples.toDouble();
    out[15] = (precise ? 1 : 0) + (culling ? 2 : 0) + (refraction ? 4 : 0);
    return out;
  }
}
