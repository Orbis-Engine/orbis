import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart';

import 'material.dart' show OrbisTexture;

/// A picture thrown along a box onto whatever is inside it.
///
/// A poster on a wall, a scorch on a floor, a puddle, graffiti, the white
/// line down a road. None of those is an object of its own: each is a change
/// to a surface that is already there, and modelling it as a quad floating a
/// millimetre above that surface is how it ends up flickering through it,
/// hanging off the edge of a kerb, or failing to bend round a corner.
///
/// So a decal is a box. Every lit surface inside it takes the picture at the
/// point the box's x and z say, painted into its base colour — and, if asked,
/// its roughness and metalness — *before* it is lit. That is the difference
/// that matters: a decal is shadowed where the surface is shadowed and shines
/// where the surface shines, because by the time the lights see it, it is
/// the surface.
///
/// The box's own y is the projection axis. An unturned decal is thrown
/// straight down, which is a floor marking; turned a quarter about x it is
/// thrown along minus z, which is a poster on a wall facing the viewer.
///
/// What it does not reach: surfaces drawn with a glTF file's own materials,
/// with the unlit or video surfaces, and populations. Those are other
/// shaders, and a decal is part of the standard surface's.
class OrbisDecal {
  OrbisDecal({
    required this.key,
    required this.position,
    required this.size,
    Quaternion? rotation,
    this.texture,
    Vector3? colour,
    this.opacity = 1,
    this.fadeStartAngle = defaultFadeStart,
    this.fadeEndAngle = defaultFadeEnd,
    this.roughness,
    this.metallic,
    this.layers,
    this.sortOrder = 0,
  }) : rotation = rotation ?? Quaternion.identity(),
       colour = colour ?? Vector3(1, 1, 1);

  /// This decal's identity, for an editor to select it by. Shares its space
  /// with every other key in the scene.
  final int key;

  /// The centre of the projection box, in the world.
  final Vector3 position;

  /// How the box is turned. Its y is the direction it throws along, towards
  /// minus; its x runs across the picture and its z down it.
  final Quaternion rotation;

  /// The box's full extent along its own x, y and z, in metres.
  ///
  /// x and z are how big the picture is. y is how deep the projection reaches
  /// — worth keeping shallow, because everything inside it is painted, and a
  /// floor decal a metre deep paints the feet of whoever stands on it.
  final Vector3 size;

  /// The picture, or null for a decal that is only its [colour].
  ///
  /// Read as colour, always: whatever [OrbisTexture.srgb] says, a decal's
  /// picture is something somebody painted. Its alpha is how much of the
  /// surface it covers. Every picture is resampled to the same square on the
  /// way in, so the aspect ratio that matters is the box's, not the file's.
  final OrbisTexture? texture;

  /// Linear RGB, multiplied into the picture — or the whole decal's colour
  /// when there is no picture.
  final Vector3 colour;

  /// How much of the surface it covers where the picture is solid, 0 to 1.
  final double opacity;

  /// The angle from the projection axis, in radians, at which the decal
  /// starts to fade — and the one by which it has gone.
  ///
  /// This is what stops a decal smearing. A box straddling the corner where a
  /// floor meets a wall covers both, and the wall is edge-on to a decal
  /// thrown downwards: every point on it lands on the same row of the
  /// picture, which draws as stripes running down the wall. Fading by how
  /// square the surface is to the projector keeps the decal on the floor.
  /// [noFade] for both turns it off.
  final double fadeStartAngle;
  final double fadeEndAngle;

  /// Paints this roughness where the decal covers, or leaves the surface's
  /// own alone when null. A puddle is a decal that is mostly this: darker, and
  /// much smoother than the ground under it.
  final double? roughness;

  /// Paints this metalness where the decal covers, or leaves it when null.
  final double? metallic;

  /// Which layers receive it, as [OrbisObject.layer] numbers — null for every
  /// layer.
  ///
  /// Objects that share one [OrbisMaterial] share one shader instance, so
  /// they are painted as though they were on every layer any of them is on.
  /// Objects with a material of their own are painted exactly by their layer.
  final Set<int>? layers;

  /// Which decals are painted over which. Higher is later, so on top; equal
  /// orders keep the order they were listed in.
  final int sortOrder;

  /// Sixty degrees: a floor that slopes like a steep ramp still takes the
  /// whole picture.
  static const double defaultFadeStart = 60 * math.pi / 180;

  /// Eighty: gone well before the surface is edge-on.
  static const double defaultFadeEnd = 80 * math.pi / 180;

  /// Pass for both fade angles to paint every surface in the box whichever
  /// way it faces.
  static const double noFade = math.pi;

  /// The seven layers as bits, the way the renderer holds them.
  int get layerMask {
    final named = layers;
    if (named == null) return 0x7F;
    var mask = 0;
    for (final layer in named) {
      if (layer >= 0 && layer <= 6) mask |= 1 << layer;
    }
    return mask;
  }

  /// Writes this decal's floats into the scene's decal block.
  ///
  /// The layout is written out in OrbisDecals.h, which is what reads it.
  void pack(Float32List into, int at) {
    into[at] = position.x;
    into[at + 1] = position.y;
    into[at + 2] = position.z;
    into[at + 3] = rotation.x;
    into[at + 4] = rotation.y;
    into[at + 5] = rotation.z;
    into[at + 6] = rotation.w;
    into[at + 7] = size.x;
    into[at + 8] = size.y;
    into[at + 9] = size.z;
    into[at + 10] = colour.x;
    into[at + 11] = colour.y;
    into[at + 12] = colour.z;
    into[at + 13] = opacity;
    into[at + 14] = fadeStartAngle;
    into[at + 15] = fadeEndAngle;
    into[at + 16] = roughness ?? 0;
    into[at + 17] = roughness == null ? 0 : 1;
    into[at + 18] = metallic ?? 0;
    into[at + 19] = metallic == null ? 0 : 1;
    into[at + 20] = layerMask.toDouble();
    into[at + 21] = sortOrder.toDouble();
  }

  /// How many floats one decal occupies.
  static const int stride = 22;

  /// How many one view paints. The renderer reports any past this.
  static const int budget = 32;
}
