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
  const OrbisObject({required this.transform, required this.colour});

  final Matrix4 transform;
  final Vector3 colour;
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

/// Everything the renderer needs for a frame.
///
/// Sent whole rather than as a diff. A scene of this size costs less to send
/// than a diff costs to get wrong, and "the renderer thought nothing changed"
/// is a failure that looks exactly like a frozen viewport.
class OrbisScene {
  const OrbisScene({
    required this.objects,
    required this.sun,
    required this.camera,
  });

  final List<OrbisObject> objects;
  final OrbisSun sun;
  final OrbisCamera camera;

  /// Packs the scene into the flat float arrays the channel carries.
  Map<String, Object> toMessage(int textureId) {
    final transforms = Float32List(objects.length * 16);
    final colours = Float32List(objects.length * 3);
    for (var i = 0; i < objects.length; i++) {
      final object = objects[i];
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
      'sunDirection': _vector(sun.direction.normalized()),
      'sunColour': _vector(sun.colour),
      'sunIlluminance': sun.illuminance,
      'cameraPosition': _vector(camera.position),
      'cameraTarget': _vector(camera.target),
      'fieldOfView': camera.fieldOfView,
    };
  }

  static Float32List _vector(Vector3 value) =>
      Float32List.fromList([value.x, value.y, value.z]);
}
