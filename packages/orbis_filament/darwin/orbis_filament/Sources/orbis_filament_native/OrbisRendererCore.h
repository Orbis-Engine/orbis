#pragma once

// The renderer, in plain C++.
//
// Everything Orbis draws is decided here: the scene and its reconciliation,
// the materials, lights, sky and weather, the render graph and its passes,
// probes, the irradiance field, post-processing, decals, splats, the outline
// and batching. No Objective-C and no Apple header, so the same class runs
// behind the Swift plugin on macOS and iOS, behind the C ABI in
// include/orbis_renderer.h anywhere else, and behind a host with no Flutter
// at all.
//
// It was the Objective-C class in OrbisRenderer.mm, and it is laid out as
// that class was, so that a change made to the old file can be found in this
// one: every method is a member function named for the first part of its
// selector, in OrbisRendererCore.cpp in the same order with the same
// comments, and every ivar is a member of the same name. The structs and
// constants from the top of the old file are below, in the same order. What
// the operating system provides — logging, the clock, files, pictures,
// video — is asked of OrbisPlatform.h, and where a frame is presented is
// OrbisSurface's business, as it was before.

#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <unordered_map>
#include <vector>

#include <filament-iblprefilter/IBLPrefilterContext.h>
#include <filament/Camera.h>
#include <filament/ColorGrading.h>
#include <filament/Engine.h>
#include <filament/IndexBuffer.h>
#include <filament/IndirectLight.h>
#include <filament/InstanceBuffer.h>
#include <filament/Material.h>
#include <filament/MaterialInstance.h>
#include <filament/RenderTarget.h>
#include <filament/Renderer.h>
#include <filament/Scene.h>
#include <filament/Skybox.h>
#include <filament/SwapChain.h>
#include <filament/Texture.h>
#include <filament/TextureSampler.h>
#include <filament/VertexBuffer.h>
#include <filament/View.h>
#include <gltfio/AssetLoader.h>
#include <gltfio/FilamentAsset.h>
#include <gltfio/FilamentInstance.h>
#include <gltfio/MaterialProvider.h>
#include <gltfio/ResourceLoader.h>
#include <gltfio/TextureProvider.h>
#include <math/mat4.h>
#include <math/quat.h>
#include <math/vec2.h>
#include <math/vec3.h>
#include <math/vec4.h>
#include <utils/Entity.h>

#include "OrbisBatching.h"
#include "OrbisOutline.h"
#include "OrbisPlatform.h"
#include "OrbisShadows.h"
#include "OrbisSplatSet.h"
#include "OrbisSurface.h"
#include "orbis_renderer.h"
// Hook (screen effects): god rays and distortion live in plain C++, beside
// this file, so the port to the renderer's C++ class carries them unchanged.
#include "ScreenEffects.h"
// Motion blur hook: the velocity pass, the tiles and the gather live in plain
// C++ beside this file; the renderer holds one and tells it what moved.
#include "OrbisMotionBlur.h"

namespace orbis {

// Filament's names, which the old file had from `using namespace filament`.
// Named one at a time rather than the whole namespace, because a header that
// pulls a namespace in pulls it into every file that includes it — and
// because filament::Renderer is the one name that must stay out: inside
// orbis, Renderer is this class, and Filament's is always spelled in full.
using filament::Camera;
using filament::ColorGrading;
using filament::Engine;
using filament::IndexBuffer;
using filament::IndirectLight;
using filament::Material;
using filament::MaterialInstance;
using filament::Scene;
using filament::Skybox;
using filament::SwapChain;
using filament::Texture;
using filament::TextureSampler;
using filament::VertexBuffer;
using filament::View;
namespace gltfio = filament::gltfio;
using filament::math::float2;
using filament::math::float3;
using filament::math::float4;
using filament::math::mat4f;
using filament::math::quatf;

/// What a scene asked for that could not be given, and why, keyed by what it
/// is about. An NSDictionary of strings before; a map of them now, and the
/// Objective-C wrapper turns it back into the dictionary Swift reads.
using Notes = std::map<std::string, std::string>;


/// One loaded glTF file, and the copies made from that one parse.
///
/// Instances rather than one asset per object: a scene with fifty of the same
/// crate parses the file once and shares its geometry and materials.
///
/// `spare` is the pool. An object that stops using a mesh hands its instance
/// back rather than destroying it, so a crate deleted and undone — or a scene
/// closed and reopened — costs a pointer, not another parse.
struct Mesh {
  filament::gltfio::FilamentAsset *asset = nullptr;
  std::vector<filament::gltfio::FilamentInstance *> all;
  std::vector<filament::gltfio::FilamentInstance *> spare;
};

/// The most copies Filament will draw from one renderable.
///
/// Its own limit, and a hard one: this is the size of the block of
/// per-renderable uniforms it indexes by the copy's own number. Asking for
/// more does not fail, it reads past the end of that block — which draws a
/// screen full of wedges rather than anything recognisable.
///
/// So a population is submitted in sixty-fours. A hundred thousand members is
/// sixteen hundred draws rather than a hundred thousand, and each of those
/// sixteen hundred is culled as one — which for a large world is worth having
/// on its own.
constexpr uint32_t kInstancesPerDraw = 64;

/// How wide the cell is that a member's distance is measured from, matching
/// kCellSide in instanced.mat. Whole cells leave together, so nothing that
/// straddles the boundary is cut in half.
constexpr float kCellSide = 16.0f;

/// How wide the book of transforms is.
///
/// A texture rather than a uniform array. Filament's own InstanceBuffer would
/// carry a transform each, but it fills the per-renderable uniform block and
/// so is capped at sixty-four instances — which is not a number that draws a
/// forest. Two dimensions rather than one so the width stays well inside what
/// every platform allows.
constexpr uint32_t kBookWidth = 2048;

/// Four texels an instance: three rows of an affine, and a colour.
constexpr uint32_t kTexelsPerMember = 4;

/// How far through its range a member starts sinking.
///
/// Three quarters, so the last quarter is the going. Too late and it is a pop
/// with extra steps; too early and half the field is short.
constexpr float kFadeFrom = 0.75f;

/// One population as the renderer holds it between frames.
///
/// The buffers are the expensive part and they are built once. What arrives
/// each frame is a revision number, and when it has not moved there is
/// nothing to do at all — which is the only reason a hundred thousand members
/// costs less than a hundred thousand of anything.
struct Grown {
  std::vector<utils::Entity> entities;
  std::vector<filament::MaterialInstance *> materials;

  /// Which member goes in which slot of the book.
  ///
  /// Sorted so that members near each other in the world are near each other
  /// in the book, and therefore in the same draw. Without it a draw's
  /// sixty-four members are sixty-four places scattered over the whole map,
  /// its bounding box is the whole map, and nothing can ever be culled — the
  /// camera looking at one corner still pays for every draw in the world.
  std::vector<uint32_t> order;

  /// Where each draw's own members actually are, and how far from the middle
  /// of it to the furthest of them.
  std::vector<filament::math::float3> middles;
  std::vector<float> radii;

  /// Which draws are currently in the scene at all.
  std::vector<bool> shown;

  /// One book for the whole population. Sixty-four members a draw would
  /// otherwise mean sixteen hundred textures for a hundred thousand.
  filament::Texture *book = nullptr;

  uint32_t count = 0;
  int32_t revision = INT32_MIN;
  int32_t flags = -1;

  /// How far a member is still drawn from, in metres. Zero is always.
  float range = 0;

  std::string path;
  uint64_t seen = 0;
};

/// A number that puts nearby places near each other.
///
/// The bits of three coordinates interleaved, so sorting by it walks the world
/// in a way that keeps neighbours together. Sorting by any single axis instead
/// gives draws that are thin slabs across the whole map, which cull almost as
/// badly as no sorting at all.
inline uint64_t mortonOf(uint32_t x, uint32_t y, uint32_t z) {
  auto spread = [](uint32_t v) -> uint64_t {
    uint64_t n = v & 0x1FFFFFull;
    n = (n | (n << 32)) & 0x1F00000000FFFFull;
    n = (n | (n << 16)) & 0x1F0000FF0000FFull;
    n = (n | (n << 8)) & 0x100F00F00F00F00Full;
    n = (n | (n << 4)) & 0x10C30C30C30C30C3ull;
    n = (n | (n << 2)) & 0x1249249249249249ull;
    return n;
  };
  return spread(x) | (spread(y) << 1) | (spread(z) << 2);
}

/// Where the camera was told to be, and when it was told.
///
/// Two of these are kept, because one is a position and two are a motion —
/// and a motion is what lets the picture ask where the camera is *now* rather
/// than where it was when the message arrived.
struct Aimed {
  filament::math::float3 position{0.0f, 0.0f, 0.0f};
  filament::math::float3 target{0.0f, 0.0f, -1.0f};
  float fieldOfView = 50.0f;

  /// Whether parallel lines stay parallel, and how much of the world fits in
  /// the frame from top to bottom when they do.
  bool orthographic = false;
  float viewHeight = 10.0f;

  /// The application's own seconds, which is the clock the camera was solved
  /// on and therefore the only one its speed can honestly be measured against.
  double at = 0.0;

  /// When this arrived here, on the clock the picture is drawn against.
  double arrived = 0.0;

  bool valid = false;
};

/// How far behind the latest word the camera is drawn, as a multiple of the
/// usual gap between words.
///
/// Slightly behind on purpose. The application's own motion is smooth — a
/// tenth of a percent of unevenness, measured — so the best thing that can be
/// done with it is to read it rather than to guess at it. Sampling a little
/// behind means the moment being drawn almost always falls *between* two
/// things the application has said, where the answer is exact, instead of
/// past the last one, where it is a prediction that has to be corrected when
/// the next arrives.
///
/// The cost is about a sixtieth of a second of delay, which is far below
/// noticing. What it buys is the difference between a camera that judders and
/// one that does not.
constexpr double kDrawBehind = 1.15;

/// How far past the last word it will still carry on when one is late, as a
/// multiple of that same gap. Beyond this it holds still rather than
/// inventing a position, because by then it has no idea.
constexpr double kCarryOn = 2.5;

/// How quickly a correction is absorbed, in seconds.
///
/// Predicting where the camera is between words means being a little wrong,
/// and being put right the moment the next word arrives. Snapping to it is a
/// small jump every message, which is most of what is left of a judder once
/// the prediction is doing its job. Carrying the difference and letting it
/// decay spreads each correction over a few frames — and because it is the
/// *difference* being decayed rather than the position, the camera still ends
/// up exactly where it was told, with no trailing behind.
constexpr double kAbsorb = 0.05;

/// One object as the renderer holds it between frames.
///
/// What is kept here is exactly what has to be compared to decide whether a
/// frame's worth of work can be skipped: the shape the object was built as,
/// and the last values written into it.
struct Drawn {
  /// The cube path: an entity this renderer built and owns.
  utils::Entity entity;
  filament::MaterialInstance *material = nullptr;

  /// The mesh path: an instance borrowed from a loaded glTF file.
  filament::gltfio::FilamentInstance *instance = nullptr;

  /// Which file it draws, empty for the built-in cube. A change here is a
  /// change of what the object *is*, and the only thing that forces a rebuild.
  std::string path;

  filament::math::mat4f transform;

  /// Whether that transform has ever been written. An instance out of the pool
  /// still stands where its last owner left it, and identity — which is what
  /// this starts as — is a transform a new object might genuinely have. So the
  /// first write is unconditional rather than compared.
  bool placed = false;

  /// Impossible values, so the first publish always writes.
  filament::math::float3 colour = {-1, -1, -1};
  int32_t flags = -1;

  /// Which of this frame's materials the object is made of, or -1 for the
  /// default surface tinted by [colour]. Starts at an index no publish can
  /// name, so the first one always dresses.
  int32_t surface = -2;

  /// The layer bit written into this object's own instance for decals to
  /// test against. One, layer nought, is what a fresh instance is given.
  int32_t decalLayer = 1;

  /// A mesh's own materials, kept from the moment one is overridden so that
  /// clearing the override puts the model back the way the file had it.
  /// Empty while nothing has been overridden, which is the usual case.
  std::vector<filament::MaterialInstance *> ownMaterials;

  /// The shared surface a batched placeholder cube is wearing, or null for
  /// its own. Borrowed from the colour pool rather than owned: the cube's own
  /// [material] is kept, and its colour kept written, so leaving a batch is
  /// a pointer swapped back and nothing rebuilt.
  filament::MaterialInstance *pooled = nullptr;

  /// The publish that last mentioned this object. Anything not stamped by the
  /// current one has left the scene.
  uint64_t seen = 0;
};

/// How many floats one material's numbers occupy, and how many maps it has
/// room for. Both agree with the Dart side by hand; a mismatch is caught in
/// the plugin, which checks the array lengths before any of this is reached.
constexpr size_t kMaterialParams = 37;
constexpr size_t kMaterialMaps = 7;

/// The maps a lit surface has, in the order the Dart side packs them.
///
/// At file scope because two places need them and a second copy is how the
/// blend maps came to be missing from one of them: a material that had never
/// been given them left two samplers unset, which Filament reports on every
/// draw. Hundreds of lines a second, for a surface that was drawing correctly.
/// One of a model's files: what the glTF calls it, where it is, and its bytes
/// once they have been read.
struct Wanted {
  const char *uri;
  std::string path;
  void *bytes;
  size_t size;
};

/// Reads one file whole, or leaves it null.
///
/// Null is not an error here — it is the answer to "is this file there",
/// which is what the caller is asking. A model that names four hundred
/// textures and finds none of them still loads, and still draws, in black.
///
/// Read, not mapped. Mapping looks like the frugal choice — the pages are
/// backed by the file and the system can evict them — but every page then
/// arrives as a fault when the decoder touches it, and paging four hundred
/// files in sixteen kilobytes at a time measured 2226 ms against 542 ms for
/// reading them. This data is read once, immediately, in full: the access
/// pattern a plain read is for.
inline void readWholeFile(Wanted &one) {
  orbis::readWholeFile(one.path, &one.bytes, &one.size);
}

constexpr const char *kMapNames[kMaterialMaps] = {
    "baseColorMap", "normalMap",         "metallicRoughnessMap",
    "occlusionMap", "emissiveMap",       "blendBaseColorMap",
    "blendMaskMap"};
constexpr const char *kMapFlags[kMaterialMaps] = {
    "hasBaseColorMap", "hasNormalMap",      "hasMetallicRoughnessMap",
    "hasOcclusionMap", "hasEmissiveMap",    "hasBlendBaseColorMap",
    "hasBlendMaskMap"};

/// One material as the renderer holds it between frames.
///
/// The instance is the expensive part and the flags decide which compiled
/// material it has to come from, so a change of flags is a rebuild and a
/// change of numbers is a handful of uniform writes. Keeping both here is
/// what lets those be told apart without asking Filament anything.
struct Surfaced {
  filament::MaterialInstance *instance = nullptr;
  int32_t flags = -1;
  float params[kMaterialParams] = {};
  int32_t maps[kMaterialMaps] = {-1, -1, -1, -1, -1, -1, -1};
  bool written = false;
  uint64_t seen = 0;
};

/// How many floats one video contributes to the message.
constexpr size_t kVideoParams = 4;

/// One video as the renderer holds it between frames.
///
/// The frame never becomes an ordinary texture. It stays the buffer the
/// decoder wrote and is handed to the GPU where it lies, which is the whole
/// reason a screen in the scene costs about as much as a flat colour.
struct Movie {
  /// What decodes it, from the platform layer. Null while nothing is open,
  /// and always null where the platform has no decoder yet.
  std::unique_ptr<orbis::VideoDecoder> decoder;
  filament::Texture *texture = nullptr;

  std::string path;
  int32_t flags = -1;
  float rate = 1.0f;
  float volume = 1.0f;
  int32_t seekToken = -1;
  bool looping = false;
  uint64_t seen = 0;
};

/// How many floats one probe takes on the wire. Must match
/// `OrbisProbe.stride` on the Dart side and `probeStride` in the plugin.
constexpr uint32_t kProbeStride = 8;

/// One reflection probe as the renderer holds it between frames.
struct Probe {
  /// What the six faces were drawn into, and what the filter made of it. The
  /// captured cube is kept as well as the filtered one because a re-capture
  /// can reuse it rather than allocating a second time.
  filament::Texture *captured = nullptr;
  /// One render target per face, kept for as long as the cube is.
  ///
  /// Not built and thrown away around each render: Filament records a draw
  /// and performs it later, so a target destroyed on the line after the
  /// render is destroyed before the render happens, and the face comes back
  /// empty. The same trap as a buffer descriptor freed too early.
  filament::RenderTarget *faces[6] = {};
  /// One depth buffer, shared by all six faces: they are drawn one after
  /// another and none of them needs the last one's depth. A colour attachment
  /// on its own is a target with nothing to depth-test against, and what
  /// comes back is the clear colour and nothing else.
  filament::Texture *depth = nullptr;
  filament::Texture *filtered = nullptr;
  filament::IndirectLight *light = nullptr;

  filament::math::float3 position = {0, 0, 0};
  float radius = 0.0f;
  float intensity = 1.0f;
  uint32_t resolution = 0;
  /// The version last captured at. A different one on the wire is the host
  /// saying the room has changed.
  int32_t captured_at = -1;

  /// Set when the version moves, cleared when the photograph is taken.
  ///
  /// A capture cannot happen where it is asked for. The scene arrives a piece
  /// at a time — objects, then lights, then the sky — so a probe captured the
  /// moment it is mentioned photographs a room with no sky in it and comes
  /// back black. It waits for the start of the next frame, by which point the
  /// scene is whole.
  bool wants_capture = false;
  uint8_t capture_layers = 0xFF;
  uint64_t seen = 0;
};
/// How many floats a world-space irradiance field takes on the wire. Must
/// match `OrbisField.stride` on the Dart side and `fieldStride` in the plugin.
constexpr uint32_t kFieldStride = 14;

/// A probe's tile in the atlas, and how many of those fit across it.
///
/// Eight texels: six of directions with a one-texel gutter each side. The
/// gutter carries a mirrored copy of the interior edge so that a bilinear
/// read across the seam of the octahedron lands on the direction actually
/// next to it rather than on the neighbouring probe's tile.
constexpr uint32_t kFieldTile = 8;
constexpr uint32_t kFieldTilesPerRow = 16;

/// How much of the light going round the feedback loop is passed on.
///
/// A field reads the picture the scene drew, and that picture already holds
/// what the field put into it, so the light goes round: field lights room,
/// room is photographed, photograph lights field. Each lap multiplies by the
/// surfaces' albedo and by the strength the host asked for, and an infinite
/// series of that converges only while the product stays below one.
constexpr float kFieldDamping = 0.6f;

/// The largest product of damping and strength that stays convergent.
///
/// Measured in a room with a red wall and a blue one, over six hundred
/// frames: the light that arrives matches what was asked for to within three
/// per cent up to a strength of four, is ten per cent over at five, and
/// **fifty-seven** per cent over at six — and it does not fail by getting
/// brighter, it fails by drifting in hue, because the channel with the
/// highest gain wins the race. One point eight is the last fully linear
/// point with a whole step of margin under the knee.
constexpr float kFieldSafeGain = 1.8f;

/// The most probes a field may hold. A thousand is a large room at two-metre
/// spacing, and the atlas for it is 128 by 512.
constexpr uint32_t kFieldMaxProbes = 1024;

/// How many floats one light takes on the wire.
///
/// Must match `OrbisLight.stride` on the Dart side and `lightStride` in the
/// plugin. Used for both the offset into the message and the size of the copy
/// kept per light, so those two cannot drift apart again — they already did
/// once: the halo fields took a light from sixteen floats to eighteen, the
/// kept copy followed and the offset did not, and every light after the first
/// read a mixture of the one before it and itself.
constexpr uint32_t kLightStride = 22;

/// How many rectangular area lights one view shades.
///
/// They cost differently from Filament's own lights: a rectangle is a polygon
/// integral inside the surface shader, paid by every lit fragment, and there
/// is no culling in front of it. Sixteen is a room with a wall of windows,
/// and the number at which the loop is still cheaper than the alternative.
constexpr uint32_t kAreaLightBudget = 16;

/// How many texels one rectangle occupies: centre, radiance, the two edges
/// with their lengths, whether it casts, and the matrix that says what it
/// could see when it looked.
///
/// The last five are only read for a rectangle that casts, which is why they
/// sit after the four every rectangle needs rather than among them.
constexpr uint32_t kAreaLightTexels = 9;

/// How wide the one shadow map is, in pixels.
///
/// One map, not an atlas, and one casting rectangle rather than sixteen. A
/// scene has one key light and the rest are fill; giving every rectangle a
/// map would cost sixteen scene renders a frame to shadow lights whose whole
/// job is to not be noticed. The second one asked is reported rather than
/// silently ignored.
constexpr uint32_t kAreaShadowSide = 1024;

/// How big every decal's picture is once it is in the array, and how many
/// different pictures one view can hold.
///
/// One size for all of them because a texture array's layers share one: a
/// picture is resampled to this square on the way in. Five hundred and
/// twelve is a poster read from across a room; sixteen of them with their
/// mips is twenty-two megabytes, reserved only once a scene names a picture.
constexpr uint32_t kDecalPictureSide = 512;
constexpr uint32_t kDecalPictureLayers = 16;
constexpr uint32_t kDecalPictureLevels = 10;

/// How many compiled surfaces there are: three shading models in five blend
/// modes, and the shadow catcher on the end.
constexpr int kShadowCatcherSurface = 15;
constexpr int kSurfaceCount = 16;

/// One light as the renderer holds it between frames.
///
/// The whole parameter block is kept rather than the fields that matter,
/// because comparing sixty-four bytes is cheaper than a dozen setter calls
/// that each dirty something downstream.
struct Lit {
  utils::Entity entity;
  int32_t kind = -1;
  int32_t flags = -1;
  float params[kLightStride] = {};
  bool applied = false;
  uint64_t seen = 0;
};

/// The ambient the scene starts with: the skybox's own colour, so an
/// unconfigured scene is lit by the sky it appears to be standing under.
constexpr float3 kDefaultAmbient = {0.10f, 0.12f, 0.16f};
constexpr float kDefaultAmbientIntensity = 28000.0f;


/// Two surfaces, alternated. Filament finishes writing one while Flutter's
/// raster thread samples the other, so a frame is never read while it is being
/// drawn. Each needs its own swap chain because a Filament swap chain is bound
/// to one CVPixelBuffer for its lifetime.
constexpr int kOrbisBufferCount = 2;

/// What an object's flag bits mean. Matches OrbisObject on the Dart side.
constexpr int32_t kCastsShadows = 1;
constexpr int32_t kReceivesShadows = 2;
constexpr int32_t kVisible = 4;

/// Hiding is a layer the view does not draw rather than a removal from the
/// scene: the object keeps its entity, its material and its instance, so
/// showing it again is one byte written instead of a rebuild.
///
/// The low seven bits are the author's own layers, one bit each, and the top
/// one is hidden. That split is why an object that has never heard of layers
/// still lands on bit nought and is still drawn by a pass that asks for
/// everything: what used to be "the visible layer" is now "layer nought", and
/// the two are the same byte.
constexpr uint8_t kVisibleLayer = 0x01;
constexpr uint8_t kHiddenLayer = 0x80;
constexpr uint8_t kAllLayers = 0x7F;
constexpr int32_t kLayerShift = 8;
constexpr int32_t kLayerMask = 0x07;

/// The layer bit an object's flags ask for.
inline uint8_t layerBitOf(int32_t flags) {
  return static_cast<uint8_t>(1u << ((flags >> kLayerShift) & kLayerMask));
}

/// How many floats a pass and a target take on the wire. Must match
/// OrbisRenderGraph on the Dart side.
constexpr uint32_t kPassStride = 13;
constexpr uint32_t kTargetStride = 6;

/// How many passes a frame may have. Matches OrbisRenderGraph.maxPasses; a
/// graph past it has run away rather than grown.
constexpr uint32_t kMaxPasses = 32;

/// What a pass is for. Matches OrbisPassKind.
constexpr int kPassScene = 0;
constexpr int kPassReflection = 1;
/// A material run over every pixel of what another pass drew. The rails every
/// screen-space effect rides on: read a target, write a target, draw one
/// triangle over the lot.
constexpr int kPassEffect = 2;

/// Which effect, matching OrbisEffect. Minus one is none.
constexpr int kEffectSharpen = 0;
constexpr int kEffectSmaaEdges = 1;
constexpr int kEffectSmaaWeights = 2;
constexpr int kEffectSmaaBlend = 3;
constexpr int kEffectBounce = 4;
constexpr int kEffectCopy = 5;
// Motion blur hook. Appended rather than inserted, so every effect before it
// keeps its number: the effect crosses as its index, and an index that drifts
// runs a different shader rather than failing. motion_blur_test checks it.
constexpr int kEffectMotionBlur = 8;  // god rays are 6 and distortion 7, in ScreenEffects.h

/// Where a material's texture says it comes from a pass rather than a file.
static const char *const kTargetScheme = "orbis:target/";

/// How many punctual lights Filament shades in one view before it starts
/// dropping the ones furthest from the camera. Worth saying out loud: a light
/// that quietly stops working is a long afternoon.
constexpr uint32_t kPunctualLightBudget = 256;

/// The key the placeholder cube is filed under while no host owns the scene.
/// Far out of the way of anything a host would count from.
constexpr int64_t kPlaceholderKey = INT64_MIN;

struct Vertex {
  float3 position;
  quatf tangents;

  /// Where the corner sits on its face. The standard surface asks for texture
  /// coordinates whether the material has a map or not — a shader either
  /// declares an attribute or it does not — so even the placeholder cube
  /// carries them, and a texture put on one lands square on each face.
  float2 uv;
};

/// A corner of one sheet of mist: where it is, and where it sits across the
/// sheet so the edges can be faded out.
struct MistVertex {
  float3 position;
  float2 uv;
};

/// The sheet, lying flat and two metres across, which the transform then makes
/// as wide as the weather needs to be.
constexpr MistVertex kMistCorners[4] = {
    {{-1, 0, -1}, {0, 0}},
    {{1, 0, -1}, {1, 0}},
    {{1, 0, 1}, {1, 1}},
    {{-1, 0, 1}, {0, 1}},
};

constexpr uint16_t kMistIndices[6] = {0, 1, 2, 2, 3, 0};

/// How many sheets a bank is drawn with.
///
/// Ten is enough that a bank reads as depth from a shallow angle and few
/// enough that the screen is only covered ten times over. Every one of them is
/// a full-screen pass of four-octave noise, which is the whole cost of this.
constexpr int kMistSheets = 10;

/// How finely the sky dome is divided, and how big it is.
///
/// The dome is only somewhere to put pixels: the cloud is worked out per
/// pixel from where that pixel's view ray crosses a flat layer, so the mesh
/// needs enough triangles to interpolate a direction smoothly and no more.
constexpr int kSkyRings = 10;
constexpr int kSkySegments = 32;
constexpr float kSkyRadius = 900.0f;

/// How many panes a curtain of rain is drawn with, and how far in front of
/// the camera each one hangs.
///
/// Three, at three depths, because one pane is a flat pattern and the eye
/// reads depth from things moving past each other at different rates.
constexpr int kRainCurtains = 3;
constexpr float kRainDistances[kRainCurtains] = {2.5f, 7.0f, 18.0f};

/// How far a bank reaches, in metres. Centred on the camera, so it is always
/// around whoever is looking rather than somewhere in the world they might
/// walk out of.
constexpr float kMistReach = 260.0f;

// A unit cube with four vertices per face, so every face keeps a flat normal
// and the lighting reads as six distinct planes rather than a smooth blob.
constexpr float3 kPositions[24] = {
    {-1, -1, 1},  {1, -1, 1},   {1, 1, 1},    {-1, 1, 1},    // +Z
    {1, -1, -1},  {-1, -1, -1}, {-1, 1, -1},  {1, 1, -1},    // -Z
    {1, -1, 1},   {1, -1, -1},  {1, 1, -1},   {1, 1, 1},     // +X
    {-1, -1, -1}, {-1, -1, 1},  {-1, 1, 1},   {-1, 1, -1},   // -X
    {-1, 1, 1},   {1, 1, 1},    {1, 1, -1},   {-1, 1, -1},   // +Y
    {-1, -1, -1}, {1, -1, -1},  {1, -1, 1},   {-1, -1, 1},   // -Y
};

constexpr float3 kNormals[24] = {
    {0, 0, 1},  {0, 0, 1},  {0, 0, 1},  {0, 0, 1},
    {0, 0, -1}, {0, 0, -1}, {0, 0, -1}, {0, 0, -1},
    {1, 0, 0},  {1, 0, 0},  {1, 0, 0},  {1, 0, 0},
    {-1, 0, 0}, {-1, 0, 0}, {-1, 0, 0}, {-1, 0, 0},
    {0, 1, 0},  {0, 1, 0},  {0, 1, 0},  {0, 1, 0},
    {0, -1, 0}, {0, -1, 0}, {0, -1, 0}, {0, -1, 0},
};

constexpr uint16_t kIndices[36] = {
    0,  1,  2,  2,  3,  0,  4,  5,  6,  6,  7,  4,
    8,  9,  10, 10, 11, 8,  12, 13, 14, 14, 15, 12,
    16, 17, 18, 18, 19, 16, 20, 21, 22, 22, 23, 20,
};

/// One image a pass draws into, and everything needed to keep it.
///
/// Rebuilt when its size changes and not otherwise: a render target is a
/// texture, a depth buffer and a piece of driver state, and reallocating all
/// three on a frame where nothing moved is the sort of cost that only shows
/// up as a stutter while somebody drags a window.
struct GraphTarget {
  std::string name;
  uint32_t width = 0;   // zero follows the view
  uint32_t height = 0;
  float scale = 1.0f;
  bool keepsDepth = true;
  bool keepsColour = true;

  filament::Texture *colour = nullptr;
  filament::Texture *depth = nullptr;
  filament::RenderTarget *target = nullptr;
  uint32_t builtWidth = 0;
  uint32_t builtHeight = 0;
};

/// One material sampler that reads what a pass drew.
///
/// Kept so the renderer can put it right by itself. A target that follows the
/// view is a new texture every time the window changes, and a host is under
/// no obligation to publish again afterwards — a static scene never does. The
/// binding has to be renewed by whoever rebuilt the texture.
struct TargetBinding {
  filament::MaterialInstance *instance = nullptr;
  std::string parameter;
  std::string target;
};

/// A target texture that is no longer wanted but may still be bound.
struct RetiredTexture {
  filament::Texture *texture = nullptr;
  uint64_t afterGeneration = 0;
};

/// One step of a frame, as the renderer holds it.
struct GraphPass {
  int kind = kPassScene;
  int into = -1;  // an index into the targets, or -1 for the frame
  uint8_t layers = kAllLayers;
  bool clears = true;
  float plane[4] = {0.0f, 1.0f, 0.0f, 0.0f};

  /// Which screen-space effect, for an effect pass. -1 for every other kind.
  int effect = -1;

  /// The targets this pass samples, as indices, or -1. An effect reads the
  /// first of them that was actually built.
  int reads[4] = {-1, -1, -1, -1};

  /// The one triangle an effect pass draws, and what it is dressed in. Built
  /// on first use and kept, because a pass runs every frame.
  filament::Scene *effectScene = nullptr;
  utils::Entity effectEntity;
  filament::MaterialInstance *effectMaterial = nullptr;

  /// The view this pass renders through, for a pass that draws into a target.
  /// The frame pass uses the renderer's own view.
  filament::View *view = nullptr;
  filament::Camera *camera = nullptr;
  utils::Entity cameraEntity;

  /// What it cost last frame, in milliseconds, and how much it drew.
  double milliseconds = 0;
  int drawn = 0;
};

/// The matrix that mirrors the world in a plane.
///
/// `n` is the plane's normal and `d` its distance from the origin, so that a
/// point on it satisfies dot(n, p) + d = 0. Reflecting about it is what turns
/// a camera into the camera behind the glass, which is the whole of how a
/// planar reflection is drawn: the same scene, the same lights, one matrix
/// different.
inline filament::math::mat4f reflectionAbout(const float plane[4]) {
  using filament::math::float3;
  using filament::math::float4;
  using filament::math::mat4f;

  float3 n{plane[0], plane[1], plane[2]};
  const float length = std::sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
  // A plane with no normal is not a plane. Standing the camera still is a
  // reflection of nothing, which is visibly wrong and does not divide by zero.
  if (length < 1e-6f) return mat4f();
  n = n / length;
  const float d = plane[3] / length;

  mat4f mirror;
  mirror[0] = float4{1 - 2 * n.x * n.x, -2 * n.x * n.y, -2 * n.x * n.z, 0};
  mirror[1] = float4{-2 * n.x * n.y, 1 - 2 * n.y * n.y, -2 * n.y * n.z, 0};
  mirror[2] = float4{-2 * n.x * n.z, -2 * n.y * n.z, 1 - 2 * n.z * n.z, 0};
  mirror[3] = float4{-2 * n.x * d, -2 * n.y * d, -2 * n.z * d, 1};
  return mirror;
}

/// How many post-processing numbers the renderer will read.
///
/// Larger than the description needs, so a host built against a newer version
/// sending more of them is ignored from here on rather than reading past the
/// end of the array.
constexpr size_t kMaxPostParams = 128;

/// What one pass of the last frame cost, in milliseconds, and how many
/// renderables it submitted.
struct PassTiming {
  double milliseconds = 0;
  int drawn = 0;
};

class Renderer {
 public:
  /// Takes ownership of `surface`, which is where frames are presented, and
  /// remembers which backend to ask for. Nothing starts until initWithWidth.
  Renderer(OrbisSurface *surface, OrbisBackend backend);
  ~Renderer();
  Renderer(const Renderer &) = delete;
  Renderer &operator=(const Renderer &) = delete;

  /// Starts Filament and allocates buffers. False if the backend would not
  /// start or Filament refused, with the reason logged.
  bool initWithWidth(uint32_t width, uint32_t height);

  // OrbisRenderer.h's interface in C++ types, in the order it declares them.
  // The documentation there is the documentation of these.
  void renderAtTime(double time);
  void applyObjects(const int64_t *keys, const float *transforms,
                    const float *colours, const int32_t *meshes,
                    const int32_t *flags, const int32_t *materials,
                    const int32_t *morphCounts, const float *morphWeights,
                    const std::vector<std::string> &paths, uint32_t count);
  void setBatching(bool enabled);
  uint32_t batchedObjects();
  uint32_t batchGroups();
  void applyMaterials(const int64_t *keys, const int32_t *flags,
                      const float *params, const int32_t *maps,
                      const std::vector<std::string> &texturePaths,
                      const int32_t *textureSrgb, const int32_t *videos,
                      uint32_t count);
  void setPipeline(const float *params, size_t count);
  void applyVideos(const int64_t *keys, const int32_t *flags,
                   const float *params, const std::vector<std::string> &paths,
                   uint32_t count);
  void applyLights(const int64_t *keys, const int32_t *kinds,
                   const int32_t *flags, const float *params, uint32_t count);
  void applyDecals(const float *params, const int32_t *images,
                   const std::vector<std::string> &paths, uint32_t count);
  void setFogEnabled(bool enabled, const float *params);
  void setPostProcess(const float *params, size_t count);
  void applyProbes(const int64_t *keys, const float *params, uint32_t count);
  void applyField(const float *params, const std::string &from);
  void setEnvironmentRadiance(const std::string &radiance,
                              const std::string &skybox, const float *params);
  void setRenderGraph(const float *passes, uint32_t count,
                      const float *targets, uint32_t targetCount,
                      const std::vector<std::string> &names);
  // Hook (screen effects): the host's god-ray and distortion settings.
  void setGodRays(const float *godRays, size_t count,
                  const float *distortions, size_t distortionCount);
  std::vector<PassTiming> passTimings();
  double gpuMilliseconds();
  double cpuMilliseconds();
  bool hasPopulations();
  void applyPopulations(const int32_t *keys, const int32_t *counts,
                        const int32_t *meshes, const int32_t *flags,
                        const int32_t *revisions, const float *ranges,
                        const float *bounds,
                        const std::vector<std::string> &paths,
                        const int32_t *changed, uint32_t changedCount,
                        const float *transforms, const float *colours,
                        uint32_t count);
  bool hasSplats();
  void applySplats(const int32_t *keys, const int32_t *flags,
                   const int32_t *revisions, const float *params,
                   const std::vector<std::string> &paths,
                   const int32_t *changed, const int32_t *changedCounts,
                   uint32_t changedCount, const uint8_t *data,
                   size_t dataLength, uint32_t count);
  void setSkyEnabled(bool enabled, const float *params);
  void setPrecipitationEnabled(bool enabled, const float *params);
  Notes notes();
  void setSkyColour(const float *colour, float ambient, bool showBody);
  void setCameraPosition(const float *position, const float *target,
                         float fieldOfView, bool orthographic,
                         float viewHeight, double at);
  void setExposure(float aperture, float shutter, float sensitivity);
  void setOutlineKeys(const int64_t *keys, uint32_t count,
                      const float *params);
  void resizeToWidth(uint32_t width, uint32_t height);

  /// The most recently presented frame with a reference the caller owns, or
  /// null before the first one. Opaque: on Apple it is a CVPixelBufferRef.
  void *copyPresentedBuffer();

  /// Tears down Filament. Idempotent; the renderer is inert afterwards.
  void dispose();

  /// Which backend the engine was built with, once it has been.
  OrbisBackend backend() const { return _backend; }

  /// Asks for the next frame drawn to be read back into memory as well as
  /// presented. For a host with nowhere to present to — a test, a server, a
  /// console tool — this is the picture.
  void requestCapture();

  /// The last frame read back, as RGBA8 with the top row first. False until
  /// one has arrived, which is a frame or two after it was asked for.
  bool capturedFrame(std::vector<uint8_t> &rgba, uint32_t &width,
                     uint32_t &height);

 private:
  void startWithWidth(uint32_t width, uint32_t height);
  void buildGeometry();
  void buildQuad();
  void buildMist();
  void updateMistAtTime(double time);
  void buildClouds();
  void updateCloudsAtTime(double time);
  void buildRain();
  void updateRainAtTime(double time);
  void setAmbientColour(float3 colour, float intensity);
  void startAssetLoader();
  Mesh *meshAtPath(const std::string &path);
  gltfio::FilamentInstance *takeInstanceOf(Mesh *mesh);
  void recycle(Drawn &drawn);
  void removeEverything();
  void applyFlags(int32_t flags, utils::Entity entity);
  void morph(const Drawn &drawn, const float *weights, size_t count);
  void applyFlags(int32_t flags, const Drawn &drawn);
  void build(Drawn &drawn, const std::string &path);
  void clearPopulation(Grown &grown);
  filament::InstanceBuffer *identityInstances();
  void growPopulation(Grown &grown, uint32_t count, const float *bounds, int32_t flags);
  void sortPopulation(Grown &grown, const float *transforms);
  void fillPopulation(Grown &grown, const float *transforms, const float *colours);
  void rangePopulations();
  int surfaceIndexFor(int32_t flags);
  Material *surfaceAt(int index);
  Texture *blankTexture();
  void setDefaultsOn(MaterialInstance *instance);
  float fieldStrength();
  void bindFieldEverywhere();
  void bindFieldTo(MaterialInstance *instance);
  Texture *textureAtPath(const std::string &path, bool srgb);
  void pollTextures();
  TextureSampler samplerFor(int32_t flags);
  void write(Surfaced &surface, const float *params, const int32_t *maps, const std::vector<std::string> &texturePaths, const int32_t *textureSrgb, int32_t video);
  void applyRasterState(Surfaced &surface, float threshold, float bias);
  void open(Movie &movie, const std::string &path);
  void close(Movie &movie);
  Texture *cubemapAtPath(const std::string &path, float3 *harmonics, bool *hasThose, const std::string &note);
  void rebuildEnvironmentLight();
  void releaseEnvironment();
  void prepareTargets();
  void rebindTargets();
  void buildSmaaTables();
  void packRectangle(const float *p, float *out, bool casting);
  void uploadRectangles(const float *rectangles, uint32_t count);
  void renderAreaShadow();
  void buildAreaShadow();
  bool aimAreaShadowAt(const float *p);
  void buildLtcTables();
  filament::Material *materialForEffect(int effect);
  bool buildEffect(GraphPass &pass);
  void applyPostTo(View *view);
  void runEffect(GraphPass &pass, GraphTarget *into);
  View *viewForPass(GraphPass &pass);
  void aimPass(GraphPass &pass, uint32_t wide, uint32_t tall);
  void releaseTarget(GraphTarget &target);
  void sweepRetiredTextures();
  void releaseGraph();
  Texture *targetTextureNamed(const std::string &name);
  void shadowOptionsFor(utils::Entity entity);
  void refreshShadowOptions();
  void pumpVideos();
  void dress(Drawn &drawn, int32_t index);
  void sweepUnnamedMeshes();
  void writeLight(const Lit &lit);
  void buildDecalData();
  void bindDecalsTo(MaterialInstance *instance);
  void bindDecalsEverywhere();
  int32_t decalLayerFor(const std::string &path, Notes &notes, bool *uploaded);
  void capture(Probe &probe, uint8_t layers);
  void releaseProbe(Probe &probe);
  void captureOwedProbes();
  void chooseProbe();
  bool buildField();
  void runField();
  void releaseField();
  void applyGrading(bool enabled, int toneMapper, float exposure, float contrast, float saturation, float vibrance, float temperature, float tint, const float *shadows, const float *midtones, const float *highlights);
  void placeCamera();
  void projectWith(float fieldOfView, bool orthographic, float tall);
  void allocateBuffers();
  void releaseBuffers();
  void applyViewportSize();
  void drawOutline();
  void renderPasses();
  void drawAtTime(double time);

  /// Reads the frame being drawn back into memory, if one was asked for.
  /// Between the passes and endFrame, which is the only place Filament will
  /// read a swap chain.
  void readBackIfAsked();

  /// Which backend a host asked for, and which one the engine was built with.
  OrbisBackend _backendAsked = ORBIS_BACKEND_DEFAULT;
  OrbisBackend _backend = ORBIS_BACKEND_DEFAULT;

  /// Videos this platform could not open. Replaced on every publish.
  Notes _videoNotes;

  /// A frame read back for requestCapture, and whether one is wanted, in
  /// flight, or ready. Written by Filament's callback, read by the host.
  std::mutex _captureLock;
  bool _captureWanted = false;
  bool _captureInFlight = false;
  bool _captureReady = false;
  std::vector<uint8_t> _captured;
  uint32_t _capturedWidth = 0;
  uint32_t _capturedHeight = 0;

  // ---- What was the ivar block of @implementation OrbisRenderer ----
  Engine *_engine{};

  /// The colour grading currently on the view.
  ///
  /// A resource with a baked lookup table rather than a struct, so it is kept
  /// and rebuilt only when the numbers move.
  ColorGrading *_colorGrading{};

  /// The post-processing numbers as last applied, so a frame that changes
  /// nothing costs a memcmp rather than a dozen option rebuilds.
  float _postParams[kMaxPostParams]{};
  size_t _postCount{};

  /// Just the grading numbers, compared separately: the rest of the options
  /// are cheap to set and this one bakes a lookup table.
  float _gradingParams[17]{};
  filament::Renderer *_renderer{};
  Scene *_scene{};
  View *_view{};
  Camera *_camera{};
  utils::Entity _cameraEntity{};

  /// Everything in the scene, by the key its host gave it. This map is the
  /// whole reason a drag is cheap: it is what lets a publish be read as "these
  /// three moved" rather than "here is a new scene".
  std::unordered_map<int64_t, Drawn> _drawn{};
  std::unordered_map<int64_t, Lit> _lit{};

  /// Stamps for the mark-and-sweep. One counter each, because objects and
  /// lights arrive in separate calls.
  uint64_t _objectGeneration{};
  uint64_t _lightGeneration{};

  /// Whether identical objects are merged into instanced draws. See
  /// OrbisBatching.h for what that means here and why it is mostly a question
  /// of what objects are made of.
  bool _batching{};
  orbis::BatchCensus _census{};
  orbis::ColourPool<filament::MaterialInstance> _colourPool{};

  /// What the last publish batched: objects in a group large enough to merge,
  /// and how many groups. Nought while batching is off.
  uint32_t _batchedObjects{};
  uint32_t _batchGroups{};

  gltfio::AssetLoader *_assetLoader{};
  gltfio::ResourceLoader *_resourceLoader{};
  gltfio::MaterialProvider *_materialProvider{};
  gltfio::TextureProvider *_stbTextures{};

  /// A second decoder, for the images materials name directly.
  ///
  /// Separate from the one the glTF loader uses because a provider is a
  /// queue: popping from it takes ownership of whatever comes out, and
  /// popping a texture the resource loader was waiting for would leave a
  /// model with a missing map and no way to find out why.
  gltfio::TextureProvider *_ownStbTextures{};
  gltfio::TextureProvider *_ownKtxTextures{};

  /// The compiled surfaces, indexed by shading and blend mode. Built on
  /// first use: a scene of opaque lit objects should not compile the four
  /// blending variants it never draws.
  filament::Material *_surfaces[kSurfaceCount]{};

  /// Every material the host has named, by its key.
  std::unordered_map<int64_t, Surfaced> _materials{};

  /// This frame's materials in the order they arrived, which is what an
  /// object's index points into. Rebuilt each publish; never outlives one.
  std::vector<filament::MaterialInstance *> _materialOrder{};

  /// Which of them were built afresh this publish, so the objects wearing
  /// them are re-dressed rather than left pointing at what was destroyed.
  std::vector<bool> _materialRebuilt{};

  /// Instances no material needs any more.
  ///
  /// Destroyed at the start of the *next* publish rather than this one. An
  /// object still wearing one is not put right until objects are applied,
  /// which happens after materials — so destroying them here would leave a
  /// renderable pointing at freed memory for the rest of the call.
  std::vector<filament::MaterialInstance *> _materialsSpent{};

  /// Images loaded for materials, by path and colour space — the same file
  /// read as sRGB and as linear is two textures, and asking for one when the
  /// other is loaded would be a silent wrong answer.
  std::unordered_map<std::string, filament::Texture *> _ownTextures{};

  /// Whether any of those are still decoding, so the queue is only polled
  /// while there is something in it.
  int _texturesPending{};

  /// How many frames the decoders have been asked and given nothing back.
  int _pollsWithoutProgress{};

  /// One white pixel, standing in for every map a material does not set.
  filament::Texture *_blankTexture{};

  /// An external image that never gets one, for a screen with no video on it
  /// yet. Filament wants every sampler bound whether the shader reads it or
  /// not, and a screen showing nothing is a legitimate state to be in.
  filament::Texture *_blankExternal{};

  /// How the frame is put together, already in the order it runs.
  ///
  /// Empty until a host says otherwise, which is read as the ordinary frame:
  /// one pass, every layer, straight into the picture. Empty rather than a
  /// default row, so that "nobody has said" and "somebody asked for exactly
  /// this" are not the same state.
  std::vector<GraphPass> _passes{};
  std::vector<GraphTarget> _targets{};

  /// Target textures given up but not yet destroyed, with the material
  /// generation they were given up in.
  std::vector<RetiredTexture> _retiredTextures{};

  /// Every material sampler currently reading a pass, rebuilt on each
  /// publish and replayed whenever a target is rebuilt.
  std::vector<TargetBinding> _targetBindings{};

  /// The place the scene is standing in, when a host has named one.
  ///
  /// Held apart from the flat ambient rather than replacing it, so that
  /// clearing an environment puts back the sky the day cycle had been
  /// writing rather than leaving the scene unlit.
  filament::IndirectLight *_environmentLight{};

  /// The reflections the scene has taken of itself, by key.
  std::unordered_map<int64_t, Probe> _probes{};

  /// The filter that turns a captured cube into the blurred chain a rough
  /// surface samples. Built once — it compiles its own materials and holds a
  /// kernel texture, so one per renderer rather than one per capture.
  /// The view and camera every capture is taken through, kept for the same
  /// reason the targets are: destroying them beside the render destroys them
  /// before it.
  filament::View *_captureView{};
  filament::Camera *_captureCamera{};

  IBLPrefilterContext *_prefilter{};
  IBLPrefilterContext::SpecularFilter *_specularFilter{};

  /// Which probe is lighting the scene, or zero for none.
  int64_t _activeProbe{};

  filament::Texture *_environmentRadiance{};
  filament::Texture *_environmentSkyTexture{};
  filament::Skybox *_environmentSkybox{};

  /// Whether the environment's backdrop is the one in the scene, so the
  /// procedural sky knows to stay out of the way.
  bool _showingEnvironmentSkybox{};
  std::string _environmentRadiancePath{};
  std::string _environmentSkyboxPath{};
  float _environmentParams[4]{};

  /// The diffuse harmonics read off the radiance cubemap, kept because
  /// Filament does not hand them back and the bundle they came from is freed
  /// as soon as the driver has taken the pixels. Turning an environment or
  /// dimming it rebuilds the light, and a rebuild without these is an
  /// environment that lights reflections and nothing matte.
  float3 _environmentHarmonics[9]{};
  bool _environmentHasHarmonics{};

  /// The last flat ambient asked for, kept so it can be put back when an
  /// environment is cleared. The day cycle writes this on every frame and
  /// would otherwise have to be waited for.
  float3 _ambientColour{0.0f, 0.0f, 0.0f};
  float _ambientIntensity{};

  /// The graph as last received, so a scene republished sixty times a second
  /// only rebuilds views and render targets when something in it moved.
  std::vector<float> _graphPassParams{};
  std::vector<float> _graphTargetParams{};
  std::vector<std::string> _graphTargetNames{};

  /// The last pipeline settings applied, so a scene republished sixty times
  /// a second only reconfigures the view when something actually moved.
  ///
  /// Larger than the block a current host sends, deliberately: a host that
  /// sends more is a newer one, and its extra floats are dropped rather than
  /// written past the end of this. The assertion is what keeps the two facts
  /// in step, because the truncation is silent and reads as a dial that has
  /// stopped working.
  float _pipelineParams[32]{};
  size_t _pipelineCount{};

  /// Every video the host has named, by its key.
  std::unordered_map<int64_t, Movie> _movies{};

  /// This frame's videos in the order they arrived, which is what a material
  /// points into.
  std::vector<Movie *> _movieOrder{};

  uint64_t _videoGeneration{};

  uint64_t _materialGeneration{};
  gltfio::TextureProvider *_ktxTextures{};

  /// Whether any asset is still decoding its textures. An ivar block takes
  /// no initialiser, so this is zeroed by the runtime like the rest.
  bool _loadingResources{};
  /// What the load in flight is, and when it started, for the timing report.
  std::string _loadingName{};
  size_t _loadingResourceCount{};
  double _loadingFrom{};

  /// Loaded glTF files, by path. Kept for the life of the renderer: a scene
  /// arrives on every drag, and the parse is the expensive part.
  std::map<std::string, Mesh> _meshes{};

  /// Sixty-four identity transforms, lent to every population draw. Built
  /// once, because every draw wants the same nothing.
  filament::InstanceBuffer *_identityInstances{};

  /// One material per effect, built on first use and shared by every pass
  /// that runs it. Indexed by the effect's own number.
  std::map<int, filament::Material *> _effectMaterials{};

  /// Hook (screen effects): what the host said about god rays and
  /// distortion, turned into material parameters when their pass runs.
  orbis::ScreenEffects _screenEffects{};
  /// Motion blur hook: what motion blur remembers between frames and the
  /// passes it runs. Made the first time a graph asks for the effect, so a
  /// renderer that never blurs allocates none of it.
  std::unique_ptr<orbis::MotionBlur> _motionBlur{};

  /// SMAA's two precomputed tables, uploaded once.
  /// The world-space irradiance field: two atlases, written in turn.
  ///
  /// Two because a probe's new value is a blend of what it just learned with
  /// what it already held, and a shader cannot read the texture it is writing.
  /// One is the answer being read this frame while the other is being built.
  filament::Texture *_fieldAtlas[2]{};
  filament::RenderTarget *_fieldTargets[2]{};
  int _fieldFront{};
  bool _fieldHasHistory{};
  uint32_t _fieldProbes{};

  /// The triangle the field is drawn with, and what draws it.
  filament::View *_fieldView{};
  filament::Camera *_fieldCamera{};
  filament::Scene *_fieldScene{};
  utils::Entity _fieldEntity{};
  filament::MaterialInstance *_fieldInstance{};
  filament::Material *_fieldMaterial{};

  float _fieldParams[kFieldStride]{};
  std::string _fieldFrom{};

  filament::Texture *_smaaArea{};
  filament::Texture *_smaaSearch{};

  /// The fitted tables every rectangular area light is shaded against, and
  /// this frame's rectangles. Both are built once and live as long as the
  /// renderer: the tables never change, and the lights are rewritten in
  /// place so that a material instance can bind the texture once and not
  /// care that its contents moved.
  /// The fitted tables and this frame's rectangles, in one texture.
  ///
  /// One rather than two because a material at Filament's first feature level
  /// may have nine samplers, and alongside the irradiance field's atlas these
  /// would have been the tenth. They share without interfering: the tables are
  /// read with filtering and the lights with texelFetch, which ignores it.
  /// The tables occupy the first 64 rows and the rectangles the ones below.
  filament::Texture *_lightData{};

  /// The one rectangle's depth map, and everything needed to draw it.
  ///
  /// A view and a camera of its own rather than the scene's, because what a
  /// light can see is a different picture from what the camera can: the same
  /// objects, a different frustum, and no shading worth doing — only how far
  /// away the nearest thing is in each direction.
  filament::Texture *_areaShadow{};
  filament::RenderTarget *_areaShadowTarget{};
  filament::View *_areaShadowView{};
  filament::Camera *_areaShadowCamera{};
  utils::Entity _areaShadowCameraEntity{};

  /// Where the casting rectangle stood when it last looked, and whether one
  /// is casting at all. Kept between frames because the surfaces read it out
  /// of the light data, which is written once per frame rather than per draw.
  filament::math::mat4f _areaShadowMatrix{};
  // Where the casting rectangle stood when its map was drawn: the near plane
  // and field of view the surface needs to turn map depth back into metres.
  orbis::AreaShadowFrame _areaShadowFrame{};
  bool _areaShadowCasting{};

  /// The rectangles as the GPU currently holds them, so a frame that changed
  /// none of them uploads nothing. Almost every scene has no area lights at
  /// all, and that scene should not pay a texture upload a frame to keep
  /// saying so.
  std::vector<float> _areaLightsOnGpu{};

  /// Decals: one row of numbers each, and one layer of picture each.
  ///
  /// The numbers are rewritten in place like the rectangles', so a surface
  /// binds the texture once. The pictures are built the first time a scene
  /// names one; until then surfaces are pointed at a one-texel stand-in,
  /// because Filament refuses to draw a material with a sampler nobody bound.
  filament::Texture *_decalData{};
  filament::Texture *_decalPictures{};
  filament::Texture *_decalBlankPictures{};
  std::vector<float> _decalsOnGpu{};

  /// Which layer each picture went into, by path. Negative for a picture
  /// that could not be read (-1) or found no room (-2): kept, so a missing
  /// file is looked for once rather than every frame.
  std::unordered_map<std::string, int32_t> _decalPictureLayer{};
  uint32_t _decalPictureCount{};
  Notes _decalNotes{};


  /// Assets that could not be loaded. Sticky, because a file is read once and
  /// a failure that reported itself only on the frame of the attempt would
  /// never be seen again.
  Notes _assetNotes{};

  /// What the current objects and lights add up to that the renderer cannot
  /// honour. Replaced on every publish, so fixing the scene clears it.
  Notes _objectNotes{};
  Notes _lightNotes{};

  bool _sceneIsOwnedByHost{};
  Skybox *_skybox{};
  IndirectLight *_ambient{};

  /// The sky as it currently stands. A day cycle changes it on every frame,
  /// and a skybox rebuilt sixty times a second is sixty allocations to say
  /// what one setter says.
  float3 _skyColour{0.0f, 0.0f, 0.0f};
  float _skyAmbient{};
  bool _skyShowsBody{};
  bool _skyBuilt{};

  /// Drawn many times over from one submission. Built the first time a scene
  /// has a population in it, because most have none.
  Material *_instancedMaterial{};
  std::unordered_map<int32_t, Grown> _populations{};
  uint64_t _populationGeneration{};

  /// Gaussian splat clouds. Everything about them is in OrbisSplatSet, in
  /// plain C++; this only holds it, feeds it the scene and the camera, and
  /// passes on what it could not load.
  std::unique_ptr<orbis::SplatScene> _splats{};
  Notes _splatNotes{};
  VertexBuffer *_vertexBuffer{};
  IndexBuffer *_indexBuffer{};

  /// The sheets a bank of mist is drawn with, and what they are made of.
  /// Built the first time a scene asks for weather and kept after that.
  Material *_mistMaterial{};
  VertexBuffer *_quadVertices{};
  IndexBuffer *_quadIndices{};
  std::vector<utils::Entity> _mistEntities{};
  std::vector<MaterialInstance *> _mistInstances{};

  /// The dome the sky's cloud is drawn on, and what it is made of.
  Material *_cloudMaterial{};
  VertexBuffer *_skyVertices{};
  IndexBuffer *_skyIndices{};
  utils::Entity _cloudEntity{};
  MaterialInstance *_cloudInstance{};
  bool _cloudsShowing{};

  /// The panes a curtain of rain or snow is drawn on.
  Material *_rainMaterial{};
  std::vector<utils::Entity> _rainEntities{};
  std::vector<MaterialInstance *> _rainInstances{};
  bool _rainShowing{};

  /// What the current weather is, so the sheets are only rewritten when it
  /// changes rather than on every frame.
  bool _mistShowing{};
  float _mistHeight{};
  float _mistThickness{};
  float3 _mistCentre{0.0f, 0.0f, 0.0f};

  OrbisSurface *_surface{};
  SwapChain *_swapChains[kOrbisBufferCount]{};
  int _backIndex{};
  int _presentedIndex{};

  uint32_t _width{};
  uint32_t _height{};
  uint32_t _pendingWidth{};
  uint32_t _pendingHeight{};
  float _fieldOfView{};
  bool _orthographic{};
  float _viewHeight{};

  /// The last two things the camera was told, and the lock between the thread
  /// that says them and the thread that draws.
  Aimed _aimedNow{};
  Aimed _aimedWas{};
  std::mutex _aimLock;
  double _clockOffset{};
  bool _clocksAligned{};

  /// How fast the camera is going, followed rather than measured fresh.
  float3 _aimVelocity{0.0f, 0.0f, 0.0f};
  float3 _lookVelocity{0.0f, 0.0f, 0.0f};
  float _lensVelocity{};
  bool _movingKnown{};

  /// The word this is currently predicting from, and how wrong the last
  /// prediction turned out to be — carried, and decaying.
  double _spokeAt{};
  float3 _spokePosition{0.0f, 0.0f, 0.0f};
  float3 _spokeTarget{0.0f, 0.0f, 0.0f};
  float3 _carriedPosition{0.0f, 0.0f, 0.0f};
  float3 _carriedTarget{0.0f, 0.0f, 0.0f};
  double _placedAt{};
  double _placedWas{};

  /// The usual gap between words, followed. A single gap is far too noisy to
  /// decide anything with.
  double _spanUsual{};
  float3 _toldFrom{0.0f, 0.0f, 0.0f};
  double _toldAt{};
  float _toldSpeedWas{};
  float _toldSpeedTotal{};
  float _toldJerkTotal{};
  int _toldCount{};
  double _reachedTotal{};
  int _reachedCount{};
  int _saturated{};
  bool _pacing{};
  double _gpuTotal{};
  int _gpuCount{};

  std::mutex _presentLock;
  bool _disposed{};
  int _frameCount{};
  double _startedAt{};
  float _skyFlash{};
  int _cameraUpdates{};
  double _pacedAt{};
  float3 _pacedFrom{0.0f, 0.0f, 0.0f};
  double _pacedFrameAt{};
  float _stepWas{};
  float _stepTotal{};
  float _jerkTotal{};
  int _stepCount{};
  bool _dumped{};

  /// The selection outline, made the first time something is highlighted
  /// and not before: a renderer nobody asks for an outline holds nothing
  /// for one.
  std::unique_ptr<orbis::Outline> _outline{};

  /// Which objects are highlighted, by key, the active ones first. Resolved
  /// to entities at the top of each frame rather than when they arrive,
  /// because an object can be rebuilt as a different mesh between the two.
  std::vector<int64_t> _outlineKeys{};
  uint32_t _outlinePrimaryCount{};
  orbis::OutlineStyle _outlineStyle{};
};

}  // namespace orbis
