import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import 'units.dart';

/// What kind of source a light is.
enum LightType {
  /// Radiates in every direction from a point. A bulb.
  point,

  /// Parallel rays from infinitely far away. A sun, and the only light whose
  /// strength does not fall off with distance.
  sun,

  /// A cone. A torch, a stage lamp, a car headlight.
  spot,

  /// A shape that emits from its whole surface. Soft, because a surface being
  /// lit can see different parts of it, which is what produces a gradual
  /// shadow edge rather than a hard one.
  area,
}

/// The shape an area light emits from.
enum AreaShape { square, rectangle, disk, ellipse }

/// A light, described the way an artist states one.
///
/// Power in watts, sizes in metres, angles in degrees — the units on the
/// fixture and in the tool the scene was authored in. Nothing here is in the
/// renderer's units; [toRenderer] does that conversion in one place, so a
/// change of renderer does not mean re-authoring every light.
class Light {
  Light({
    this.type = LightType.point,
    Vector3? color,
    double? power,
    this.radius = 0.1,
    this.sunAngle = 0.526,
    this.spotSize = 45,
    this.spotBlend = 0.15,
    this.shape = AreaShape.square,
    this.sizeX = 1.0,
    this.sizeY = 1.0,
    this.spread = 180,
    this.diffuse = 1,
    this.specular = 1,
    this.volume = 1,
    this.castShadows = true,
    this.customDistance,
  }) : color = color ?? Vector3(1, 1, 1),
       power = power ?? _defaultPower(type);

  /// What a light of this type starts at, matching the values an artist will
  /// have seen when they added one.
  static double _defaultPower(LightType type) => switch (type) {
    LightType.sun => 1.0,
    LightType.area => 100,
    _ => 1000,
  };

  LightType type;

  /// Linear RGB, not gamma. A colour picked in sRGB has to be converted before
  /// it gets here, or every light will be too bright in the midtones.
  Vector3 color;

  /// Watts for a point, spot or area light. Watts per square metre for a sun,
  /// since parallel rays have no total to state.
  double power;

  /// How large the source is, in metres.
  ///
  /// Not a brightness control — the power stays the same and is spread over a
  /// bigger surface. What it changes is the shadow: a point source gives a
  /// knife edge, and anything with size gives a penumbra that widens with
  /// distance from the occluder.
  double radius;

  /// The sun's angular diameter in degrees.
  ///
  /// Defaults to the real one. It is why shadows outdoors are crisp at your
  /// feet and soft at the end of a long shadow, and turning it to zero is the
  /// quickest way to make an outdoor scene look computer-generated.
  double sunAngle;

  /// The full cone angle of a spot, in degrees.
  double spotSize;

  /// How much of the cone is falloff rather than full brightness, from zero
  /// for a hard edge to one for a cone that is entirely gradient.
  double spotBlend;

  AreaShape shape;

  /// Metres. [sizeY] is ignored for a square or a disk, which are defined by
  /// [sizeX] alone.
  double sizeX;
  double sizeY;

  /// How wide an area light throws, in degrees. A hundred and eighty is a bare
  /// surface radiating into the whole hemisphere; smaller values are what a
  /// softbox with a grid on it does.
  double spread;

  /// Multipliers on the light's contribution to each response.
  ///
  /// Not physical, and useful precisely because of that: killing the specular
  /// on a fill light is how you stop it putting a second highlight in someone's
  /// eyes, which no real fixture will do for you.
  double diffuse;
  double specular;
  double volume;

  bool castShadows;

  /// A distance past which the light is ignored, in metres.
  ///
  /// Null lets it be derived from the power, which is usually better: a cutoff
  /// chosen by hand is either wastefully far or visibly clipped.
  double? customDistance;

  /// The area of the emitting surface in square metres, for the shapes that
  /// have one.
  double get emittingArea => switch (shape) {
    AreaShape.square => sizeX * sizeX,
    AreaShape.rectangle => sizeX * sizeY,
    AreaShape.disk => math.pi * (sizeX / 2) * (sizeX / 2),
    AreaShape.ellipse => math.pi * (sizeX / 2) * (sizeY / 2),
  };

  /// Converts to the units and angles a renderer works in.
  RendererLight toRenderer() {
    final kind = switch (type) {
      LightType.sun => RendererLightKind.directional,
      LightType.point => RendererLightKind.point,
      LightType.spot => RendererLightKind.spot,
      // No renderer this targets has a true area light, so it arrives as a
      // point of the same luminous power at the shape's centre. The falloff
      // and the total light are right; the soft shadow its size would have
      // produced is not, and that is worth knowing rather than discovering.
      LightType.area => RendererLightKind.point,
    };

    final intensity = type == LightType.sun
        ? Photometry.irradianceToLux(power)
        : Photometry.wattsToLumens(power);

    final outer = spotSize.clamp(0.0, 180.0) / 2 * math.pi / 180;

    return RendererLight(
      kind: kind,
      color: color.clone(),
      intensity: intensity,
      // A sun does not fall off, so its influence has no radius.
      falloffRadius: type == LightType.sun
          ? double.infinity
          : customDistance ?? Photometry.influenceRadius(intensity),
      innerConeAngle: outer * (1 - spotBlend.clamp(0.0, 1.0)),
      outerConeAngle: outer,
      sunAngularRadius: sunAngle / 2,
      sourceRadius: type == LightType.area ? _areaEquivalentRadius() : radius,
      castShadows: castShadows,
      approximated: type == LightType.area,
    );
  }

  /// The radius of a sphere with the same area as this shape, so a light that
  /// arrives as a point at least casts a penumbra of a believable width.
  double _areaEquivalentRadius() => math.sqrt(emittingArea / math.pi);

  Light copy() => Light(
    type: type,
    color: color.clone(),
    power: power,
    radius: radius,
    sunAngle: sunAngle,
    spotSize: spotSize,
    spotBlend: spotBlend,
    shape: shape,
    sizeX: sizeX,
    sizeY: sizeY,
    spread: spread,
    diffuse: diffuse,
    specular: specular,
    volume: volume,
    castShadows: castShadows,
    customDistance: customDistance,
  );
}

/// The kinds of light a renderer actually implements.
enum RendererLightKind { directional, point, spot }

/// A light in the units a renderer takes.
class RendererLight {
  const RendererLight({
    required this.kind,
    required this.color,
    required this.intensity,
    required this.falloffRadius,
    required this.innerConeAngle,
    required this.outerConeAngle,
    required this.sunAngularRadius,
    required this.sourceRadius,
    required this.castShadows,
    this.approximated = false,
  });

  final RendererLightKind kind;
  final Vector3 color;

  /// Lumens for a point or spot; lux for a directional light.
  final double intensity;

  /// Metres, or infinite for a directional light.
  final double falloffRadius;

  /// Radians. Full brightness within the inner angle, falling to nothing at
  /// the outer one.
  final double innerConeAngle;
  final double outerConeAngle;

  /// Half the sun's angular diameter, in degrees.
  final double sunAngularRadius;

  /// Metres, for soft shadows.
  final double sourceRadius;

  final bool castShadows;

  /// Whether something was lost on the way here — currently only true for area
  /// lights, which no target renderer supports natively.
  final bool approximated;
}
