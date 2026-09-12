import 'dart:typed_data';

import 'decal.dart';
import 'material.dart';
import 'outline.dart';
import 'environment.dart';
import 'field.dart';
import 'graph.dart';
import 'pipeline.dart';
import 'video.dart';
import 'post.dart';
import 'screen.dart';
import 'volumes.dart';

import 'package:vector_math/vector_math_64.dart';

import 'population.dart';
import 'splats.dart';

/// One thing to draw: where it is, what it is made of, and how it behaves
/// towards light.
///
/// The [key] is what makes a scene cheap to send repeatedly. A scene arrives
/// on every frame of a drag, and a renderer that cannot tell this frame's
/// crate from last frame's has no choice but to destroy everything and build
/// it again. A key that survives an edit lets the renderer move what moved and
/// leave the rest alone.
///
/// Keys are the host's to invent and the host's to keep stable. Any number
/// will do, as long as one object carries the same key for as long as it
/// exists and no new object reuses a key still in the scene.
class OrbisObject {
  /// Creates an object at [transform] in [colour], which is linear RGB — not
  /// sRGB, and not a Flutter Color, because the lighting maths happens in
  /// linear space and a silent conversion is the kind that goes unnoticed.
  const OrbisObject({
    required this.key,
    required this.transform,
    required this.colour,
    this.mesh,
    this.material,
    this.castShadows = true,
    this.receiveShadows = true,
    this.visible = true,
    this.layer = 0,
    this.morphWeights,
  });

  /// How far each of the mesh's shapes is dialled in, nought to one.
  ///
  /// A morph target is a second set of positions for the same vertices — a
  /// face with its mouth open, a wing folded — and the weight says how far
  /// between the two the mesh currently sits. Several add together, which is
  /// how a face is built from a smile and a blink rather than from every
  /// combination of the two.
  ///
  /// The shapes come out of the glTF; this only says how much of each. Null
  /// leaves whatever the file set, which for most models is all zeroes.
  ///
  /// Not skinning. A skeleton moves a mesh by joints and morphing moves it a
  /// vertex at a time, and they are for different things: a limb bends, a
  /// mouth does not.
  final List<double>? morphWeights;

  /// This object's identity, stable for as long as the object exists.
  final int key;

  final Matrix4 transform;
  final Vector3 colour;

  /// An absolute path to a glTF or glb file, or null for the built-in cube.
  ///
  /// Loaded once and kept, however many scenes mention it. An object naming a
  /// file that cannot be read is drawn as the cube, and the failure comes back
  /// from the publish rather than being logged where nobody sees it.
  final String? mesh;

  /// The key of the material this object is made of, or null to be drawn in
  /// [colour] on the default surface.
  ///
  /// A key rather than the material itself, because a material is shared —
  /// one entry in [OrbisScene.materials] stands behind every object made of
  /// it, and the renderer keeps one instance for the lot. Naming a key the
  /// scene does not list falls back to [colour] rather than failing: a
  /// material that has not finished loading should not take the object off
  /// screen with it.
  ///
  /// On a mesh this *overrides* the materials the file brought with it, on
  /// every primitive. Leave it null to keep them.
  final int? material;

  /// Whether this object appears in other objects' shadows.
  ///
  /// Worth having per object rather than only per scene: a ground plane that
  /// casts is a plane casting a shadow onto itself, and the acne that produces
  /// is the commonest reason a scene looks dirty for no visible cause.
  final bool castShadows;

  /// Whether shadows land on this object.
  final bool receiveShadows;

  /// Whether it is drawn at all.
  ///
  /// Hidden is not deleted: the object keeps its key and its mesh stays
  /// loaded, so showing it again costs a flag rather than a parse.
  final bool visible;

  /// Which group of the scene this belongs to, from 0 to
  /// [OrbisScene.maxLayer].
  ///
  /// What lets one scene serve several passes. A pass draws the layers it
  /// names and no others, so the water can be left out of its own reflection,
  /// the editor's gizmos out of a thumbnail, and a stand-in for an
  /// off-screen object into a shadow pass and nowhere else.
  ///
  /// Zero for everything until somebody says otherwise, and a pass draws every
  /// layer until it says otherwise, so a scene that has never heard of layers
  /// behaves exactly as it did.
  final int layer;

  /// The flag bits this object contributes to the message.
  ///
  /// The layer rides in the high bits rather than in an array of its own: it
  /// is three bits per object, and a parallel array of them would be a fourth
  /// buffer allocated, packed and crossed every frame to carry a byte.
  int get _flags =>
      (castShadows ? 1 : 0) |
      (receiveShadows ? 2 : 0) |
      (visible ? 4 : 0) |
      (layer.clamp(0, OrbisScene.maxLayer) << 8);
}

/// The kinds of light a renderer actually implements.
///
/// Shorter than the list an artist works with, but no longer shorter by one:
/// a rectangle is here because a rectangle is what most real light comes from
/// — a window, a softbox, a strip in a ceiling — and approximating one with a
/// point puts the highlight in the wrong shape, which is the part of the image
/// somebody actually reads the light from.
enum OrbisLightKind {
  /// Parallel rays from infinitely far away, in lux. Filament honours one per
  /// scene, so a second is reported back rather than quietly ignored.
  directional,

  /// Radiates in every direction from a point, in lumens.
  point,

  /// A cone, in lumens.
  spot,

  /// A rectangle that emits from one face, in lumens.
  ///
  /// Not a Filament light: Filament has none, so this one is shaded by the
  /// surface material itself, against a fitted table that gives the rectangle
  /// a closed-form answer. The consequences of being outside Filament's own
  /// lighting are worth stating plainly: an area light casts no shadow, and
  /// it does not count against the punctual budget because it never becomes
  /// a punctual light.
  ///
  /// [OrbisLight.direction] is the face it emits from, [OrbisLight.tangent]
  /// the edge [OrbisLight.width] is measured along, and the height runs along
  /// the two crossed together. The back face emits nothing.
  area,
}

/// A light, in the units a renderer takes.
///
/// Watts, metres and degrees belong upstream in `orbis_light`, where an
/// artist's numbers are converted once. What arrives here is already
/// photometric, because a renderer that converts as well is a second place for
/// the conversion to be wrong.
class OrbisLight {
  OrbisLight({
    required this.key,
    required this.kind,
    required this.intensity,
    Vector3? colour,
    Vector3? position,
    Vector3? direction,
    this.falloffRadius = 10,
    this.innerConeAngle = 0.5,
    this.outerConeAngle = 0.6,
    this.sunAngularRadius = 0.263,
    this.sourceRadius = 0.1,
    this.haloSize = 10,
    this.haloFalloff = 80,
    this.castShadows = true,
    this.width = 1,
    this.height = 1,
    Vector3? tangent,
  }) : colour = colour ?? Vector3(1, 1, 1),
       position = position ?? Vector3.zero(),
       direction = direction ?? Vector3(0, -1, 0),
       tangent = tangent ?? Vector3(1, 0, 0);

  /// This light's identity, stable for as long as it exists. Keys share one
  /// space with [OrbisObject.key]: one number, one thing in the scene.
  final int key;

  final OrbisLightKind kind;

  /// Linear RGB.
  final Vector3 colour;

  /// Lux for a directional light; lumens for a point or a spot.
  final double intensity;

  /// Where the light is. Meaningless for a directional light, which is
  /// everywhere at once.
  final Vector3 position;

  /// The direction light travels, not the direction of the source in the sky.
  final Vector3 direction;

  /// Metres past which the light is ignored. A directional light does not fall
  /// off, so it has no influence radius.
  final double falloffRadius;

  /// Radians. Full brightness within the inner angle, falling to nothing at
  /// the outer one.
  final double innerConeAngle;
  final double outerConeAngle;

  /// Half the sun's angular diameter, in degrees.
  ///
  /// Why an outdoor shadow is crisp at your feet and soft at its far end.
  /// Zero is the quickest way to make a scene look computer-generated.
  final double sunAngularRadius;

  /// The radius of the emitting source in metres, which decides how wide a
  /// penumbra it casts.
  final double sourceRadius;

  /// The glow around the disk a directional light draws in the sky, and how
  /// quickly it fades.
  ///
  /// Only a directional light has a body to draw. Wide and soft reads as a sun
  /// seen through air; tight and small reads as a moon on a clear night, which
  /// is most of what tells the two apart at a glance.
  final double haloSize;
  final double haloFalloff;

  final bool castShadows;

  /// The rectangle's size in metres, for [OrbisLightKind.area]. Width is
  /// measured along [tangent] and height along the direction crossed with it.
  ///
  /// Size is not brightness. [intensity] is the lumens the panel emits, so
  /// making it bigger spreads the same light over more of the scene and
  /// softens its shadow terminator rather than making the room brighter —
  /// which is what somebody moving a softbox expects, and the opposite of
  /// what scaling a point light does.
  final double width;
  final double height;

  /// The edge [width] is measured along, for [OrbisLightKind.area].
  ///
  /// A rectangle needs this and [direction] both: the face alone leaves the
  /// panel free to spin in its own plane, and a strip light spun ninety
  /// degrees is a different light. Squared up against [direction] on the way
  /// through, so it only has to be roughly right.
  final Vector3 tangent;

  /// Writes this light's floats into the scene's light block.
  ///
  /// A fixed stride rather than one array per field: the whole scene is one
  /// channel message, and sixteen floats per light costs less than eleven more
  /// typed arrays to allocate, encode and check.
  void _pack(Float32List into, int at) {
    into[at] = colour.x;
    into[at + 1] = colour.y;
    into[at + 2] = colour.z;
    into[at + 3] = intensity;
    into[at + 4] = position.x;
    into[at + 5] = position.y;
    into[at + 6] = position.z;
    into[at + 7] = direction.x;
    into[at + 8] = direction.y;
    into[at + 9] = direction.z;
    into[at + 10] = falloffRadius;
    into[at + 11] = innerConeAngle;
    into[at + 12] = outerConeAngle;
    into[at + 13] = sunAngularRadius;
    into[at + 14] = sourceRadius;
    into[at + 15] = haloSize;
    into[at + 16] = haloFalloff;
    into[at + 17] = width;
    into[at + 18] = height;
    into[at + 19] = tangent.x;
    into[at + 20] = tangent.y;
    into[at + 21] = tangent.z;
  }

  /// How many floats one light occupies.
  static const int stride = 22;
}

/// Where the viewer is, and how much light reaches it.
class OrbisCamera {
  const OrbisCamera({
    required this.position,
    required this.target,
    this.fieldOfView = 50,
    this.orthographic = false,
    this.viewHeight = 10,
    this.aperture = 16,
    this.shutterSpeed = 1 / 125,
    this.sensitivity = 100,
  });

  final Vector3 position;
  final Vector3 target;

  /// Whether parallel lines stay parallel.
  ///
  /// What a game seen flat on needs, and not the same as a very long lens:
  /// perspective at a narrow angle still converges, so a sprite at the edge of
  /// the frame is still seen slightly from the side — which is exactly what
  /// art drawn face on must not do.
  final bool orthographic;

  /// How much of the world fits in the frame from top to bottom, in metres.
  ///
  /// The flat lens's answer to a field of view, and a separate number because
  /// an angle means nothing without a distance and a flat lens has none.
  /// Ignored when the camera has perspective.
  final double viewHeight;

  /// Vertical field of view in degrees.
  final double fieldOfView;

  /// The three settings that decide how much light gets in: the f-number, the
  /// shutter speed in seconds, and the sensitivity in ISO.
  ///
  /// The defaults are sunny sixteen — what a camera is set to outdoors at
  /// midday. A scene lit by anything dimmer has to say so, because the range
  /// between a night and a noon is about seventeen stops and no single setting
  /// covers both.
  final double aperture;
  final double shutterSpeed;
  final double sensitivity;

  /// The same camera somewhere else, keeping how it is set.
  OrbisCamera copyWith({
    Vector3? position,
    Vector3? target,
    double? fieldOfView,
    bool? orthographic,
    double? viewHeight,
    double? aperture,
    double? shutterSpeed,
    double? sensitivity,
  }) => OrbisCamera(
    position: position ?? this.position,
    target: target ?? this.target,
    fieldOfView: fieldOfView ?? this.fieldOfView,
    orthographic: orthographic ?? this.orthographic,
    viewHeight: viewHeight ?? this.viewHeight,
    aperture: aperture ?? this.aperture,
    shutterSpeed: shutterSpeed ?? this.shutterSpeed,
    sensitivity: sensitivity ?? this.sensitivity,
  );
}

/// The sky, and the light it casts on everything.
///
/// One thing rather than two, because a backdrop that lights nothing reads as
/// a photograph behind the scene rather than the sky the scene stands under.
/// Without it, every shadow and every surface facing away from the sun renders
/// pure black.
/// How much work the sky is allowed to do.
///
/// A phone, a browser and a desktop are not the same machine, and the honest
/// way to span them is to say what the sky may cost rather than to draw a
/// different sky. Every tier draws the same thing; what changes is how finely
/// it is sampled, which shows as softer edges at a distance and nothing else.
///
/// Measured on an M4 Pro at 1656x1400, on a fair-weather sky filling most of
/// the frame — the worst case, since a scene with ground in it pays for the
/// ground's pixels instead.
enum SkyQuality {
  /// Eight steps through the cloud and two towards the light, with no
  /// erosion. For a phone, a browser, or anything sharing a frame with a lot
  /// else.
  lean(marchSteps: 8, lightSteps: 2, erosion: 2),

  /// Twelve and three, with erosion on what is near.
  fair(marchSteps: 12, lightSteps: 3, erosion: 0.6),

  /// Eighteen and three, with erosion wherever the detail would show.
  full(marchSteps: 18, lightSteps: 3, erosion: 0.35);

  const SkyQuality({
    required this.marchSteps,
    required this.lightSteps,
    required this.erosion,
  });

  /// How many samples are taken along a ray through the cloud. Nearly all of
  /// the cost is here.
  final int marchSteps;

  /// How many are taken towards the light at each of those, which is what
  /// puts a shadow on the underside of a cloud.
  final int lightSteps;

  /// How near a cloud has to be before it is bitten at the edges by finer
  /// noise. Above one is never.
  final double erosion;
}

class OrbisSky {
  OrbisSky({
    Vector3? colour,
    Vector3? zenith,
    Vector3? horizon,
    this.ambient = 28000,
    this.showBody = true,
    this.drawn = true,
    this.quality = SkyQuality.full,
    Vector3? bodyDirection,
    Vector3? bodyColour,
    this.bodySize = 0.0047,
    this.flash = 0,
    Vector3? flashDirection,
    this.flashSeed = 0,
    OrbisClouds? clouds,
  }) : colour = colour ?? Vector3(0.10, 0.12, 0.16),
       zenith = zenith ?? Vector3(0.05, 0.17, 0.48),
       horizon = horizon ?? Vector3(0.60, 0.74, 0.90),
       bodyDirection = bodyDirection ?? Vector3(0.35, 0.78, 0.52),
       bodyColour = bodyColour ?? Vector3(1.00, 0.96, 0.90),
       flashDirection = flashDirection ?? Vector3(0.0, 0.35, 1.0),
       clouds = clouds ?? OrbisClouds.none;

  /// Linear RGB. What the sky is worth as a light source, which is not the
  /// same question as what it looks like: this is the one colour the image
  /// based lighting is built from, and it is an average of a whole dome.
  final Vector3 colour;

  /// Linear RGB, straight up and along the ground.
  ///
  /// Two colours rather than one because the sky is not one colour. Overhead
  /// there is the least air to look through and it is deepest; at the horizon
  /// there is the most and it is nearly white. A single flat colour is the
  /// difference between a sky and a backdrop.
  final Vector3 zenith;
  final Vector3 horizon;

  /// How much light the sky casts, in lux. Roughly a tenth of the sun on a
  /// clear day, which is about the ratio outdoors.
  final double ambient;

  /// What the sky is allowed to cost.
  final SkyQuality quality;

  /// Whether there is a sky to draw at all.
  ///
  /// An interior has none, and a scene that does not draw one pays for none:
  /// the dome is the most expensive thing in a frame and it is skipped
  /// outright rather than drawn empty.
  final bool drawn;

  /// Whether whatever is lighting the scene is drawn in the sky as a disk.
  ///
  /// A sun nobody can see is a scene lit from a direction that has to be
  /// worked out from the shadows. The disk is drawn at the light's own colour
  /// and brightness, so a dim pale one reads as a moon without being a
  /// separate feature.
  final bool showBody;

  /// Which way the body is, what colour it is, and how wide it is in radians.
  ///
  /// The same direction the cloud is lit from, which is the point of having
  /// it here: a sun drawn in one place and a cloud lit from another is the
  /// single thing that gives a sky away.
  final Vector3 bodyDirection;
  final Vector3 bodyColour;
  final double bodySize;

  /// A strike, this instant: how bright, which way, and which strike.
  ///
  /// The seed is what the bolt is drawn from, so one strike is a different
  /// shape from the next and the same shape whenever that instant is played
  /// again.
  final double flash;
  final Vector3 flashDirection;
  final double flashSeed;

  /// The layer of cloud in it.
  ///
  /// Held by the sky rather than beside it, because a cloud is a thing the
  /// sky has: it is lit by the sky's own body, it covers the sky's own
  /// gradient, and drawing either without the other is what made the last
  /// two attempts read as wallpaper.
  final OrbisClouds clouds;

  /// Everything the sky is drawn from, in one array.
  ///
  /// The gradient, the body, the cloud and the strike travel together because
  /// they are drawn together: one pass along one view ray, so the cloud can
  /// cover the sun, the sun can light the cloud, and a strike can light both.
  Float32List get packed {
    final body = bodyDirection.length2 > 0
        ? (bodyDirection.clone()..normalize())
        : Vector3(0, 1, 0);
    final strike = flashDirection.length2 > 0
        ? (flashDirection.clone()..normalize())
        : Vector3(0, 0, 1);

    return Float32List.fromList([
      zenith.x,
      zenith.y,
      zenith.z,
      horizon.x,
      horizon.y,
      horizon.z,
      body.x,
      body.y,
      body.z,
      bodyColour.x,
      bodyColour.y,
      bodyColour.z,
      bodySize,
      showBody ? 1 : 0,
      clouds.colour.x,
      clouds.colour.y,
      clouds.colour.z,
      clouds.cover,
      clouds.altitude,
      clouds.thickness,
      clouds.featureSize,
      clouds.density,
      clouds.billow,
      clouds.extinction,
      quality.marchSteps.toDouble(),
      quality.lightSteps.toDouble(),
      quality.erosion,
      clouds.wind.x,
      clouds.wind.y,
      flash,
      strike.x,
      strike.y,
      strike.z,
      flashSeed,
    ]);
  }

  /// How many floats the sky occupies.
  static const int stride = 34;
}

/// Air with something in it.
///
/// Distance and height are one setting because they are one effect: fog thick
/// enough to see across a valley is fog that pools in the valley, and having
/// the first without the second reads as a filter over the lens rather than as
/// weather.
class OrbisFog {
  OrbisFog({
    Vector3? colour,
    this.density = 0.05,
    this.distance = 0,
    this.cutOffDistance = double.infinity,
    this.maximumOpacity = 1,
    this.height = 0,
    this.heightFalloff = 1,
    this.structure = 0,
    Vector2? wind,
    this.featureSize = 0.02,
    this.thickness = 6,
  }) : colour = colour ?? Vector3(0.5, 0.55, 0.6),
       wind = wind ?? Vector2(0.4, 0.15);

  /// Nothing in the air, and cheap: the pass is switched off rather than run
  /// with a density of zero.
  static final OrbisFog none = OrbisFog(density: 0);

  /// Linear RGB.
  final Vector3 colour;

  /// How thick the air is, per metre.
  final double density;

  /// Metres in front of the camera where fog begins, so the thing being looked
  /// at is not veiled by the air between it and the lens.
  final double distance;

  /// Metres past which fog stops thickening. What keeps a sky visible through
  /// heavy weather instead of turning it into a wall.
  final double cutOffDistance;

  /// The most it can obscure, from zero to one.
  final double maximumOpacity;

  /// The world height the fog's own layer sits at.
  final double height;

  /// How quickly it thins going up. Larger is a shallower layer hugging the
  /// ground; zero is uniform at every height.
  final double heightFalloff;

  /// How much shape the air has, from none to a great deal.
  ///
  /// Even fog is right for distance and cannot look like anything in
  /// particular: every cubic metre of it is the same as every other. Above
  /// zero, the same air is also drawn as a stack of noise sheets, which is
  /// what gives it the shape of cloud lying along a valley. Zero costs
  /// nothing — the sheets are not drawn at all.
  final double structure;

  /// Which way the air is moving across the ground, and how fast, in metres
  /// a second.
  ///
  /// Sent as a speed rather than as a rate the pattern scrolls at, because
  /// only the renderer knows how big the pattern is — and wind that changed
  /// speed when somebody resized the clouds would be a setting that lies.
  final Vector2 wind;

  /// How large its features are: how much of a metre one turn of the noise
  /// covers. Smaller is bigger cloud.
  final double featureSize;

  /// How deep the bank is, in metres, above and below its height.
  final double thickness;

  bool get isVisible => density > 0 && maximumOpacity > 0;

  Float32List get _packed => Float32List.fromList([
    colour.x,
    colour.y,
    colour.z,
    density,
    distance,
    // Infinity survives the channel, but arithmetic on the other side turns it
    // into NaN rather than "far away", and a NaN in the fog makes the whole
    // frame vanish. A large finite stand-in keeps that maths well-behaved —
    // and, since the sky is drawn far beyond it, leaves the sky its own
    // colour rather than turning it into a wall of fog.
    cutOffDistance.isFinite ? cutOffDistance : 1e9,
    maximumOpacity,
    height,
    heightFalloff,
    structure,
    wind.x,
    wind.y,
    featureSize,
    thickness,
    0,
    0,
  ]);

  /// How many floats the fog occupies.
  static const int stride = 16;
}

/// The cloud in the sky.
///
/// Not the same thing as the fog, and worth keeping apart: fog is the air
/// between here and the horizon, and cloud is a layer a long way overhead
/// that the light comes through. A scene can have either without the other,
/// and a setting that did both would be wrong for every scene that wants one.
class OrbisClouds {
  const OrbisClouds({
    required this.colour,
    this.cover = 0,
    required this.wind,
    this.featureSize = 1 / 700,
    this.altitude = 900,
    this.thickness = 600,
    this.density = 1,
    this.billow = 0.85,
    this.extinction = 0.012,
  });

  /// A clear sky, and cheap: the layer is not marched at all.
  static final OrbisClouds none = OrbisClouds(
    colour: Vector3(0.17, 0.22, 0.33),
    wind: Vector2.zero(),
  );

  /// Fair-weather cumulus: flat bases at the condensation level, cauliflower
  /// tops, and a lot of blue between them. The default sky, and the one
  /// everybody pictures when they picture a cloud.
  factory OrbisClouds.cumulus({double cover = 0.35, Vector2? wind}) =>
      OrbisClouds(
        colour: Vector3(0.17, 0.22, 0.33),
        cover: cover,
        wind: wind ?? Vector2(4, 1.5),
      );

  /// The flatter, wider version: lumps that have run together into a layer
  /// with breaks in it rather than shapes with sky around them.
  factory OrbisClouds.stratocumulus({double cover = 0.6, Vector2? wind}) =>
      OrbisClouds(
        colour: Vector3(0.15, 0.19, 0.28),
        cover: cover,
        wind: wind ?? Vector2(5, 2),
        featureSize: 1 / 950,
        altitude: 700,
        thickness: 320,
        density: 0.85,
        billow: 0.5,
        extinction: 0.010,
      );

  /// The grey lid. Low, shallow and nearly featureless, which is why an
  /// overcast day has no shape to its sky and no shadows under it.
  factory OrbisClouds.stratus({double cover = 0.95, Vector2? wind}) =>
      OrbisClouds(
        colour: Vector3(0.14, 0.16, 0.21),
        cover: cover,
        wind: wind ?? Vector2(3, 1),
        featureSize: 1 / 1700,
        altitude: 480,
        thickness: 260,
        density: 0.75,
        billow: 0.08,
        extinction: 0.009,
      );

  /// Ice, seven kilometres up. Thin enough that the sun comes straight
  /// through it, and drawn out into streaks by a wind nothing slows down.
  factory OrbisClouds.cirrus({double cover = 0.4, Vector2? wind}) =>
      OrbisClouds(
        colour: Vector3(0.26, 0.32, 0.44),
        cover: cover,
        wind: wind ?? Vector2(16, 6),
        featureSize: 1 / 2600,
        altitude: 7000,
        thickness: 900,
        density: 0.22,
        billow: 0.3,
        extinction: 0.004,
      );

  /// The anvil. Deep enough that its own base is in its own shadow, which is
  /// the whole reason a storm sky is dark while the day around it is not.
  factory OrbisClouds.cumulonimbus({double cover = 0.85, Vector2? wind}) =>
      OrbisClouds(
        colour: Vector3(0.08, 0.09, 0.12),
        cover: cover,
        wind: wind ?? Vector2(9, 4),
        featureSize: 1 / 1200,
        altitude: 600,
        thickness: 2600,
        density: 1.25,
        billow: 0.7,
        extinction: 0.016,
      );

  /// Linear RGB: what the sky puts back into the side the sun does not reach.
  ///
  /// Not the colour of the cloud — a cloud has no colour of its own, it is
  /// white water lit by whatever reaches it. This is the blue that fills in
  /// the shadowed side, and it is why an underside reads as grey-blue rather
  /// than as black.
  final Vector3 colour;

  /// How much of the sky is covered, from nothing to everything.
  final double cover;

  /// What carries it across the sky, in metres a second.
  final Vector2 wind;

  /// Turns of the noise per metre: the reciprocal of how big a lump is.
  final double featureSize;

  /// How high the base hangs and how deep the layer is, in metres.
  ///
  /// Depth is what separates cloud from a painted ceiling. A layer with none
  /// can only be lit from one side; a layer with six hundred metres of it has
  /// a lit top, a shadowed base and an edge the light comes through.
  final double altitude;
  final double thickness;

  /// How solid it is where it is solid at all.
  final double density;

  /// How far the noise is folded, from a smooth sheet to a cauliflower.
  final double billow;

  /// How much light a metre of it takes out of a ray.
  final double extinction;

  bool get isVisible => cover > 0.01 && density > 0;

  OrbisClouds copyWith({
    Vector3? colour,
    double? cover,
    Vector2? wind,
    double? featureSize,
    double? altitude,
    double? thickness,
    double? density,
    double? billow,
    double? extinction,
  }) => OrbisClouds(
    colour: colour ?? this.colour,
    cover: cover ?? this.cover,
    wind: wind ?? this.wind,
    featureSize: featureSize ?? this.featureSize,
    altitude: altitude ?? this.altitude,
    thickness: thickness ?? this.thickness,
    density: density ?? this.density,
    billow: billow ?? this.billow,
    extinction: extinction ?? this.extinction,
  );
}

/// Water or snow on its way down.
///
/// One description for both, because they are the same thing at different
/// speeds: a field of drops falling and being blown sideways. What separates
/// them is [stretch] — how far a drop travels while the shutter is open, which
/// is the difference between a streak and a flake.
class OrbisPrecipitation {
  OrbisPrecipitation({
    Vector3? colour,
    this.amount = 0,
    this.fall = 9,
    Vector2? wind,
    this.dropsPerMetre = 6,
    this.stretch = 26,
    this.threshold = 0.72,
  }) : colour = colour ?? Vector3(0.72, 0.78, 0.86),
       wind = wind ?? Vector2.zero();

  /// Dry weather, and cheap: the curtains are not drawn at all.
  static final OrbisPrecipitation none = OrbisPrecipitation(amount: 0);

  /// Linear RGB.
  final Vector3 colour;

  /// How much of it there is, from nothing to a downpour.
  final double amount;

  /// Metres a second, downwards. Rain falls at about nine; snow at under one.
  final double fall;

  /// What carries it sideways, in metres a second.
  final Vector2 wind;

  /// How many drops there are in a metre.
  final double dropsPerMetre;

  /// How far a drop is smeared along its fall. One is a flake; forty is rain
  /// caught in a headlight.
  final double stretch;

  /// How much of the field is drop rather than air. Higher is sparser.
  final double threshold;

  bool get isVisible => amount > 0;

  Float32List get _packed => Float32List.fromList([
    colour.x,
    colour.y,
    colour.z,
    amount,
    fall,
    wind.x,
    wind.y,
    dropsPerMetre,
    stretch,
    threshold,
    0,
    0,
  ]);

  /// How many floats the weather on its way down occupies.
  static const int stride = 12;
}

/// Everything the renderer needs for a frame.
///
/// Sent whole rather than as a diff. A message that describes the entire scene
/// cannot go stale: there is no state on the wire to fall out of step, and no
/// way for the renderer to believe nothing changed when something did — which
/// is a failure that looks exactly like a frozen viewport.
///
/// Whole on the wire and incremental in the renderer are not in tension. The
/// keys make the description addressable, so the far side can work out what
/// actually moved without being told, and pay only for that. Sending was never
/// the expensive half; tearing down every entity in the scene sixty times a
/// second was.
class OrbisScene {
  OrbisScene({
    required this.objects,
    required this.camera,
    List<OrbisLight>? lights,
    OrbisSky? sky,
    OrbisFog? fog,
    OrbisPrecipitation? precipitation,
    List<OrbisPopulation>? populations,
    List<OrbisSplats>? splats,
    List<OrbisMaterial>? materials,
    List<OrbisVideo>? videos,
    OrbisPostProcess? post,
    OrbisPipeline? pipeline,
    OrbisRenderGraph? graph,
    OrbisEnvironment? environment,
    List<OrbisProbe>? probes,
    OrbisField? field,
    List<OrbisEnvironmentVolume>? volumes,
    List<OrbisDecal>? decals,
    OrbisOutline? outline,
    this.batching = false,
    OrbisGodRays? godRays,
    List<OrbisDistortion>? distortions,
  }) : lights = lights ?? const [],
       decals = decals ?? const [],
       outline = outline ?? OrbisOutline.none,
       godRays = godRays ?? OrbisGodRays.off,
       distortions = distortions ?? const [],
       probes = probes ?? const [],
       volumes = volumes ?? const [],
       field = field ?? OrbisField.none,
       environment = environment ?? OrbisEnvironment.none,
       pipeline = pipeline ?? OrbisPipeline(),
       graph = graph ?? OrbisRenderGraph.standard(),
       materials = materials ?? const [],
       videos = videos ?? const [],
       post = post ?? OrbisPostProcess(),
       populations = populations ?? const [],
       splats = splats ?? const [],
       sky = sky ?? OrbisSky(),
       fog = fog ?? OrbisFog.none,
       precipitation = precipitation ?? OrbisPrecipitation.none;

  /// The same scene with something changed.
  ///
  /// A scene is stated whole every frame, which makes taking one somebody
  /// else built and altering one thing about it awkward — an editor putting a
  /// gizmo layer over a game's scene, a tool running somebody's scene through
  /// an effect to see what it does to it, a test rendering the same scene
  /// twice with one setting moved. All of those otherwise mean rebuilding a
  /// dozen fields by hand and quietly dropping the one that was added last.
  OrbisScene copyWith({
    List<OrbisObject>? objects,
    List<OrbisPopulation>? populations,
    List<OrbisSplats>? splats,
    List<OrbisLight>? lights,
    List<OrbisMaterial>? materials,
    List<OrbisVideo>? videos,
    OrbisCamera? camera,
    OrbisSky? sky,
    OrbisFog? fog,
    OrbisPrecipitation? precipitation,
    OrbisPipeline? pipeline,
    OrbisPostProcess? post,
    OrbisRenderGraph? graph,
    OrbisEnvironment? environment,
    List<OrbisProbe>? probes,
    OrbisField? field,
    List<OrbisEnvironmentVolume>? volumes,
    List<OrbisDecal>? decals,
    OrbisOutline? outline,
    bool? batching,
    OrbisGodRays? godRays,
    List<OrbisDistortion>? distortions,
  }) => OrbisScene(
    // The probes and the field used to be missing here, so any copy quietly
    // dropped them. Resolving the volumes copies every scene that has any,
    // which is how it was noticed.
    probes: probes ?? this.probes,
    godRays: godRays ?? this.godRays,
    distortions: distortions ?? this.distortions,
    field: field ?? this.field,
    volumes: volumes ?? this.volumes,
    batching: batching ?? this.batching,
    objects: objects ?? this.objects,
    populations: populations ?? this.populations,
    splats: splats ?? this.splats,
    lights: lights ?? this.lights,
    materials: materials ?? this.materials,
    videos: videos ?? this.videos,
    camera: camera ?? this.camera,
    sky: sky ?? this.sky,
    fog: fog ?? this.fog,
    precipitation: precipitation ?? this.precipitation,
    pipeline: pipeline ?? this.pipeline,
    post: post ?? this.post,
    graph: graph ?? this.graph,
    environment: environment ?? this.environment,
    decals: decals ?? this.decals,
    outline: outline ?? this.outline,
  );

  final List<OrbisObject> objects;

  /// The parts of the scene that are many copies of one thing.
  ///
  /// Kept apart from [objects] because they are a different question. An
  /// object is tracked one at a time; a population is submitted whole. Mixing
  /// them would mean either paying an object's price for every tree or losing
  /// an object's individuality for every one that needs it.
  final List<OrbisPopulation> populations;

  /// Clouds of 3D Gaussians: captured places, or generated ones.
  ///
  /// Apart from [objects] and [populations] because they are not surfaces.
  /// They are drawn after everything solid, sorted back to front among
  /// themselves, and hidden by anything solid in front of them.
  final List<OrbisSplats> splats;

  /// Every light in the scene. A scene with none is lit by its sky alone,
  /// which is dim and even and perfectly legitimate.
  final List<OrbisLight> lights;

  /// Every material any object in the scene is made of.
  ///
  /// Listed here rather than held on the objects because materials are shared
  /// and objects are not: a hundred crates made of the same wood are a
  /// hundred entries in [objects] and one entry here, and the renderer builds
  /// one shader instance for them all. Sending the list whole each frame also
  /// means a material can be edited — a slider dragged — without anything
  /// having to say which objects were affected.
  final List<OrbisMaterial> materials;

  /// Every video the scene is playing.
  ///
  /// Beside the materials rather than inside them, for the same reason: one
  /// film can be on four screens, and playing it four times would be four
  /// decoders doing identical work out of step with each other.
  final List<OrbisVideo> videos;

  final OrbisCamera camera;
  final OrbisSky sky;
  final OrbisFog fog;
  final OrbisPrecipitation precipitation;

  /// How much of the frame's work actually happens.
  ///
  /// On the scene rather than on the view, for the same reason the post
  /// settings are: four views of one world should be drawn to one standard.
  /// It is the tier a machine has been set to, not a property of a window.
  final OrbisPipeline pipeline;

  /// Everything done to the image after the scene is drawn.
  ///
  /// On the scene rather than on the camera, because a look belongs to the
  /// place rather than to where somebody is standing in it: four views of one
  /// world should not each grade it differently.
  final OrbisPostProcess post;

  /// How the frame is put together: which passes there are and what they draw
  /// into.
  ///
  /// [pipeline] says how much of each step happens; this says which steps
  /// there are. The default is one pass into the picture, which is the frame
  /// the renderer drew before graphs existed — so nothing pays for the
  /// generality until it is used.
  final OrbisRenderGraph graph;

  /// The place the scene is standing in, as light and as a backdrop.
  ///
  /// Overrules [sky]'s flat ambient while it is set: a scene lit by a
  /// photograph of a room and *also* by an even grey wash is a scene lit
  /// twice, and the wash is the half that flattens it. The sky's own colour
  /// and its body go on meaning what they meant.
  final OrbisEnvironment environment;

  /// The reflections captured from points inside the scene.
  ///
  /// The camera is inside one of these at a time, and that one lights the
  /// scene in place of [environment]. A scene with none is lit by its
  /// environment as before, which is why adding probes to an existing scene
  /// changes nothing until one of them contains the camera.
  final List<OrbisProbe> probes;

  /// The light kept in the world rather than on the screen.
  ///
  /// Off by default, and free when off: a scene that never mentions one is
  /// lit exactly as it was.
  final OrbisField field;

  /// The regions of the world that look different from the rest of it — a
  /// dim hall off a sunny courtyard, a foggy cave.
  ///
  /// Resolved against [camera] when the scene is sent: the fog, sky,
  /// environment, exposure and grade that go over the channel are this
  /// scene's own, moved towards whatever the volumes around the camera ask
  /// for. The renderer never sees a volume, so none of this is native code.
  /// See [resolved] for the scene that is actually drawn.
  final List<OrbisEnvironmentVolume> volumes;

  /// Shafts of light from the scene's directional light, through whatever
  /// stands against the sky. Off by default, and free when off.
  final OrbisGodRays godRays;

  /// Air that bends the light through it: shockwaves, heat haze, a lens.
  /// None by default, and free when none of them moves anything.
  final List<OrbisDistortion> distortions;

  /// The light god rays come from: the first directional one, which is the
  /// one the renderer draws.
  OrbisLight? get _sun => lights
      .where((light) => light.kind == OrbisLightKind.directional)
      .firstOrNull;

  /// The graph the renderer is actually sent: [graph], with the passes for
  /// [godRays] and [distortions] put in when the graph is the renderer's own
  /// and something asks for them. See [OrbisRenderGraph.withScreenEffects].
  OrbisRenderGraph get drawnGraph => graph.withScreenEffects(
    godRays: godRays.isOn && _sun != null,
    distortion: distortions.any((one) => one.isActive),
  );

  /// This scene as it looks from [at] — the camera's position unless said
  /// otherwise — with every volume applied and none left in it.
  ///
  /// What [toMessage] sends. Public because a host wants to ask the same
  /// question: what the fog is where the player is standing, to decide
  /// whether to play the echoey footsteps.
  OrbisScene resolved([Vector3? at]) {
    if (volumes.isEmpty) return this;
    return OrbisEnvironmentSettings.of(
      this,
    ).resolve(volumes, at ?? camera.position).applyTo(this);
  }

  /// What is painted onto the surfaces: posters, scorches, puddles, road
  /// markings. Each one a box and a picture, projected onto whatever lit
  /// surface is inside the box before it is lit.
  ///
  /// The first [OrbisDecal.budget] are painted; the renderer reports any past
  /// that rather than dropping them without a word.
  final List<OrbisDecal> decals;

  /// Which objects have a line drawn round them, and how.
  ///
  /// On the scene rather than on the objects because it is about the view of
  /// the world rather than the world: a game never sets it, and an editor
  /// changes it on every click without touching a single object. Nothing is
  /// outlined until somebody says otherwise, and nothing is paid for until
  /// then either.
  final OrbisOutline outline;

  /// Whether objects that are the same thing are drawn together.
  ///
  /// A hundred crates with one mesh, one material and the same shadow and
  /// layer settings are a hundred draws per pass without this, and one with
  /// it: the renderer builds the group as a single renderable, manually
  /// instanced — each copy's own transform in its own slot of a buffer built
  /// for the purpose — rather than drawing each crate on its own. A group
  /// past sixty-four members becomes more than one such renderable, because
  /// that is as many copies as one can carry, but it is still a handful of
  /// draws rather than one per crate. Nothing about the objects themselves
  /// changes — each is still its own entry in [objects] with its own key,
  /// moving one moves only that one, and picking still answers with the one
  /// that was clicked, because picking never asks the renderer which entity
  /// is at a pixel; it works from this list, same as ever.
  ///
  /// What batches is decided per publish, by counting. Four or more objects
  /// with the same [OrbisObject.mesh], the same [OrbisObject.material] and the
  /// same flags form a group; a placeholder cube on the default surface also
  /// needs the same [OrbisObject.colour], because on that surface the colour
  /// *is* the material. An object with [OrbisObject.morphWeights] never
  /// batches, because its shape is its own, and neither does a model wearing
  /// its own file's materials, because every copy of a model comes with its
  /// own set of them — give such a model an [OrbisMaterial] and the census
  /// counts it like anything else, though the renderer does not yet build a
  /// merged draw for a named mesh, only for the placeholder cube; such a
  /// model still draws correctly, just as its own renderable, unmerged.
  ///
  /// **What this costs.** A merged group shares everything in Filament that
  /// is set per renderable rather than per instance: the shadow and layer
  /// flags (already guaranteed identical within a group by what makes a
  /// group) and, more visibly, culling. Filament culls a renderable by one
  /// box, so a group's box is the union of its members' — up to sixty-four
  /// of them — and a member outside the camera's view still draws if another
  /// member of its own chunk of sixty-four is inside it. The same is true of
  /// the shadow pass: a member outside the light's view can still cast if a
  /// chunk-mate is inside it. Neither ever *hides* something that should be
  /// visible or shadowing — the union box can only be a superset of what a
  /// member-by-member account would cull — so the cost is some wasted
  /// drawing at the edge of a chunk, not a wrong picture. Members are sorted
  /// by where they are in the world before being split into chunks of
  /// sixty-four, precisely so that a chunk is a compact patch rather than
  /// members scattered across the whole group, which keeps this cost small
  /// in practice: a scene with objects that are already laid out somewhat
  /// together — a grid, a cluster, a tile — pays very little for it.
  ///
  /// **On, but only where proven.** Measured on three thousand crates: a
  /// third of the CPU time and GPU time of drawing them unbatched, and the
  /// draw count falls from thousands to dozens. Where nothing in a scene
  /// batches — nothing repeats often enough, or every copy differs in colour
  /// or material — turning this on changes nothing, measured to the pixel:
  /// there is nothing to merge, so nothing is drawn differently.
  ///
  /// Where something *does* batch, and none of it casts shadows, the same is
  /// true: measured bit-identical on three thousand crates grouped without a
  /// caster among them, and on forty-eight overlapping slabs sharing one
  /// material. Where a batched group also casts shadows — crates in a
  /// pattern, one in five, is the case this was measured on — the frame is
  /// close but not bit-identical: with the clock pinned, 2.27% of pixels
  /// differ, by 2.6 parts in 255 on average, along the edges of shadows
  /// rather than scattered across every silhouette or missing from a whole
  /// object. Two runs of the same frame are bit-identical, so that is a real
  /// difference and not noise. Turning the shadow pass off makes it vanish,
  /// which is what places it there.
  ///
  /// **It is the group's box, and now only the group's box.** This comment
  /// used to say the difference was 2.97%, and that the bounding box had been
  /// ruled out because shrinking a group to one member still left 2.75%
  /// behind. The test was sound and the conclusion was wrong, because the
  /// thing it was compared against was itself wrong: the placeholder cube
  /// declared a box that did not contain it — Filament's `Box` is a centre
  /// and a half-extent, and the declaration was a {min,max} pair — so the
  /// *unbatched* side was fitting its shadows from the wrong volume, and no
  /// amount of shrinking a chunk could reveal that. With the declaration
  /// corrected, one member to a chunk differs by 0.0055%: a hundred and six
  /// pixels, every one of them by a single level, which is the float rounding
  /// left in recovering a chunk's half-extent from the union of its members'.
  /// The two paths agree.
  ///
  /// What is left at sixty-four members is the grouping, behaving as a union
  /// of boxes should: a chunk's box is looser along the light axis than any
  /// member's, so the shadow camera fits a deeper volume and the map's texels
  /// land differently. It saturates immediately — eight members to a chunk
  /// measures 2.22% against sixty-four's 2.27% — so no chunk size buys the
  /// difference back while still batching anything.
  ///
  /// So this stays off by default, but the trade is now a named one: a
  /// bounded difference at the edges of shadows, against three thousand
  /// renderables where fifty-one would do. Turning it on is safe in the
  /// sense that mattered most: it no longer touches the Filament feature
  /// that used to blacken a frame outright (see below), so the worst this
  /// can now do is a scattering of pixels near a shadow's edge, never a
  /// black screen. A scene where nothing batched casts a shadow stays
  /// bit-identical.
  ///
  /// **Not Filament's automatic instancing, and deliberately so.** An
  /// earlier version of this switched on `Engine::setAutomaticInstancingEnabled`
  /// and let Filament notice, after the fact, that several draws it had
  /// already built could be merged. On stock Filament 1.76 that path is
  /// broken: `RenderPass::instanceify()` compares a leftover custom command
  /// as though it were a draw, and can fold the colour-grading subpass into
  /// a neighbouring instanced run so it never executes — the whole frame
  /// comes back entirely black, on some scenes and not others, with no way
  /// to tell beforehand which a given scene is. Building the merged
  /// renderable directly, with `RenderableManager::Builder::instances`,
  /// never asks Filament to notice anything after the fact, so that bug is
  /// never reached — which is what let three scenes that used to come back
  /// black with instancing forced on render correctly once batching stopped
  /// asking for it. A fix for the underlying Filament bug exists, on Orbis's
  /// own Filament fork, in no release yet; it no longer matters to this
  /// switch, because nothing here depends on it any more.
  ///
  /// Turned off with `batching: false`, which is also what leaving this
  /// unset does.
  final bool batching;

  /// The highest layer an object may be on.
  ///
  /// Seven of them, because the renderer's own mask is eight bits and the
  /// top one says whether a thing is drawn at all. Seven groups is more
  /// than any scene here has wanted and few enough to stay one byte.
  static const int maxLayer = 6;

  /// The names of the passes that will run, in order.
  ///
  /// What a capture's timings line up against: the renderer sends back two
  /// numbers per pass and this says which pass each pair belongs to, so the
  /// names never have to cross.
  List<String> get passNames => [
    for (final pass in drawnGraph.schedule) pass.name,
  ];

  /// Packs the scene into the flat arrays the channel carries.
  /// The whole scene, as the renderer takes it.
  ///
  /// [sentRevisions] is what the renderer already holds for each population,
  /// so that buffers it already has are left out. Passing null sends
  /// everything, which is what a fresh renderer needs.
  Map<String, Object> toMessage(
    int textureId, {
    Map<int, int>? sentRevisions,
    Map<int, int>? sentSplatRevisions,
    double? at,
  }) {
    // Volumes are resolved here, where the scene is packed, so that every
    // host gets them without calling anything and the message stays the
    // shape the renderer already reads.
    if (volumes.isNotEmpty) {
      return resolved().toMessage(
        textureId,
        sentRevisions: sentRevisions,
        at: at,
      );
    }

    final count = objects.length;
    final keys = Int64List(count);
    final transforms = Float32List(count * 16);
    final colours = Float32List(count * 3);
    final meshes = Int32List(count);
    final flags = Int32List(count);
    final objectMaterials = Int32List(count);

    // Materials are referred to by their position in this frame's list, so
    // the renderer never has to search. Keys are what survive between frames;
    // indices are what travel in one.
    final materialAt = <int, int>{};
    for (var i = 0; i < materials.length; i++) {
      materialAt[materials[i].key] = i;
    }

    // Morph weights, packed end to end with a count each rather than a fixed
    // width per object. A face rig has dozens and a crate has none, and a
    // width that suits both is a width that is wrong for both.
    final morphCounts = Int32List(count);
    final allWeights = <double>[];

    // Paths are sent once and referred to by index, because the same mesh is
    // usually on many objects and the message goes over the channel on every
    // frame of a drag.
    final paths = <String>[];
    final indices = <String, int>{};

    for (var i = 0; i < count; i++) {
      final object = objects[i];
      final mesh = object.mesh;
      keys[i] = object.key;
      meshes[i] = mesh == null
          ? -1
          : indices.putIfAbsent(mesh, () {
              paths.add(mesh);
              return paths.length - 1;
            });
      flags[i] = object._flags;
      final material = object.material;
      objectMaterials[i] = material == null ? -1 : (materialAt[material] ?? -1);
      // Matrix4's storage is already column-major, which is what Filament's
      // mat4f expects, so this copies rather than transposes.
      transforms.setRange(i * 16, i * 16 + 16, object.transform.storage);
      colours[i * 3] = object.colour.x;
      colours[i * 3 + 1] = object.colour.y;
      colours[i * 3 + 2] = object.colour.z;

      final weights = object.morphWeights;
      if (weights != null && weights.isNotEmpty) {
        morphCounts[i] = weights.length;
        allWeights.addAll(weights);
      }
    }

    // Never empty, because the far side takes a pointer and an empty typed
    // list has none to give.
    final morphWeights = Float32List.fromList(
      allWeights.isEmpty ? const [0.0] : allWeights,
    );

    // The probes, packed the same way as everything else: keys in one array
    // and a fixed stride of floats in another, so the renderer walks them
    // without matching a single string.
    final probeKeys = Int64List(probes.length);
    final probeParams = Float32List(probes.length * OrbisProbe.stride);
    for (var i = 0; i < probes.length; i++) {
      probeKeys[i] = probes[i].key;
      probes[i].pack(probeParams, i * OrbisProbe.stride);
    }

    final materialCount = materials.length;
    final materialKeys = Int64List(materialCount);
    final materialFlags = Int32List(materialCount);
    final materialParams = Float32List(materialCount * OrbisMaterial.stride);
    final materialMaps = Int32List(materialCount * OrbisMaterial.mapCount);
    final materialVideos = Int32List(materialCount);

    final videoAt = <int, int>{};
    for (var i = 0; i < videos.length; i++) {
      videoAt[videos[i].key] = i;
    }

    // The same trick as mesh paths: an image is usually on several materials
    // and always on several frames, so it travels once and is pointed at.
    final texturePaths = <String>[];
    final textureSrgb = <int>[];
    final textureAt = <OrbisTexture, int>{};

    for (var i = 0; i < materialCount; i++) {
      final material = materials[i];
      materialKeys[i] = material.key;
      materialFlags[i] = material.flags;
      material.pack(materialParams, i * OrbisMaterial.stride);
      final video = material.video;
      materialVideos[i] = video == null ? -1 : (videoAt[video] ?? -1);
      final maps = material.maps;
      for (var m = 0; m < OrbisMaterial.mapCount; m++) {
        final map = maps[m];
        materialMaps[i * OrbisMaterial.mapCount + m] = map == null
            ? -1
            : textureAt.putIfAbsent(map, () {
                texturePaths.add(map.path);
                textureSrgb.add(map.srgb ? 1 : 0);
                return texturePaths.length - 1;
              });
      }
    }

    final videoCount = videos.length;
    final videoKeys = Int64List(videoCount);
    final videoFlags = Int32List(videoCount);
    final videoParams = Float32List(videoCount * OrbisVideo.stride);
    final videoPaths = <String>[];
    for (var i = 0; i < videoCount; i++) {
      final video = videos[i];
      videoKeys[i] = video.key;
      videoFlags[i] = video.flags;
      videoPaths.add(video.path);
      final at = i * OrbisVideo.stride;
      videoParams[at] = video.rate;
      videoParams[at + 1] = video.volume;
      // Negative for "no seek asked for", so a token that has moved with no
      // target is a no-op rather than a jump to the start.
      videoParams[at + 2] = video.seekTo ?? -1;
      videoParams[at + 3] = video.seekToken.toDouble();
    }

    // Decals, with their pictures sent once and pointed at, the same trick
    // as mesh paths and material maps.
    final decalParams = Float32List(decals.length * OrbisDecal.stride);
    final decalImages = Int32List(decals.length);
    final decalPaths = <String>[];
    final decalPathAt = <String, int>{};
    for (var i = 0; i < decals.length; i++) {
      final decal = decals[i];
      decal.pack(decalParams, i * OrbisDecal.stride);
      final texture = decal.texture;
      decalImages[i] = texture == null
          ? -1
          : decalPathAt.putIfAbsent(texture.path, () {
              decalPaths.add(texture.path);
              return decalPaths.length - 1;
            });
    }
    final drawn = drawnGraph;
    final sun = _sun;

    final lightCount = lights.length;
    final lightKeys = Int64List(lightCount);
    final lightKinds = Int32List(lightCount);
    final lightFlags = Int32List(lightCount);
    final lightParams = Float32List(lightCount * OrbisLight.stride);

    for (var i = 0; i < lightCount; i++) {
      final light = lights[i];
      lightKeys[i] = light.key;
      lightKinds[i] = light.kind.index;
      lightFlags[i] = light.castShadows ? 1 : 0;
      light._pack(lightParams, i * OrbisLight.stride);
    }

    return {
      'textureId': textureId,
      'objectKeys': keys,
      'transforms': transforms,
      'colours': colours,
      'meshes': meshes,
      'objectFlags': flags,
      'objectMorphCounts': morphCounts,
      'objectMorphWeights': morphWeights,
      'meshPaths': paths,
      'objectMaterials': objectMaterials,
      'batching': batching,
      'materialKeys': materialKeys,
      'materialFlags': materialFlags,
      'materialParams': materialParams,
      'materialMaps': materialMaps,
      'materialVideos': materialVideos,
      'videoKeys': videoKeys,
      'videoFlags': videoFlags,
      'videoParams': videoParams,
      'videoPaths': videoPaths,
      'texturePaths': texturePaths,
      'textureSrgb': Int32List.fromList(textureSrgb),
      'lightKeys': lightKeys,
      'lightKinds': lightKinds,
      'lightFlags': lightFlags,
      'lightParams': lightParams,
      'cameraPosition': _vector(camera.position),
      'cameraTarget': _vector(camera.target),
      'fieldOfView': camera.fieldOfView,
      'orthographic': camera.orthographic,
      'viewHeight': camera.viewHeight,
      'aperture': camera.aperture,
      'shutterSpeed': camera.shutterSpeed,
      'sensitivity': camera.sensitivity,
      'skyColour': _vector(sky.colour),
      'ambient': sky.ambient,
      'showBody': sky.showBody,
      'skyParams': sky.packed,
      'fogEnabled': fog.isVisible,
      'fogParams': fog._packed,
      'precipitationEnabled': precipitation.isVisible,
      'precipitationParams': precipitation._packed,
      'skyEnabled': sky.drawn,
      'postParams': post.packed,
      'pipelineParams': pipeline.packed,
      'decalParams': decalParams,
      'decalImages': decalImages,
      'decalPaths': decalPaths,
      'probeKeys': probeKeys,
      'probeParams': probeParams,
      'fieldParams': field.packed,
      'fieldFrom': field.from,
      'environmentRadiance': environment.radiance ?? '',
      'environmentSkybox': environment.skybox ?? '',
      'environmentParams': environment.packed,
      'graphPasses': drawn.packedPasses,
      'graphTargets': drawn.packedTargets,
      'graphTargetNames': [for (final target in drawn.targets) target.name],
      'outlineKeys': outline.packedKeys,
      'outlineParams': outline.packed,
      // The shafts' settings, with the light they come from and the cloud in
      // front of it worked out here, where the scene is whole. Cloud only
      // counts when the sky that carries it is drawn.
      'godRayParams': godRays.pack(
        towardLight: sun == null ? null : -sun.direction,
        lightColour: sun?.colour,
        cloudCover: sky.drawn && sky.clouds.isVisible ? sky.clouds.cover : 0,
      ),
      'distortionParams': OrbisDistortion.packAll(distortions),
      // When the application reckons this is, in its own seconds.
      //
      // The renderer draws far more often than it is told anything, and works
      // out where the camera is in between. Doing that from when the messages
      // *arrived* uses a clock with jitter in it, and dividing by a jittery
      // gap turns a small timing wobble into a large wrong speed. This is the
      // clock the camera was actually solved on.
      'at': at ?? 0.0,
      ...?_populationMessage(sentRevisions),
      ...?_splatMessage(sentSplatRevisions),
    };
  }

  /// What the renderer needs to know about the splat clouds.
  ///
  /// Absent altogether when there are none, so every scene that never uses
  /// them sends exactly what it sent before. The records of an in-memory
  /// cloud travel only when its revision is not the one the renderer holds —
  /// [sent] — for the same reason a population's transforms do.
  Map<String, Object>? _splatMessage(Map<int, int>? sent) {
    if (splats.isEmpty) return null;

    final count = splats.length;
    final keys = Int32List(count);
    final flags = Int32List(count);
    final revisions = Int32List(count);
    final params = Float32List(count * OrbisSplats.stride);
    final paths = <String>[];
    final changed = <OrbisSplats>[];
    var bytes = 0;

    for (var i = 0; i < count; i++) {
      final cloud = splats[i];
      keys[i] = cloud.key;
      flags[i] = cloud.flags;
      revisions[i] = cloud.revision;
      cloud.packParams(params, i * OrbisSplats.stride);
      paths.add(cloud.path ?? '');
      final data = cloud.data;
      if (data != null && (sent == null || sent[cloud.key] != cloud.revision)) {
        changed.add(cloud);
        bytes += data.length;
      }
    }

    final data = Uint8List(bytes);
    final changedKeys = Int32List(changed.length);
    final changedCounts = Int32List(changed.length);
    var at = 0;
    for (var i = 0; i < changed.length; i++) {
      final records = changed[i].data!;
      changedKeys[i] = changed[i].key;
      changedCounts[i] = changed[i].count;
      data.setRange(at, at + records.length, records);
      at += records.length;
    }

    return {
      'splatKeys': keys,
      'splatFlags': flags,
      'splatRevisions': revisions,
      'splatParams': params,
      'splatPaths': paths,
      'splatChanged': changedKeys,
      'splatChangedCounts': changedCounts,
      'splatData': data,
    };
  }

  /// What the renderer needs to know about the populations.
  ///
  /// The transforms and colours are left out for any population whose
  /// revision the renderer already has. That is the entire point: six
  /// megabytes of transforms is not something to send sixty times a second in
  /// order to say that nothing moved.
  Map<String, Object>? _populationMessage(Map<int, int>? sent) {
    if (populations.isEmpty) return null;

    final keys = Int32List(populations.length);
    final counts = Int32List(populations.length);
    final meshes = Int32List(populations.length);
    final flags = Int32List(populations.length);
    final revisions = Int32List(populations.length);
    final ranges = Float32List(populations.length);
    final bounds = Float32List(populations.length * 6);
    final paths = <String>[];

    // Only the ones that have changed, packed end to end. The renderer takes
    // them in the order the changed keys appear.
    final changed = <OrbisPopulation>[];
    var members = 0;

    for (var i = 0; i < populations.length; i++) {
      final population = populations[i];
      keys[i] = population.key;
      counts[i] = population.count;
      flags[i] = population.flags;
      revisions[i] = population.revision;
      ranges[i] = population.range;

      meshes[i] = -1;
      if (population.mesh != null) {
        meshes[i] = paths.indexOf(population.mesh!);
        if (meshes[i] < 0) {
          meshes[i] = paths.length;
          paths.add(population.mesh!);
        }
      }

      bounds[i * 6 + 0] = population.minimum.x;
      bounds[i * 6 + 1] = population.minimum.y;
      bounds[i * 6 + 2] = population.minimum.z;
      bounds[i * 6 + 3] = population.maximum.x;
      bounds[i * 6 + 4] = population.maximum.y;
      bounds[i * 6 + 5] = population.maximum.z;

      if (sent == null || sent[population.key] != population.revision) {
        changed.add(population);
        members += population.count;
      }
    }

    final transforms = Float32List(members * 16);
    final colours = Float32List(members * 3);
    final changedKeys = Int32List(changed.length);
    var atTransform = 0;
    var atColour = 0;

    for (var i = 0; i < changed.length; i++) {
      changedKeys[i] = changed[i].key;
      transforms.setRange(
        atTransform,
        atTransform + changed[i].transforms.length,
        changed[i].transforms,
      );
      colours.setRange(
        atColour,
        atColour + changed[i].colours.length,
        changed[i].colours,
      );
      atTransform += changed[i].transforms.length;
      atColour += changed[i].colours.length;
    }

    return {
      'populationKeys': keys,
      'populationCounts': counts,
      'populationMeshes': meshes,
      'populationFlags': flags,
      'populationRevisions': revisions,
      'populationRanges': ranges,
      'populationBounds': bounds,
      'populationPaths': paths,
      'populationChanged': changedKeys,
      'populationTransforms': transforms,
      'populationColours': colours,
    };
  }

  static Float32List _vector(Vector3 value) =>
      Float32List.fromList([value.x, value.y, value.z]);
}
