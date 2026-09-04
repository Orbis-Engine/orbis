import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart';

/// One thing to draw: where it is, and what colour it is.
///
/// The mesh is not part of this yet — the renderer draws a unit cube for every
/// object. Naming the field now and only honouring the transform would suggest
/// a capability that isn't there, so the mesh arrives when glTF loading does.
class OrbisObject {
  /// Creates an object at [transform] in [colour], which is linear RGB — not
  /// sRGB, and not a Flutter [Color], because the lighting maths happens in
  /// linear space and a silent conversion is the kind that goes unnoticed.
  const OrbisObject({required this.transform, required this.colour, this.mesh});

  final Matrix4 transform;
  final Vector3 colour;

  /// An absolute path to a glTF or glb file, or null for the built-in cube.
  ///
  /// Loaded once and kept, however many scenes mention it. An object naming a
  /// file that cannot be read is drawn as the cube, and the failure comes back
  /// from the publish rather than being logged where nobody sees it.
  final String? mesh;
}

/// The sun, in the units Blender uses.
class OrbisSun {
  // Not const: Vector3 has no const constructor, so white cannot be a const
  // default.
  OrbisSun({
    required this.direction,
    Vector3? colour,
    this.illuminance = 100000,
  }) : colour = colour ?? Vector3(1, 1, 1);

  /// The direction light travels, not the direction of the sun in the sky.
  final Vector3 direction;

  final Vector3 colour;

  /// Illuminance in lux. Overcast daylight is around 10000; direct sun is
  /// around 100000.
  final double illuminance;
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

/// Everything the renderer needs for a frame.
///
/// Sent whole rather than as a diff. A scene of this size costs less to send
/// than a diff costs to get wrong, and "the renderer thought nothing changed"
/// is a failure that looks exactly like a frozen viewport.
class OrbisScene {
  OrbisScene({
    required this.objects,
    required this.sun,
    required this.camera,
    OrbisSky? sky,
  }) : sky = sky ?? OrbisSky();

  final List<OrbisObject> objects;
  final OrbisSun sun;
  final OrbisCamera camera;
  final OrbisSky sky;

  /// Packs the scene into the flat float arrays the channel carries.
  Map<String, Object> toMessage(int textureId) {
    final transforms = Float32List(objects.length * 16);
    final colours = Float32List(objects.length * 3);
    final meshes = Int32List(objects.length);

    // Paths are sent once and referred to by index, because the same mesh is
    // usually on many objects and the message goes over the channel on every
    // frame of a drag.
    final paths = <String>[];
    final indices = <String, int>{};

    for (var i = 0; i < objects.length; i++) {
      final object = objects[i];
      final mesh = object.mesh;
      meshes[i] = mesh == null
          ? -1
          : indices.putIfAbsent(mesh, () {
              paths.add(mesh);
              return paths.length - 1;
            });
      // Matrix4's storage is already column-major, which is what Filament's
      // mat4f expects, so this copies rather than transposes.
      transforms.setRange(i * 16, i * 16 + 16, object.transform.storage);
      colours[i * 3] = object.colour.x;
      colours[i * 3 + 1] = object.colour.y;
      colours[i * 3 + 2] = object.colour.z;
    }

    return {
      'textureId': textureId,
      'transforms': transforms,
      'colours': colours,
      'meshes': meshes,
      'meshPaths': paths,
      'sunDirection': _vector(sun.direction.normalized()),
      'sunColour': _vector(sun.colour),
      'sunIlluminance': sun.illuminance,
      'cameraPosition': _vector(camera.position),
      'cameraTarget': _vector(camera.target),
      'fieldOfView': camera.fieldOfView,
      'skyColour': _vector(sky.colour),
      'ambient': sky.ambient,
    };
  }

  static Float32List _vector(Vector3 value) =>
      Float32List.fromList([value.x, value.y, value.z]);
}
