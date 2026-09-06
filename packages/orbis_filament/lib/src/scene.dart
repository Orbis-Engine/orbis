import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart';

import 'population.dart';

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
    this.castShadows = true,
    this.receiveShadows = true,
    this.visible = true,
  });

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

  /// The flag bits this object contributes to the message.
  int get _flags =>
      (castShadows ? 1 : 0) | (receiveShadows ? 2 : 0) | (visible ? 4 : 0);
}

/// The kinds of light a renderer actually implements.
///
/// Deliberately shorter than the list an artist works with. An area light is a
/// real thing to author and not a real thing to render here, so the package
/// that knows about watts and softboxes is the one that decides what an area
/// light becomes; this end only takes what Filament can be told.
enum OrbisLightKind {
  /// Parallel rays from infinitely far away, in lux. Filament honours one per
  /// scene, so a second is reported back rather than quietly ignored.
  directional,

  /// Radiates in every direction from a point, in lumens.
  point,

  /// A cone, in lumens.
  spot,
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
  }) : colour = colour ?? Vector3(1, 1, 1),
       position = position ?? Vector3.zero(),
       direction = direction ?? Vector3(0, -1, 0);

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
    into[at + 17] = 0;
  }

  /// How many floats one light occupies.
  static const int stride = 18;
}

/// Where the viewer is, and how much light reaches it.
class OrbisCamera {
  const OrbisCamera({
    required this.position,
    required this.target,
    this.fieldOfView = 50,
    this.aperture = 16,
    this.shutterSpeed = 1 / 125,
    this.sensitivity = 100,
  });

  final Vector3 position;
  final Vector3 target;

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
    double? aperture,
    double? shutterSpeed,
    double? sensitivity,
  }) => OrbisCamera(
    position: position ?? this.position,
    target: target ?? this.target,
    fieldOfView: fieldOfView ?? this.fieldOfView,
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
      zenith.x, zenith.y, zenith.z,
      horizon.x, horizon.y, horizon.z,
      body.x, body.y, body.z,
      bodyColour.x, bodyColour.y, bodyColour.z,
      bodySize,
      showBody ? 1 : 0,
      clouds.colour.x, clouds.colour.y, clouds.colour.z,
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
      clouds.wind.x, clouds.wind.y,
      flash,
      strike.x, strike.y, strike.z,
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
  }) : lights = lights ?? const [],
       populations = populations ?? const [],
       sky = sky ?? OrbisSky(),
       fog = fog ?? OrbisFog.none,
       precipitation = precipitation ?? OrbisPrecipitation.none;

  final List<OrbisObject> objects;

  /// The parts of the scene that are many copies of one thing.
  ///
  /// Kept apart from [objects] because they are a different question. An
  /// object is tracked one at a time; a population is submitted whole. Mixing
  /// them would mean either paying an object's price for every tree or losing
  /// an object's individuality for every one that needs it.
  final List<OrbisPopulation> populations;

  /// Every light in the scene. A scene with none is lit by its sky alone,
  /// which is dim and even and perfectly legitimate.
  final List<OrbisLight> lights;

  final OrbisCamera camera;
  final OrbisSky sky;
  final OrbisFog fog;
  final OrbisPrecipitation precipitation;

  /// Packs the scene into the flat arrays the channel carries.
  /// The whole scene, as the renderer takes it.
  ///
  /// [sentRevisions] is what the renderer already holds for each population,
  /// so that buffers it already has are left out. Passing null sends
  /// everything, which is what a fresh renderer needs.
  Map<String, Object> toMessage(
    int textureId, {
    Map<int, int>? sentRevisions,
    double? at,
  }) {
    final count = objects.length;
    final keys = Int64List(count);
    final transforms = Float32List(count * 16);
    final colours = Float32List(count * 3);
    final meshes = Int32List(count);
    final flags = Int32List(count);

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
      // Matrix4's storage is already column-major, which is what Filament's
      // mat4f expects, so this copies rather than transposes.
      transforms.setRange(i * 16, i * 16 + 16, object.transform.storage);
      colours[i * 3] = object.colour.x;
      colours[i * 3 + 1] = object.colour.y;
      colours[i * 3 + 2] = object.colour.z;
    }

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
      'meshPaths': paths,
      'lightKeys': lightKeys,
      'lightKinds': lightKinds,
      'lightFlags': lightFlags,
      'lightParams': lightParams,
      'cameraPosition': _vector(camera.position),
      'cameraTarget': _vector(camera.target),
      'fieldOfView': camera.fieldOfView,
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
      // When the application reckons this is, in its own seconds.
      //
      // The renderer draws far more often than it is told anything, and works
      // out where the camera is in between. Doing that from when the messages
      // *arrived* uses a clock with jitter in it, and dividing by a jittery
      // gap turns a small timing wobble into a large wrong speed. This is the
      // clock the camera was actually solved on.
      'at': at ?? 0.0,
      ...?_populationMessage(sentRevisions),
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
