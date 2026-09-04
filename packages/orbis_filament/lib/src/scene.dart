import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart';

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
    into[at + 15] = 0;
  }

  /// How many floats one light occupies.
  static const int stride = 16;
}

/// Where the viewer is.
class OrbisCamera {
  const OrbisCamera({
    required this.position,
    required this.target,
    this.fieldOfView = 50,
  });

  final Vector3 position;
  final Vector3 target;

  /// Vertical field of view in degrees.
  final double fieldOfView;
}

/// The sky, and the light it casts on everything.
///
/// One thing rather than two, because a backdrop that lights nothing reads as
/// a photograph behind the scene rather than the sky the scene stands under.
/// Without it, every shadow and every surface facing away from the sun renders
/// pure black.
class OrbisSky {
  OrbisSky({Vector3? colour, this.ambient = 28000})
    : colour = colour ?? Vector3(0.10, 0.12, 0.16);

  /// Linear RGB.
  final Vector3 colour;

  /// How much light the sky casts, in lux. Roughly a tenth of the sun on a
  /// clear day, which is about the ratio outdoors.
  final double ambient;
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
  }) : colour = colour ?? Vector3(0.5, 0.55, 0.6);

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
    0,
  ]);

  /// How many floats the fog occupies.
  static const int stride = 10;
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
  }) : lights = lights ?? const [],
       sky = sky ?? OrbisSky(),
       fog = fog ?? OrbisFog.none;

  final List<OrbisObject> objects;

  /// Every light in the scene. A scene with none is lit by its sky alone,
  /// which is dim and even and perfectly legitimate.
  final List<OrbisLight> lights;

  final OrbisCamera camera;
  final OrbisSky sky;
  final OrbisFog fog;

  /// Packs the scene into the flat arrays the channel carries.
  Map<String, Object> toMessage(int textureId) {
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
      'skyColour': _vector(sky.colour),
      'ambient': sky.ambient,
      'fogEnabled': fog.isVisible,
      'fogParams': fog._packed,
    };
  }

  static Float32List _vector(Vector3 value) =>
      Float32List.fromList([value.x, value.y, value.z]);
}
