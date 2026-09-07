import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart';

/// How a surface answers light.
///
/// Two answers rather than a catalogue. Every physically based renderer's
/// long list of shaders — standard, glass, foliage, decal — is the same
/// lighting model with different numbers in it, and the numbers live on
/// [OrbisMaterial]. What genuinely differs is whether light is consulted at
/// all.
enum OrbisShading {
  /// Lit by the scene: metalness, roughness, reflectance, the lot.
  lit,

  /// Ignores light entirely and draws the base colour as given. Cheaper than
  /// [lit] by every light in the scene, and the right answer for anything
  /// that carries its own brightness — a marker, a sky card, a screen.
  unlit,

  /// Shows a video. Unlit for the same reason: a screen makes its own light,
  /// and the frame arriving from the decoder is already the picture somebody
  /// graded. Set [OrbisMaterial.video] to the key of the video to show;
  /// [OrbisMaterial.baseColour] tints it, so a screen can be dimmed or faded
  /// without touching the film.
  video,
}

/// How a surface's pixels combine with what is already drawn.
///
/// This is the one property of a material that cannot change without
/// recompiling it, because blending is fixed-function state the GPU is
/// configured with rather than something a shader decides. Each mode is a
/// separately compiled copy of the same shader, so switching an object from
/// [opaque] to [fade] swaps which material its instance comes from.
enum OrbisBlend {
  /// Alpha is ignored; the pixel replaces what was there. The fast path, and
  /// the default, because an opaque object can be depth-sorted, occlusion
  /// culled and drawn in any order.
  opaque,

  /// Alpha fades the surface's own reflections and diffuse together, keeping
  /// specular highlights at full strength. Glass: still shiny at the edges
  /// however clear it is.
  transparent,

  /// Alpha fades everything, highlights included, until the surface is gone.
  /// A dissolve or a fade-out, where the object is meant to stop existing
  /// rather than become see-through.
  fade,

  /// Each pixel is either fully drawn or discarded, decided by comparing
  /// alpha against [OrbisMaterial.maskThreshold]. Leaves, chain-link, a
  /// cut-out sign — shapes cheaper to punch out of a quad than to model, and
  /// unlike the blended modes they still write depth and sort correctly.
  masked,

  /// Added to what is behind it, so it only ever brightens. Fire, sparks,
  /// holograms, muzzle flash.
  add,
}

/// Which side of a triangle is drawn.
enum OrbisCulling {
  /// Draw the front, discard the back. The default: half the fragments of a
  /// closed shape are facing away and would be hidden anyway.
  back,

  /// Draw the back, discard the front — for looking at a shape from inside.
  front,

  /// Draw both. Needed for anything one triangle thick, and the reason
  /// [OrbisMaterial.doubleSided] exists: culling nothing shows the back face
  /// but leaves it lit by a normal pointing the wrong way.
  none,
}

/// How a texture behaves outside the nought-to-one range.
enum OrbisWrap {
  /// Tiles. What [OrbisMaterial.tiling] above one is for.
  repeat,

  /// The edge pixel stretches outwards. Right for anything that is meant to
  /// be placed once, where repeating would show a seam.
  clamp,

  /// Tiles, flipping every other copy, so the seams line up.
  mirror,
}

/// How a texture is sampled between its pixels.
enum OrbisFilter {
  /// Smoothed, with mipmaps. Almost always what is wanted.
  smooth,

  /// Nearest pixel, no smoothing. Pixel art stays pixel art rather than
  /// turning to mush at any distance other than exactly one to one.
  sharp,
}

/// An image on disk, used as one of a material's maps.
///
/// A path rather than bytes: the same file is usually on many materials, and
/// the renderer loads each one once however many ask for it. PNG, JPEG and
/// KTX2 are understood.
class OrbisTexture {
  const OrbisTexture(this.path, {this.srgb = true});

  /// What a pass drew, sampled as a texture.
  ///
  /// This is what makes a render target worth writing. A mirror is a pass
  /// that draws the scene from behind the glass into a target and a material
  /// that samples it; a portal, a security monitor and a rear-view mirror are
  /// the same two halves. Without this a target is a picture nothing can
  /// look at.
  ///
  /// Addressed as a path with a scheme rather than through a second field:
  /// a texture is already "where the image comes from", and one more place it
  /// can come from is a different answer to the same question rather than a
  /// different question. Never sRGB — what a pass drew is already linear, and
  /// decoding it again would darken every reflection in the scene.
  factory OrbisTexture.ofTarget(String target) =>
      OrbisTexture('$targetScheme$target', srgb: false);

  /// What a target's path starts with.
  static const String targetScheme = 'orbis:target/';

  /// Absolute path to the image, or `orbis:target/<name>` for what a pass
  /// drew.
  final String path;

  /// The pass target this samples, or null if it is an image on disk.
  String? get target => path.startsWith(targetScheme)
      ? path.substring(targetScheme.length)
      : null;

  /// Whether the file's numbers are sRGB and need decoding to linear.
  ///
  /// True for anything describing a colour a person picked — base colour,
  /// emissive. **False** for anything describing a measurement — normals,
  /// roughness, metalness, occlusion. Getting this wrong on a normal map
  /// bends every normal towards flat and the surface goes subtly wrong in a
  /// way that reads as "the lighting is off" rather than "the texture is
  /// wrong".
  final bool srgb;

  @override
  bool operator ==(Object other) =>
      other is OrbisTexture && other.path == path && other.srgb == srgb;

  @override
  int get hashCode => Object.hash(path, srgb);
}

/// What a surface is made of.
///
/// The numbers are physically based, which means they describe the material
/// rather than the look: a value that is right for copper is right for copper
/// under every light, in every scene, forever. That is the whole reason to
/// spell them out this way instead of exposing a colour and a shininess.
///
/// Every field has a default that draws something sensible, so a material is
/// worth making for one changed number.
class OrbisMaterial {
  const OrbisMaterial({
    required this.key,
    this.shading = OrbisShading.lit,
    this.blend = OrbisBlend.opaque,
    this.culling = OrbisCulling.back,
    this.doubleSided = false,
    Vector4? baseColour,
    this.metallic = 0.0,
    this.roughness = 0.5,
    this.reflectance = 0.5,
    Vector3? emissive,
    this.emissiveIntensity = 0.0,
    this.ambientOcclusion = 1.0,
    this.normalScale = 1.0,
    Vector2? tiling,
    Vector2? offset,
    this.maskThreshold = 0.4,
    this.depthWrite = true,
    this.depthBias = 0.0,
    this.wrap = OrbisWrap.repeat,
    this.filter = OrbisFilter.smooth,
    this.video,
    this.baseColourMap,
    this.normalMap,
    this.metallicRoughnessMap,
    this.occlusionMap,
    this.emissiveMap,
  }) : _baseColour = baseColour,
       _emissive = emissive,
       _tiling = tiling,
       _offset = offset;

  /// This material's identity, stable for as long as it exists — the same
  /// contract as an object's key, and for the same reason. A renderer that
  /// cannot tell this frame's brass from last frame's has to rebuild both.
  final int key;

  final OrbisShading shading;
  final OrbisBlend blend;
  final OrbisCulling culling;

  /// Whether a back face is lit as though its normal pointed at the camera.
  ///
  /// Distinct from `culling: none`, which only stops the back face being
  /// thrown away — it is still shaded by a normal aimed into the surface, so
  /// a leaf lit from behind goes black. This flips it, and implies drawing
  /// both sides.
  final bool doubleSided;

  final Vector4? _baseColour;
  final Vector3? _emissive;
  final Vector2? _tiling;
  final Vector2? _offset;

  /// Linear RGB and alpha. Not sRGB, and not a Flutter Color: the lighting
  /// maths happens in linear space and a silent conversion is the kind that
  /// goes unnoticed.
  Vector4 get baseColour => _baseColour ?? Vector4(0.8, 0.8, 0.8, 1.0);

  /// How metal the surface is. Physically this is nought or one and nothing
  /// between — the values in between exist for the edge of a scratch, where
  /// one pixel covers both.
  final double metallic;

  /// How scattered its reflections are, from a mirror at nought to fully
  /// diffuse at one. Perfect nought is avoided in practice: a highlight
  /// smaller than a pixel flickers.
  final double roughness;

  /// How strongly a *non-metal* reflects head-on, remapped so that the
  /// ordinary range of real materials lands around the middle. Half means
  /// four percent, which is water, plastic, skin and most other things.
  /// Ignored entirely when [metallic] is one.
  final double reflectance;

  /// Light the surface gives off, linear RGB, multiplied by
  /// [emissiveIntensity]. Kept separate from the colour so a lamp can be
  /// brightened without turning white.
  Vector3 get emissive => _emissive ?? Vector3.zero();
  final double emissiveIntensity;

  /// How much ambient light reaches the surface, from fully shadowed at
  /// nought to open sky at one. This is the baked, per-material figure; the
  /// screen-space kind is a post-processing setting and they multiply.
  final double ambientOcclusion;

  /// How far the normal map bends the surface. Nought is flat, one is as
  /// authored, above one exaggerates.
  final double normalScale;

  /// How many times the maps repeat across the surface.
  Vector2 get tiling => _tiling ?? Vector2(1.0, 1.0);

  /// Where they start. Animating this scrolls a texture, which is how a
  /// conveyor, a waterfall or a starfield is usually done.
  Vector2 get offset => _offset ?? Vector2.zero();

  /// The alpha below which a pixel is thrown away, for [OrbisBlend.masked].
  final double maskThreshold;

  /// Whether drawing the surface records how far away it is.
  ///
  /// On for anything solid. Off is the usual answer for additive effects,
  /// which would otherwise hide each other in whatever order they happened
  /// to be drawn.
  final bool depthWrite;

  /// How far the surface is pushed away from the camera in the depth test
  /// only, without moving where it is drawn.
  ///
  /// For the surfaces that share a plane with another and must lose. Two
  /// coplanar things flicker pixel by pixel as the camera moves — each one
  /// winning wherever the arithmetic rounds its way — and no amount of depth
  /// precision fixes it, because the two really are at the same depth. This
  /// says which of them is behind.
  ///
  /// Positive pushes back. A ground marking, a decal, a grid: anything meant
  /// to be *on* a surface rather than fighting it.
  final double depthBias;

  final OrbisWrap wrap;
  final OrbisFilter filter;

  /// The key of the video this surface shows, for [OrbisShading.video].
  /// Ignored by every other shading model.
  final int? video;

  /// Multiplied into [baseColour]. sRGB.
  final OrbisTexture? baseColourMap;

  /// Tangent-space normals in the usual encoding, where flat is the pale
  /// lilac that packs to nought. Linear, never sRGB.
  final OrbisTexture? normalMap;

  /// Roughness in green, metalness in blue — glTF's packing, which is what
  /// every exporter writes. Multiplied into [roughness] and [metallic].
  /// Linear.
  final OrbisTexture? metallicRoughnessMap;

  /// Occlusion in red, multiplied into [ambientOcclusion]. Linear.
  final OrbisTexture? occlusionMap;

  /// Multiplied into [emissive]. sRGB.
  final OrbisTexture? emissiveMap;

  /// The maps in the order the renderer expects them.
  List<OrbisTexture?> get maps => [
    baseColourMap,
    normalMap,
    metallicRoughnessMap,
    occlusionMap,
    emissiveMap,
  ];

  /// How many maps a material has room for.
  static const int mapCount = 5;

  /// How many floats one material contributes to the message.
  static const int stride = 19;

  /// The bits that decide which compiled material an instance comes from and
  /// how the rasteriser is set up. Separate from the floats because a change
  /// here means rebuilding the instance and a change there means writing a
  /// uniform, and the renderer wants to tell those apart without comparing
  /// eighteen numbers to find out.
  int get flags =>
      shading.index |
      (blend.index << 2) |
      (culling.index << 6) |
      ((doubleSided ? 1 : 0) << 8) |
      ((depthWrite ? 1 : 0) << 9) |
      (wrap.index << 10) |
      (filter.index << 12);

  /// Writes this material's numbers into [out] at [at], in the fixed order
  /// the renderer reads them back.
  void pack(Float32List out, int at) {
    final colour = baseColour;
    final glow = emissive;
    final scale = tiling;
    final shift = offset;
    out[at] = colour.x;
    out[at + 1] = colour.y;
    out[at + 2] = colour.z;
    out[at + 3] = colour.w;
    out[at + 4] = metallic;
    out[at + 5] = roughness;
    out[at + 6] = reflectance;
    out[at + 7] = glow.x;
    out[at + 8] = glow.y;
    out[at + 9] = glow.z;
    out[at + 10] = emissiveIntensity;
    out[at + 11] = ambientOcclusion;
    out[at + 12] = normalScale;
    out[at + 13] = scale.x;
    out[at + 14] = scale.y;
    out[at + 15] = shift.x;
    out[at + 16] = shift.y;
    out[at + 17] = maskThreshold;
    out[at + 18] = depthBias;
  }

  OrbisMaterial copyWith({
    OrbisShading? shading,
    OrbisBlend? blend,
    OrbisCulling? culling,
    bool? doubleSided,
    Vector4? baseColour,
    double? metallic,
    double? roughness,
    double? reflectance,
    Vector3? emissive,
    double? emissiveIntensity,
    double? ambientOcclusion,
    double? normalScale,
    Vector2? tiling,
    Vector2? offset,
    double? maskThreshold,
    bool? depthWrite,
    double? depthBias,
    OrbisWrap? wrap,
    OrbisFilter? filter,
  }) {
    return OrbisMaterial(
      key: key,
      shading: shading ?? this.shading,
      blend: blend ?? this.blend,
      culling: culling ?? this.culling,
      doubleSided: doubleSided ?? this.doubleSided,
      baseColour: baseColour ?? this.baseColour,
      metallic: metallic ?? this.metallic,
      roughness: roughness ?? this.roughness,
      reflectance: reflectance ?? this.reflectance,
      emissive: emissive ?? this.emissive,
      emissiveIntensity: emissiveIntensity ?? this.emissiveIntensity,
      ambientOcclusion: ambientOcclusion ?? this.ambientOcclusion,
      normalScale: normalScale ?? this.normalScale,
      tiling: tiling ?? this.tiling,
      offset: offset ?? this.offset,
      maskThreshold: maskThreshold ?? this.maskThreshold,
      depthWrite: depthWrite ?? this.depthWrite,
      depthBias: depthBias ?? this.depthBias,
      wrap: wrap ?? this.wrap,
      filter: filter ?? this.filter,
      video: video,
      baseColourMap: baseColourMap,
      normalMap: normalMap,
      metallicRoughnessMap: metallicRoughnessMap,
      occlusionMap: occlusionMap,
      emissiveMap: emissiveMap,
    );
  }
}
