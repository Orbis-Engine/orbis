#import "OrbisRenderer.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

#include <filament/ColorGrading.h>
#include <filament/Options.h>
#include <filament/Camera.h>
#include <filament/Engine.h>
#include <filament/IndexBuffer.h>
#include <filament/IndirectLight.h>
#include <filament/LightManager.h>
#include <filament/Material.h>
#include <filament/MaterialInstance.h>
#include <filament/RenderableManager.h>
#include <filament/RenderTarget.h>
#include <filament/Renderer.h>
#include <filament/Scene.h>
#include <filament/Skybox.h>
#include <filament/Texture.h>
#include <filament/TextureSampler.h>
#include <filament/SwapChain.h>

#import "OrbisSurface.h"
#include <filament/TransformManager.h>
#include <filament/VertexBuffer.h>
#include <filament/View.h>
#include <filament/Viewport.h>
#include <geometry/SurfaceOrientation.h>
#include <gltfio/AssetLoader.h>
#include <gltfio/FilamentAsset.h>
#include <gltfio/FilamentInstance.h>
#include <gltfio/MaterialProvider.h>
#include <gltfio/ResourceLoader.h>
#include <gltfio/TextureProvider.h>
#include <gltfio/materials/uberarchive.h>
#include <image/Ktx1Bundle.h>
#include <ktxreader/Ktx1Reader.h>
#include <math/mat4.h>
#include <utils/EntityManager.h>
#include <utils/Panic.h>

#include <map>
#include <string>
#include <unordered_map>
#include <vector>
#include <utils/Panic.h>

#include <algorithm>
#include <cmath>
#include <exception>

#include "generated/lit_opaque_material.h"
#include "generated/lit_transparent_material.h"
#include "generated/lit_fade_material.h"
#include "generated/lit_masked_material.h"
#include "generated/lit_add_material.h"
#include "generated/unlit_opaque_material.h"
#include "generated/unlit_transparent_material.h"
#include "generated/unlit_fade_material.h"
#include "generated/unlit_masked_material.h"
#include "generated/unlit_add_material.h"
#include "generated/video_opaque_material.h"
#include "generated/video_transparent_material.h"
#include "generated/video_fade_material.h"
#include "generated/video_masked_material.h"
#include "generated/video_add_material.h"
#include "generated/mist_material.h"
#include "generated/instanced_material.h"
#include "generated/shadowcatcher_material.h"
#include "generated/sky_material.h"
#include "generated/rain_material.h"


using namespace filament;
using namespace filament::math;

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
static uint64_t mortonOf(uint32_t x, uint32_t y, uint32_t z) {
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

  /// A mesh's own materials, kept from the moment one is overridden so that
  /// clearing the override puts the model back the way the file had it.
  /// Empty while nothing has been overridden, which is the usual case.
  std::vector<filament::MaterialInstance *> ownMaterials;

  /// The publish that last mentioned this object. Anything not stamped by the
  /// current one has left the scene.
  uint64_t seen = 0;
};

/// How many floats one material's numbers occupy, and how many maps it has
/// room for. Both agree with the Dart side by hand; a mismatch is caught in
/// the plugin, which checks the array lengths before any of this is reached.
constexpr size_t kMaterialParams = 19;
constexpr size_t kMaterialMaps = 5;

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
  int32_t maps[kMaterialMaps] = {-1, -1, -1, -1, -1};
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
  AVPlayer *player = nil;
  AVPlayerItemVideoOutput *output = nil;
  filament::Texture *texture = nullptr;

  /// The buffer currently on the GPU. Held until the next one replaces it:
  /// releasing it at the end of the frame that showed it would pull the
  /// picture out from under a draw that has not happened yet.
  CVPixelBufferRef showing = nullptr;

  std::string path;
  int32_t flags = -1;
  float rate = 1.0f;
  float volume = 1.0f;
  int32_t seekToken = -1;
  bool looping = false;
  id endObserver = nil;
  uint64_t seen = 0;
};

/// How many floats one light takes on the wire.
///
/// Must match `OrbisLight.stride` on the Dart side and `lightStride` in the
/// plugin. Used for both the offset into the message and the size of the copy
/// kept per light, so those two cannot drift apart again — they already did
/// once: the halo fields took a light from sixteen floats to eighteen, the
/// kept copy followed and the offset did not, and every light after the first
/// read a mixture of the one before it and itself.
constexpr uint32_t kLightStride = 18;

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
static constexpr float3 kDefaultAmbient = {0.10f, 0.12f, 0.16f};
static constexpr float kDefaultAmbientIntensity = 28000.0f;

namespace {

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
constexpr uint32_t kPassStride = 12;
constexpr uint32_t kTargetStride = 6;

/// How many passes a frame may have. Matches OrbisRenderGraph.maxPasses; a
/// graph past it has run away rather than grown.
constexpr uint32_t kMaxPasses = 32;

/// What a pass is for. Matches OrbisPassKind.
constexpr int kPassScene = 0;
constexpr int kPassReflection = 1;

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

}  // namespace

@interface OrbisRenderer ()
- (void)startWithWidth:(uint32_t)width height:(uint32_t)height;
- (void)drawAtTime:(double)time;
@end

/// How many post-processing numbers the renderer will read.
///
/// Larger than the description needs, so a host built against a newer version
/// sending more of them is ignored from here on rather than reading past the
/// end of the array.
static constexpr NSUInteger kMaxPostParams = 128;


@implementation OrbisRenderer {
  Engine *_engine;

  /// The colour grading currently on the view.
  ///
  /// A resource with a baked lookup table rather than a struct, so it is kept
  /// and rebuilt only when the numbers move.
  ColorGrading *_colorGrading;

  /// The post-processing numbers as last applied, so a frame that changes
  /// nothing costs a memcmp rather than a dozen option rebuilds.
  float _postParams[kMaxPostParams];
  NSUInteger _postCount;

  /// Just the grading numbers, compared separately: the rest of the options
  /// are cheap to set and this one bakes a lookup table.
  float _gradingParams[17];
  Renderer *_renderer;
  Scene *_scene;
  View *_view;
  Camera *_camera;
  utils::Entity _cameraEntity;

  /// Everything in the scene, by the key its host gave it. This map is the
  /// whole reason a drag is cheap: it is what lets a publish be read as "these
  /// three moved" rather than "here is a new scene".
  std::unordered_map<int64_t, Drawn> _drawn;
  std::unordered_map<int64_t, Lit> _lit;

  /// Stamps for the mark-and-sweep. One counter each, because objects and
  /// lights arrive in separate calls.
  uint64_t _objectGeneration;
  uint64_t _lightGeneration;

  gltfio::AssetLoader *_assetLoader;
  gltfio::ResourceLoader *_resourceLoader;
  gltfio::MaterialProvider *_materialProvider;
  gltfio::TextureProvider *_stbTextures;

  /// A second decoder, for the images materials name directly.
  ///
  /// Separate from the one the glTF loader uses because a provider is a
  /// queue: popping from it takes ownership of whatever comes out, and
  /// popping a texture the resource loader was waiting for would leave a
  /// model with a missing map and no way to find out why.
  gltfio::TextureProvider *_ownStbTextures;
  gltfio::TextureProvider *_ownKtxTextures;

  /// The compiled surfaces, indexed by shading and blend mode. Built on
  /// first use: a scene of opaque lit objects should not compile the four
  /// blending variants it never draws.
  filament::Material *_surfaces[kSurfaceCount];

  /// Every material the host has named, by its key.
  std::unordered_map<int64_t, Surfaced> _materials;

  /// This frame's materials in the order they arrived, which is what an
  /// object's index points into. Rebuilt each publish; never outlives one.
  std::vector<filament::MaterialInstance *> _materialOrder;

  /// Which of them were built afresh this publish, so the objects wearing
  /// them are re-dressed rather than left pointing at what was destroyed.
  std::vector<bool> _materialRebuilt;

  /// Instances no material needs any more.
  ///
  /// Destroyed at the start of the *next* publish rather than this one. An
  /// object still wearing one is not put right until objects are applied,
  /// which happens after materials — so destroying them here would leave a
  /// renderable pointing at freed memory for the rest of the call.
  std::vector<filament::MaterialInstance *> _materialsSpent;

  /// Images loaded for materials, by path and colour space — the same file
  /// read as sRGB and as linear is two textures, and asking for one when the
  /// other is loaded would be a silent wrong answer.
  std::unordered_map<std::string, filament::Texture *> _ownTextures;

  /// Whether any of those are still decoding, so the queue is only polled
  /// while there is something in it.
  int _texturesPending;

  /// How many frames the decoders have been asked and given nothing back.
  int _pollsWithoutProgress;

  /// One white pixel, standing in for every map a material does not set.
  filament::Texture *_blankTexture;

  /// An external image that never gets one, for a screen with no video on it
  /// yet. Filament wants every sampler bound whether the shader reads it or
  /// not, and a screen showing nothing is a legitimate state to be in.
  filament::Texture *_blankExternal;

  /// How the frame is put together, already in the order it runs.
  ///
  /// Empty until a host says otherwise, which is read as the ordinary frame:
  /// one pass, every layer, straight into the picture. Empty rather than a
  /// default row, so that "nobody has said" and "somebody asked for exactly
  /// this" are not the same state.
  std::vector<GraphPass> _passes;
  std::vector<GraphTarget> _targets;

  /// Target textures given up but not yet destroyed, with the material
  /// generation they were given up in.
  std::vector<RetiredTexture> _retiredTextures;

  /// Every material sampler currently reading a pass, rebuilt on each
  /// publish and replayed whenever a target is rebuilt.
  std::vector<TargetBinding> _targetBindings;

  /// The place the scene is standing in, when a host has named one.
  ///
  /// Held apart from the flat ambient rather than replacing it, so that
  /// clearing an environment puts back the sky the day cycle had been
  /// writing rather than leaving the scene unlit.
  filament::IndirectLight *_environmentLight;
  filament::Texture *_environmentRadiance;
  filament::Texture *_environmentSkyTexture;
  filament::Skybox *_environmentSkybox;

  /// Whether the environment's backdrop is the one in the scene, so the
  /// procedural sky knows to stay out of the way.
  bool _showingEnvironmentSkybox;
  std::string _environmentRadiancePath;
  std::string _environmentSkyboxPath;
  float _environmentParams[4];

  /// The diffuse harmonics read off the radiance cubemap, kept because
  /// Filament does not hand them back and the bundle they came from is freed
  /// as soon as the driver has taken the pixels. Turning an environment or
  /// dimming it rebuilds the light, and a rebuild without these is an
  /// environment that lights reflections and nothing matte.
  float3 _environmentHarmonics[9];
  bool _environmentHasHarmonics;

  /// The last flat ambient asked for, kept so it can be put back when an
  /// environment is cleared. The day cycle writes this on every frame and
  /// would otherwise have to be waited for.
  float3 _ambientColour;
  float _ambientIntensity;

  /// The graph as last received, so a scene republished sixty times a second
  /// only rebuilds views and render targets when something in it moved.
  std::vector<float> _graphPassParams;
  std::vector<float> _graphTargetParams;
  std::vector<std::string> _graphTargetNames;

  /// The last pipeline settings applied, so a scene republished sixty times
  /// a second only reconfigures the view when something actually moved.
  float _pipelineParams[32];
  NSUInteger _pipelineCount;

  /// Every video the host has named, by its key.
  std::unordered_map<int64_t, Movie> _movies;

  /// This frame's videos in the order they arrived, which is what a material
  /// points into.
  std::vector<Movie *> _movieOrder;

  uint64_t _videoGeneration;

  uint64_t _materialGeneration;
  gltfio::TextureProvider *_ktxTextures;

  /// Loaded glTF files, by path. Kept for the life of the renderer: a scene
  /// arrives on every drag, and the parse is the expensive part.
  std::map<std::string, Mesh> _meshes;

  /// Assets that could not be loaded. Sticky, because a file is read once and
  /// a failure that reported itself only on the frame of the attempt would
  /// never be seen again.
  NSMutableDictionary<NSString *, NSString *> *_assetNotes;

  /// What the current objects and lights add up to that the renderer cannot
  /// honour. Replaced on every publish, so fixing the scene clears it.
  NSMutableDictionary<NSString *, NSString *> *_objectNotes;
  NSMutableDictionary<NSString *, NSString *> *_lightNotes;

  bool _sceneIsOwnedByHost;
  Skybox *_skybox;
  IndirectLight *_ambient;

  /// The sky as it currently stands. A day cycle changes it on every frame,
  /// and a skybox rebuilt sixty times a second is sixty allocations to say
  /// what one setter says.
  float3 _skyColour;
  float _skyAmbient;
  bool _skyShowsBody;
  bool _skyBuilt;

  /// Drawn many times over from one submission. Built the first time a scene
  /// has a population in it, because most have none.
  Material *_instancedMaterial;
  std::unordered_map<int32_t, Grown> _populations;
  uint64_t _populationGeneration;
  VertexBuffer *_vertexBuffer;
  IndexBuffer *_indexBuffer;

  /// The sheets a bank of mist is drawn with, and what they are made of.
  /// Built the first time a scene asks for weather and kept after that.
  Material *_mistMaterial;
  VertexBuffer *_quadVertices;
  IndexBuffer *_quadIndices;
  std::vector<utils::Entity> _mistEntities;
  std::vector<MaterialInstance *> _mistInstances;

  /// The dome the sky's cloud is drawn on, and what it is made of.
  Material *_cloudMaterial;
  VertexBuffer *_skyVertices;
  IndexBuffer *_skyIndices;
  utils::Entity _cloudEntity;
  MaterialInstance *_cloudInstance;
  bool _cloudsShowing;

  /// The panes a curtain of rain or snow is drawn on.
  Material *_rainMaterial;
  std::vector<utils::Entity> _rainEntities;
  std::vector<MaterialInstance *> _rainInstances;
  bool _rainShowing;

  /// What the current weather is, so the sheets are only rewritten when it
  /// changes rather than on every frame.
  bool _mistShowing;
  float _mistHeight;
  float _mistThickness;
  float3 _mistCentre;

  OrbisSurface *_surface;
  SwapChain *_swapChains[kOrbisBufferCount];
  NSInteger _backIndex;
  NSInteger _presentedIndex;

  uint32_t _width;
  uint32_t _height;
  uint32_t _pendingWidth;
  uint32_t _pendingHeight;
  float _fieldOfView;
  bool _orthographic;
  float _viewHeight;

  /// The last two things the camera was told, and the lock between the thread
  /// that says them and the thread that draws.
  Aimed _aimedNow;
  Aimed _aimedWas;
  NSLock *_aimLock;
  double _clockOffset;
  bool _clocksAligned;

  /// How fast the camera is going, followed rather than measured fresh.
  float3 _aimVelocity;
  float3 _lookVelocity;
  float _lensVelocity;
  bool _movingKnown;

  /// The word this is currently predicting from, and how wrong the last
  /// prediction turned out to be — carried, and decaying.
  double _spokeAt;
  float3 _spokePosition;
  float3 _spokeTarget;
  float3 _carriedPosition;
  float3 _carriedTarget;
  double _placedAt;
  double _placedWas;

  /// The usual gap between words, followed. A single gap is far too noisy to
  /// decide anything with.
  double _spanUsual;
  float3 _toldFrom;
  double _toldAt;
  float _toldSpeedWas;
  float _toldSpeedTotal;
  float _toldJerkTotal;
  int _toldCount;
  double _reachedTotal;
  int _reachedCount;
  int _saturated;
  bool _pacing;
  double _gpuTotal;
  int _gpuCount;

  NSLock *_presentLock;
  BOOL _disposed;
  int _frameCount;
  double _startedAt;
  float _skyFlash;
  int _cameraUpdates;
  double _pacedAt;
  float3 _pacedFrom;
  double _pacedFrameAt;
  float _stepWas;
  float _stepTotal;
  float _jerkTotal;
  int _stepCount;
  bool _dumped;
}

- (nullable instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height {
  if (!(self = [super init])) return nil;

  // Before Filament, because starting Filament allocates through it.
  _surface = OrbisCreateSurface();

  // Filament reports misuse by throwing, and an uncaught throw here would take
  // the whole application down rather than the one viewport that failed. The
  // message is worth keeping: it names the precondition, which is most of the
  // diagnosis.
  try {
    [self startWithWidth:width height:height];
  } catch (const std::exception &error) {
    NSLog(@"[orbis] Filament refused to start: %s", error.what());
    return nil;
  } catch (...) {
    NSLog(@"[orbis] Filament refused to start for an unknown reason.");
    return nil;
  }
  return self;
}

/// Says why Filament is about to abort.
///
/// Its preconditions throw, and the throw cannot be caught from here — not by
/// type and not by `...` — so the process goes down with only a stack to show
/// for it. This runs *before* the throw, which is the one place the reason
/// can be read.
static void orbisReportPanic(void *user, const utils::Panic &panic) {
  NSLog(@"[orbis] Filament refused: %s\n  at %s (%s:%d)", panic.getReason(),
        panic.getFunction(), panic.getFile(), panic.getLine());
}

- (void)startWithWidth:(uint32_t)width height:(uint32_t)height {
  utils::Panic::setPanicHandler(orbisReportPanic, nullptr);
  _width = MAX(width, 1u);
  _height = MAX(height, 1u);
  _pendingWidth = _width;
  _pendingHeight = _height;
  _presentedIndex = -1;
  _presentLock = [[NSLock alloc] init];
  _aimLock = [[NSLock alloc] init];
  _pacing = getenv("ORBIS_PACE") != nullptr;

  _engine = Engine::create(Engine::Backend::METAL);
  ASSERT_PRECONDITION(_engine != nullptr, "Metal is unavailable.");

  _renderer = _engine->createRenderer();
  _scene = _engine->createScene();
  _view = _engine->createView();

  _cameraEntity = utils::EntityManager::get().create();
  _camera = _engine->createCamera(_cameraEntity);
  _camera->lookAt({3.2, 2.4, 3.2}, {0, 0, 0}, {0, 1, 0});

  _view->setCamera(_camera);
  _view->setScene(_scene);

  // One layer is drawn and one is not, which is what hiding an object means
  // here. Later work — render layers a host can name — widens this mask; the
  // two-state version costs the same and is the half that is needed now.
  // Every author layer, and not the hidden one. A pass narrows this; a frame
  // with no graph never does.
  _view->setVisibleLayers(0xFF, kAllLayers);

  const float defaultSky[3] = {kDefaultAmbient.x, kDefaultAmbient.y,
                               kDefaultAmbient.z};
  [self setSkyColour:defaultSky
             ambient:kDefaultAmbientIntensity
            showBody:YES];

  _assetNotes = [NSMutableDictionary dictionary];
  _objectNotes = [NSMutableDictionary dictionary];
  _lightNotes = [NSMutableDictionary dictionary];
  [self startAssetLoader];
  [self buildGeometry];
  [self allocateBuffers];
  [self applyViewportSize];

  // Something to look at until a host sends a scene, so an empty viewport is
  // recognisably working rather than indistinguishable from a broken one. It
  // goes in through the same door a host's scene does — a placeholder built by
  // a second path would be a second path to keep working.
  const int64_t key[1] = {kPlaceholderKey};
  const float identity[16] = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
  const float colour[3] = {0.85f, 0.28f, 0.18f};
  const int32_t noMesh[1] = {-1};
  const int32_t flags[1] = {kCastsShadows | kReceivesShadows | kVisible};
  const int32_t noMaterial[1] = {-1};
  [self applyObjects:key
          transforms:identity
             colours:colour
              meshes:noMesh
               flags:flags
           materials:noMaterial
               paths:@[]
               count:1];
  _sceneIsOwnedByHost = false;

  const int64_t sunKey[1] = {kPlaceholderKey};
  const int32_t sunKind[1] = {0};
  const int32_t sunFlags[1] = {1};
  const float sun[18] = {1.0f, 0.96f, 0.9f, 110000.0f, 0,     0,
                         0,     -0.6f, -1.0f, -0.8f,     0,     0,
                         0,     0.53f, 0.1f,  10.0f,     80.0f, 0};
  [self applyLights:sunKey kinds:sunKind flags:sunFlags params:sun count:1];
}

- (void)buildGeometry {
  // Filament wants tangent frames as quaternions, so the flat face normals are
  // converted rather than handed over directly.
  quatf quats[24];
  auto *orientation = geometry::SurfaceOrientation::Builder()
                          .vertexCount(24)
                          .normals(kNormals)
                          .build();
  orientation->getQuats(quats, 24);
  delete orientation;

  // Heap, not stack, and freed by the descriptor's callback. Filament does not
  // copy vertex data — it holds the pointer until its driver thread performs
  // the upload, which happens after this method has returned. A stack array
  // here is read back as whatever later occupied the frame: the cube arrives
  // with garbage positions and garbage tangent frames, so it renders as an
  // unlit wedge rather than a lit cube.
  auto *vertices = new Vertex[24];
  for (int i = 0; i < 24; i++) {
    // Box mapping, taken from the face's own normal: whichever axis the face
    // points along is the one left out, and the other two become the corner's
    // place on it. Six faces, each covering the whole image once.
    const float3 at = kPositions[i];
    const float3 normal = kNormals[i];
    float2 uv;
    if (std::fabs(normal.y) > 0.5f) {
      uv = {at.x, at.z};
    } else if (std::fabs(normal.x) > 0.5f) {
      uv = {at.z, at.y};
    } else {
      uv = {at.x, at.y};
    }
    vertices[i] = {at, quats[i], {uv.x * 0.5f + 0.5f, uv.y * 0.5f + 0.5f}};
  }

  _vertexBuffer =
      VertexBuffer::Builder()
          .vertexCount(24)
          .bufferCount(1)
          .attribute(VertexAttribute::POSITION, 0,
                     VertexBuffer::AttributeType::FLOAT3,
                     offsetof(Vertex, position), sizeof(Vertex))
          .attribute(VertexAttribute::TANGENTS, 0,
                     VertexBuffer::AttributeType::FLOAT4,
                     offsetof(Vertex, tangents), sizeof(Vertex))
          .attribute(VertexAttribute::UV0, 0,
                     VertexBuffer::AttributeType::FLOAT2,
                     offsetof(Vertex, uv), sizeof(Vertex))
          .build(*_engine);
  _vertexBuffer->setBufferAt(
      *_engine, 0,
      VertexBuffer::BufferDescriptor(
          vertices, sizeof(Vertex) * 24,
          [](void *buffer, size_t, void *) {
            delete[] static_cast<Vertex *>(buffer);
          }));

  _indexBuffer = IndexBuffer::Builder()
                     .indexCount(36)
                     .bufferType(IndexBuffer::IndexType::USHORT)
                     .build(*_engine);
  // kIndices is a namespace-scope constant, so it outlives the upload without
  // a callback — unlike the vertices above.
  _indexBuffer->setBuffer(
      *_engine,
      IndexBuffer::BufferDescriptor(kIndices, sizeof(kIndices), nullptr));

}

/// Builds the sheets, once, the first time a scene asks for weather.
///
/// Lazily because most scenes have none, and a scene with none should not pay
/// for a material, two buffers and ten renderables it never draws.
- (void)buildQuad {
  if (_quadVertices != nullptr) return;

  // Heap and freed by the callback, for the same reason the cube's vertices
  // are: Filament holds the pointer until its own thread performs the upload,
  // which is after this method has returned.
  auto *corners = new MistVertex[4];
  for (int i = 0; i < 4; i++) corners[i] = kMistCorners[i];

  _quadVertices =
      VertexBuffer::Builder()
          .vertexCount(4)
          .bufferCount(1)
          .attribute(VertexAttribute::POSITION, 0,
                     VertexBuffer::AttributeType::FLOAT3,
                     offsetof(MistVertex, position), sizeof(MistVertex))
          .attribute(VertexAttribute::UV0, 0,
                     VertexBuffer::AttributeType::FLOAT2,
                     offsetof(MistVertex, uv), sizeof(MistVertex))
          .build(*_engine);
  _quadVertices->setBufferAt(
      *_engine, 0,
      VertexBuffer::BufferDescriptor(
          corners, sizeof(MistVertex) * 4,
          [](void *buffer, size_t, void *) {
            delete[] static_cast<MistVertex *>(buffer);
          }));

  _quadIndices = IndexBuffer::Builder()
                     .indexCount(6)
                     .bufferType(IndexBuffer::IndexType::USHORT)
                     .build(*_engine);
  _quadIndices->setBuffer(
      *_engine,
      IndexBuffer::BufferDescriptor(kMistIndices, sizeof(kMistIndices),
                                    nullptr));
}

/// Builds the sheets a bank of mist is drawn with.
- (void)buildMist {
  if (_mistMaterial != nullptr) return;
  [self buildQuad];

  _mistMaterial = Material::Builder()
                      .package(kmistMaterial, kmistMaterial_len)
                      .build(*_engine);

  auto &entities = utils::EntityManager::get();
  for (int sheet = 0; sheet < kMistSheets; sheet++) {
    MaterialInstance *instance = _mistMaterial->createInstance();

    // One at the middle of the bank, tailing off at the top and the bottom,
    // so a bank thins into the air rather than ending at a surface.
    const float across =
        kMistSheets == 1 ? 0.0f
                         : (float(sheet) / float(kMistSheets - 1)) * 2 - 1;
    instance->setParameter("fade", 1.0f - std::abs(across) * std::abs(across));

    utils::Entity entity = entities.create();
    RenderableManager::Builder(1)
        .boundingBox({{-1, -0.02f, -1}, {1, 0.02f, 1}})
        .material(0, instance)
        .geometry(0, RenderableManager::PrimitiveType::TRIANGLES,
                  _quadVertices, _quadIndices, 0, 6)
        // Mist does not take part in shadows either way: a sheet that cast
        // one would drop a hard rectangle across the ground.
        .receiveShadows(false)
        .castShadows(false)
        .build(*_engine, entity);

    _mistInstances.push_back(instance);
    _mistEntities.push_back(entity);
  }
}

/// Puts the bank around the camera and moves its noise along.
///
/// The sheets follow whoever is looking so the weather is always around them,
/// while the noise is sampled in world space so it does not swim as they walk
/// through it — the bank moves, the clouds in it stay where they are.
- (void)updateMistAtTime:(double)time {
  if (!_mistShowing || _mistEntities.empty()) return;

  auto &transforms = _engine->getTransformManager();
  const float3 eye = _camera->getPosition();

  for (size_t sheet = 0; sheet < _mistEntities.size(); sheet++) {
    const float across =
        _mistEntities.size() == 1
            ? 0.0f
            : (float(sheet) / float(_mistEntities.size() - 1)) * 2 - 1;

    const mat4f placement =
        mat4f::translation(float3{eye.x, _mistHeight + across * _mistThickness,
                                  eye.z}) *
        mat4f::scaling(float3{kMistReach, 1.0f, kMistReach});

    transforms.setTransform(transforms.getInstance(_mistEntities[sheet]),
                            placement);
    _mistInstances[sheet]->setParameter("time", float(time));
    _mistInstances[sheet]->setParameter("eye", eye);
  }
}

/// Builds the dome the sky's cloud is drawn on.
///
/// A hemisphere with a skirt below the horizon, so there is no seam where it
/// meets the ground, and enough rings to interpolate a direction without
/// faceting. Nothing about the cloud is in this mesh — it is somewhere to put
/// pixels and nothing else.
- (void)buildClouds {
  if (_cloudMaterial != nullptr) return;


  _cloudMaterial = Material::Builder()
                       .package(kskyMaterial, kskyMaterial_len)
                       .build(*_engine);

  const int rings = kSkyRings;
  const int segments = kSkySegments;
  const int count = (rings + 1) * (segments + 1);

  auto *vertices = new MistVertex[count];
  for (int ring = 0; ring <= rings; ring++) {
    // Well below the horizon to straight up.
    //
    // A shallow skirt leaves a band between where the dome stops and where
    // the ground starts, and what shows through it is the flat skybox — a
    // dark ring around the whole scene. Reaching a good way down costs two
    // rings of triangles and closes it.
    const float t = float(ring) / float(rings);
    const float elevation = (-0.45f + 1.45f * t) * float(M_PI) * 0.5f;

    for (int segment = 0; segment <= segments; segment++) {
      const float azimuth =
          float(segment) / float(segments) * 2.0f * float(M_PI);
      const int index = ring * (segments + 1) + segment;

      vertices[index] = {
          float3{std::cos(elevation) * std::sin(azimuth), std::sin(elevation),
                 std::cos(elevation) * std::cos(azimuth)},
          float2{float(segment) / float(segments), t},
      };
    }
  }

  auto *indices = new uint16_t[rings * segments * 6];
  int at = 0;
  for (int ring = 0; ring < rings; ring++) {
    for (int segment = 0; segment < segments; segment++) {
      const uint16_t a = uint16_t(ring * (segments + 1) + segment);
      const uint16_t b = uint16_t(a + 1);
      const uint16_t c = uint16_t(a + segments + 1);
      const uint16_t d = uint16_t(c + 1);

      indices[at++] = a;
      indices[at++] = c;
      indices[at++] = b;
      indices[at++] = b;
      indices[at++] = c;
      indices[at++] = d;
    }
  }

  _skyVertices =
      VertexBuffer::Builder()
          .vertexCount(count)
          .bufferCount(1)
          .attribute(VertexAttribute::POSITION, 0,
                     VertexBuffer::AttributeType::FLOAT3,
                     offsetof(MistVertex, position), sizeof(MistVertex))
          .attribute(VertexAttribute::UV0, 0,
                     VertexBuffer::AttributeType::FLOAT2,
                     offsetof(MistVertex, uv), sizeof(MistVertex))
          .build(*_engine);
  _skyVertices->setBufferAt(
      *_engine, 0,
      VertexBuffer::BufferDescriptor(
          vertices, sizeof(MistVertex) * count,
          [](void *buffer, size_t, void *) {
            delete[] static_cast<MistVertex *>(buffer);
          }));

  _skyIndices = IndexBuffer::Builder()
                    .indexCount(rings * segments * 6)
                    .bufferType(IndexBuffer::IndexType::USHORT)
                    .build(*_engine);
  _skyIndices->setBuffer(
      *_engine,
      IndexBuffer::BufferDescriptor(
          indices, sizeof(uint16_t) * rings * segments * 6,
          [](void *buffer, size_t, void *) {
            delete[] static_cast<uint16_t *>(buffer);
          }));

  _cloudInstance = _cloudMaterial->createInstance();


  _cloudEntity = utils::EntityManager::get().create();
  RenderableManager::Builder(1)
      .boundingBox({{-kSkyRadius, -kSkyRadius, -kSkyRadius},
                    {kSkyRadius, kSkyRadius, kSkyRadius}})
      .material(0, _cloudInstance)
      .geometry(0, RenderableManager::PrimitiveType::TRIANGLES, _skyVertices,
                _skyIndices, 0, rings * segments * 6)
      .receiveShadows(false)
      .castShadows(false)
      // Behind everything else transparent: the sky is behind the weather,
      // and cloud a hundred metres up is behind the rain in front of the lens.
      .priority(0)
      .culling(false)
      .build(*_engine, _cloudEntity);
}

/// Keeps the dome around the camera and lets the wind carry the weather.
///
/// The dome moves with the viewer and the cloud does not: what a pixel shows
/// is worked out from where its ray crosses the layer in world space, so
/// walking a kilometre walks under different cloud.
- (void)updateCloudsAtTime:(double)time {
  if (!_cloudsShowing || !_cloudEntity) return;

  auto &transforms = _engine->getTransformManager();
  const float3 eye = _camera->getPosition();

  transforms.setTransform(
      transforms.getInstance(_cloudEntity),
      mat4f::translation(eye) * mat4f::scaling(float3{kSkyRadius}));

  _cloudInstance->setParameter("time", float(time));
  _cloudInstance->setParameter("eye", eye);
}

- (void)setSkyEnabled:(BOOL)enabled params:(const float *)params {
  // The third thing that wants to be the backdrop. An environment's cubemap
  // is behind everything; this dome is geometry in front of it, so leaving it
  // on hides a photographed sky completely — and there is nothing on screen
  // to say which of the two is winning.
  if (_showingEnvironmentSkybox) enabled = NO;

  if (_disposed) return;

  const bool showing = enabled;

  if (showing) {
    [self buildClouds];

    // The order here is the order `OrbisSky.packed` writes them. It is one
    // array rather than a dozen arguments because the sky is one thing.
    _cloudInstance->setParameter("zenith", float3{params[0], params[1], params[2]});
    _cloudInstance->setParameter("horizon", float3{params[3], params[4], params[5]});
    _cloudInstance->setParameter("bodyDirection",
                                 float3{params[6], params[7], params[8]});
    _cloudInstance->setParameter("bodyColour",
                                 float3{params[9], params[10], params[11]});
    _cloudInstance->setParameter("bodySize", std::max(params[12], 0.001f));
    _cloudInstance->setParameter("showBody", params[13]);

    _cloudInstance->setParameter("ambient",
                                 float3{params[14], params[15], params[16]});
    _cloudInstance->setParameter("cover", params[17]);
    _cloudInstance->setParameter("altitude", std::max(params[18], 1.0f));
    _cloudInstance->setParameter("thickness", std::max(params[19], 1.0f));
    _cloudInstance->setParameter("scale", params[20]);
    _cloudInstance->setParameter("density", params[21]);
    _cloudInstance->setParameter("billow", params[22]);
    _cloudInstance->setParameter("extinction", params[23]);

    // What the sky may cost. Clamped to what the shader was built to loop to:
    // a bound past that is quietly ignored, and one of zero draws no cloud at
    // all while costing almost nothing — which reads as a fast frame rather
    // than as a fault.
    _cloudInstance->setParameter(
        "marchSteps", int32_t(std::clamp(params[24], 1.0f, 18.0f)));
    _cloudInstance->setParameter(
        "lightSteps", int32_t(std::clamp(params[25], 1.0f, 3.0f)));
    _cloudInstance->setParameter("erosion", params[26]);

    _cloudInstance->setParameter("wind", float2{params[27], params[28]});

    _skyFlash = params[29];
    _cloudInstance->setParameter("flash", params[29]);
    _cloudInstance->setParameter("flashDirection",
                                 float3{params[30], params[31], params[32]});
    _cloudInstance->setParameter("flashSeed", params[33]);

    if (!_cloudsShowing) _scene->addEntity(_cloudEntity);
  } else if (_cloudsShowing) {
    _scene->remove(_cloudEntity);
  }

  _cloudsShowing = showing;
}

/// Builds the panes a curtain of rain or snow hangs on.
- (void)buildRain {
  if (_rainMaterial != nullptr) return;
  [self buildQuad];

  _rainMaterial = Material::Builder()
                      .package(krainMaterial, krainMaterial_len)
                      .build(*_engine);

  auto &entities = utils::EntityManager::get();
  for (int pane = 0; pane < kRainCurtains; pane++) {
    MaterialInstance *instance = _rainMaterial->createInstance();

    utils::Entity entity = entities.create();
    RenderableManager::Builder(1)
        .boundingBox({{-1, -0.02f, -1}, {1, 0.02f, 1}})
        .material(0, instance)
        .geometry(0, RenderableManager::PrimitiveType::TRIANGLES,
                  _quadVertices, _quadIndices, 0, 6)
        .receiveShadows(false)
        .castShadows(false)
        .build(*_engine, entity);

    _rainInstances.push_back(instance);
    _rainEntities.push_back(entity);
  }
}

/// Hangs the panes in front of the camera and lets the weather fall past.
///
/// Turned to face the viewer every frame, and sampled in world space, so
/// looking around moves the panes through the weather instead of taking it
/// along. Three of them at three distances, because depth is read from things
/// passing each other at different rates, and one pane passes nothing.
- (void)updateRainAtTime:(double)time {
  if (!_rainShowing || _rainEntities.empty()) return;

  auto &transforms = _engine->getTransformManager();

  const float3 eye = _camera->getPosition();
  const float3 forward = normalize(_camera->getForwardVector());
  // Right and up from the camera's own basis rather than the world's, so a
  // pane stays square to the view when it is pitched up at the sky.
  const float3 right = -normalize(_camera->getLeftVector());
  const float3 up = normalize(_camera->getUpVector());

  const float aspect = float(_width) / float(std::max(_height, 1u));
  const float half =
      std::tan((_fieldOfView > 0 ? _fieldOfView : 50.0f) * float(M_PI) / 360.0f);

  for (size_t pane = 0; pane < _rainEntities.size(); pane++) {
    const float distance = kRainDistances[pane];
    // A quarter over the frustum, so the edges of a pane are never on screen.
    const float height = distance * half * 1.25f;
    const float width = height * aspect;

    const mat4f placement{
        float4{right * width, 0},
        // The quad lies flat with its face along +Y, so that axis is the one
        // pointed back at the camera.
        float4{-forward, 0},
        float4{up * height, 0},
        float4{eye + forward * distance, 1},
    };

    transforms.setTransform(transforms.getInstance(_rainEntities[pane]),
                            placement);
    _rainInstances[pane]->setParameter("time", float(time));
    _rainInstances[pane]->setParameter("eye", eye);
  }
}

- (void)setPrecipitationEnabled:(BOOL)enabled params:(const float *)params {
  if (_disposed) return;

  const bool showing = enabled && params[3] > 0;

  if (showing) {
    [self buildRain];

    for (size_t pane = 0; pane < _rainInstances.size(); pane++) {
      MaterialInstance *instance = _rainInstances[pane];
      instance->setParameter("colour",
                             float3{params[0], params[1], params[2]});
      // The nearer panes carry less of it. All three at full strength is
      // three times the weather anybody asked for, and the far one is what
      // gives the view its depth.
      const float share = pane == 0 ? 0.5f : (pane == 1 ? 0.75f : 1.0f);
      instance->setParameter("amount", params[3] * share);
      instance->setParameter("fall", params[4]);
      instance->setParameter("wind", float2{params[5], params[6]});
      // Drops per metre, thinned with distance so the far pane does not turn
      // into a grey wall of specks too small to resolve.
      instance->setParameter("scale",
                             params[7] / (1.0f + float(pane) * 0.8f));
      instance->setParameter("stretch", params[8]);
      instance->setParameter("threshold", params[9]);
    }

    if (!_rainShowing) {
      for (utils::Entity entity : _rainEntities) _scene->addEntity(entity);
    }
  } else if (_rainShowing) {
    for (utils::Entity entity : _rainEntities) _scene->remove(entity);
  }

  _rainShowing = showing;
}

- (void)setAmbientColour:(float3)colour intensity:(float)intensity {
  if (_disposed) return;

  // Recorded whatever happens, so clearing an environment puts back the sky
  // the day cycle has been writing all along rather than an unlit scene.
  _ambientColour = colour;
  _ambientIntensity = intensity;

  // An environment is already lighting this. Two indirect lights is one
  // scene lit twice, and the flat one is the half that flattens it.
  if (_environmentLight != nullptr) return;

  // Replaced rather than mutated: an IndirectLight's irradiance is fixed at
  // build time.
  if (_ambient) {
    _scene->setIndirectLight(nullptr);
    _engine->destroy(_ambient);
    _ambient = nullptr;
  }

  // One band, which is a constant term — light arriving equally from every
  // direction. A real environment map would vary with direction and is what
  // this becomes once there is an asset pipeline to bake one; until then the
  // choice is between flat ambient and none, and none means every shadow and
  // every surface facing away from the sun renders pure black.
  //
  // The band-0 basis function is 1/(2*sqrt(pi)), so dividing by it makes the
  // coefficient mean the irradiance somebody actually asked for.
  constexpr float kBand0 = 0.28209479177f;  // 1 / (2 * sqrt(pi))
  const float3 sh[1] = {colour / kBand0};

  _ambient = IndirectLight::Builder()
                 .irradiance(1, sh)
                 .intensity(intensity)
                 .build(*_engine);
  _scene->setIndirectLight(_ambient);
}

- (void)startAssetLoader {
  _materialProvider = gltfio::createUbershaderProvider(
      _engine, UBERARCHIVE_DEFAULT_DATA, UBERARCHIVE_DEFAULT_SIZE);

  gltfio::AssetConfiguration assetConfig{};
  assetConfig.engine = _engine;
  assetConfig.materials = _materialProvider;
  _assetLoader = gltfio::AssetLoader::create(assetConfig);

  gltfio::ResourceConfiguration resourceConfig{};
  resourceConfig.engine = _engine;
  // Well-formed files do not need this; a file exported by something careless
  // does, and a character whose weights do not sum to one deforms subtly
  // wrongly in a way that is very hard to trace back to the exporter.
  resourceConfig.normalizeSkinningWeights = true;
  _resourceLoader = new gltfio::ResourceLoader(resourceConfig);

  _stbTextures = gltfio::createStbProvider(_engine);
  _ktxTextures = gltfio::createKtx2Provider(_engine);
  _ownStbTextures = gltfio::createStbProvider(_engine);
  _ownKtxTextures = gltfio::createKtx2Provider(_engine);
  _resourceLoader->addTextureProvider("image/png", _stbTextures);
  _resourceLoader->addTextureProvider("image/jpeg", _stbTextures);
  _resourceLoader->addTextureProvider("image/ktx2", _ktxTextures);
}

/// Loads a glTF or glb file, once.
///
/// Returns null and records why if it cannot be read, so the caller draws the
/// placeholder rather than nothing at all.
- (Mesh *)meshAtPath:(const std::string &)path {
  auto found = _meshes.find(path);
  if (found != _meshes.end()) {
    return found->second.asset ? &found->second : nullptr;
  }

  // Recorded either way, so a missing file is read from disk once rather than
  // on every frame of a drag.
  Mesh &entry = _meshes[path];

  NSString *native = [NSString stringWithUTF8String:path.c_str()];
  NSData *data = [NSData dataWithContentsOfFile:native];
  if (data == nil) {
    NSLog(@"[orbis] mesh unreadable: %@", native);
    _assetNotes[native] = @"The file could not be read.";
    return nullptr;
  }

  gltfio::FilamentInstance *first = nullptr;
  entry.asset = _assetLoader->createInstancedAsset(
      static_cast<const uint8_t *>(data.bytes),
      static_cast<uint32_t>(data.length), &first, 1);

  if (entry.asset == nullptr) {
    NSLog(@"[orbis] mesh not glTF: %@ (%lu bytes)", native,
          (unsigned long)data.length);
    _assetNotes[native] = @"This is not a glTF file that Filament can read.";
    return nullptr;
  }

  // The base path, so a .gltf can find the .bin and the textures sitting
  // beside it. A .glb carries everything and does not need it.
  const std::string base = path.substr(0, path.find_last_of('/') + 1);
  _resourceLoader->setConfiguration({
      .engine = _engine,
      .gltfPath = base.c_str(),
      .normalizeSkinningWeights = true,
  });

  if (!_resourceLoader->loadResources(entry.asset)) {
    NSLog(@"[orbis] mesh resources failed: %@", native);
    _assetNotes[native] = @"Its geometry or textures could not be loaded.";
  }

  // Deliberately not calling releaseSourceData: more instances can only be
  // made while it is still there, and a second object using this mesh is the
  // ordinary case rather than the exception.
  entry.all.push_back(first);
  entry.spare.push_back(first);
  return &entry;
}

/// A copy of a mesh to give an object, from the pool if one is spare.
- (gltfio::FilamentInstance *)takeInstanceOf:(Mesh *)mesh {
  if (!mesh->spare.empty()) {
    auto *spare = mesh->spare.back();
    mesh->spare.pop_back();
    return spare;
  }
  auto *extra = _assetLoader->createInstance(mesh->asset);
  // A refusal means no more instances are possible; the object falls back to
  // the placeholder rather than vanishing.
  if (extra == nullptr) return nullptr;
  mesh->all.push_back(extra);
  return extra;
}

/// Takes an object out of the scene, keeping whatever can be used again.
- (void)recycle:(Drawn &)drawn {
  if (drawn.instance != nullptr) {
    // Back onto the materials the file brought with it, before it goes in the
    // pool. An instance pooled while still pointing at an overriding material
    // outlives that material — the material is swept the moment nothing is
    // made of it — and the next object to take the instance out draws with a
    // pointer to something destroyed. Which is a crash, and the way to get
    // one is to turn a material off and on again.
    if (!drawn.ownMaterials.empty()) {
      [self dress:drawn withMaterial:-1];
      drawn.ownMaterials.clear();
    }
    drawn.surface = -2;
    _scene->removeEntities(drawn.instance->getEntities(),
                           drawn.instance->getEntityCount());
    auto found = _meshes.find(drawn.path);
    if (found != _meshes.end()) found->second.spare.push_back(drawn.instance);
    drawn.instance = nullptr;
  }
  if (drawn.entity) {
    _scene->remove(drawn.entity);
    _engine->destroy(drawn.entity);
    utils::EntityManager::get().destroy(drawn.entity);
    drawn.entity = utils::Entity();
  }
  if (drawn.material != nullptr) {
    _engine->destroy(drawn.material);
    drawn.material = nullptr;
  }
}

/// Empties the scene of everything a host put in it.
- (void)removeEverything {
  for (auto &pair : _drawn) [self recycle:pair.second];
  _drawn.clear();

  auto &entities = utils::EntityManager::get();
  for (auto &pair : _lit) {
    if (!pair.second.entity) continue;
    _scene->remove(pair.second.entity);
    _engine->destroy(pair.second.entity);
    entities.destroy(pair.second.entity);
  }
  _lit.clear();
}

/// Applies the shadow and visibility flags to one renderable.
- (void)applyFlags:(int32_t)flags toEntity:(utils::Entity)entity {
  auto &renderables = _engine->getRenderableManager();
  auto instance = renderables.getInstance(entity);
  // Not every entity in a glTF file is renderable — a joint or an empty
  // carries no geometry — so the ones without a component are skipped.
  if (!instance) return;
  renderables.setCastShadows(instance, (flags & kCastsShadows) != 0);
  renderables.setReceiveShadows(instance, (flags & kReceivesShadows) != 0);
  renderables.setLayerMask(
      instance, 0xFF, (flags & kVisible) ? layerBitOf(flags) : kHiddenLayer);
}

/// Applies them to a whole object, which for a mesh is every part of it.
- (void)applyFlags:(int32_t)flags toDrawn:(const Drawn &)drawn {
  if (drawn.instance != nullptr) {
    const utils::Entity *entities = drawn.instance->getEntities();
    const size_t count = drawn.instance->getEntityCount();
    for (size_t i = 0; i < count; i++) {
      [self applyFlags:flags toEntity:entities[i]];
    }
    return;
  }
  [self applyFlags:flags toEntity:drawn.entity];
}

/// Builds one object: a mesh instance if it names a file that loads, and the
/// placeholder cube otherwise.
- (void)build:(Drawn &)drawn withPath:(const std::string &)path {
  drawn.path = path;

  if (!path.empty()) {
    Mesh *mesh = [self meshAtPath:path];
    if (mesh != nullptr) drawn.instance = [self takeInstanceOf:mesh];
    if (drawn.instance != nullptr) {
      _scene->addEntities(drawn.instance->getEntities(),
                          drawn.instance->getEntityCount());
      return;
    }
    // Fell through: the file is missing or unreadable, so the object is drawn
    // as the placeholder cube. Somewhere visible beats nowhere.
  }

  // One material instance per object, because the colour is a parameter on it
  // and sharing would make every object the last one's colour.
  drawn.material = [self surfaceAt:0]->createInstance();
  [self setDefaultsOn:drawn.material];

  drawn.entity = utils::EntityManager::get().create();
  RenderableManager::Builder(1)
      .boundingBox({{-1, -1, -1}, {1, 1, 1}})
      .material(0, drawn.material)
      .geometry(0, RenderableManager::PrimitiveType::TRIANGLES, _vertexBuffer,
                _indexBuffer, 0, 36)
      .receiveShadows(true)
      .castShadows(true)
      .build(*_engine, drawn.entity);
  _scene->addEntity(drawn.entity);
}

- (double)gpuMilliseconds {
  if (_disposed) return 0;

  const auto history = _renderer->getFrameInfoHistory(16);
  std::vector<double> costs;
  costs.reserve(history.size());

  for (const auto &frame : history) {
    if (frame.gpuFrameDuration > 0) {
      costs.push_back(double(frame.gpuFrameDuration) / 1.0e6);
    }
  }

  if (costs.empty()) return 0;
  std::sort(costs.begin(), costs.end());
  return costs[costs.size() / 2];
}

- (BOOL)hasPopulations {
  return !_populations.empty();
}

/// Takes a population apart. Every buffer it holds is its own.
- (void)clearPopulation:(Grown &)grown {
  // Order matters, and getting it wrong is fatal rather than untidy.
  //
  // A renderable holds its material instance and a material instance holds
  // the book it samples, so they have to go in that order: the renderables
  // first, then the instances nothing is wearing any more, then the texture
  // nothing is sampling. Destroying an instance while a renderable still
  // uses it trips a Filament precondition, and a precondition here is not an
  // error code — it aborts the process.
  //
  // It went the other way round, so a population large enough to leave a
  // window between the two took the app down whenever one was cleared: on a
  // change of size, on leaving the example, on the sweep that drops a
  // population the scene has stopped mentioning.
  for (auto entity : grown.entities) {
    _scene->remove(entity);
    _engine->destroy(entity);
    utils::EntityManager::get().destroy(entity);
  }
  for (auto *material : grown.materials) _engine->destroy(material);
  if (grown.book != nullptr) _engine->destroy(grown.book);
  grown.book = nullptr;
  grown.materials.clear();
  grown.entities.clear();
  grown.count = 0;
  grown.revision = INT32_MIN;
}

/// Builds the renderables one population needs, in chunks of what Filament
/// will draw at once.
- (void)growPopulation:(Grown &)grown
                 count:(uint32_t)count
                bounds:(const float *)bounds
                 flags:(int32_t)flags {
  [self clearPopulation:grown];
  if (count == 0) return;

  if (_instancedMaterial == nullptr) {
    _instancedMaterial = Material::Builder()
                             .package(kinstancedMaterial, kinstancedMaterial_len)
                             .build(*_engine);
  }

  const Box box{{bounds[0], bounds[1], bounds[2]},
                {bounds[3], bounds[4], bounds[5]}};

  const uint32_t texels = count * kTexelsPerMember;
  const uint32_t rows = (texels + kBookWidth - 1) / kBookWidth;

  // Four channels rather than three: Metal has no three-channel float
  // texture, and asking for one gets it padded somewhere less visible.
  grown.book = Texture::Builder()
                   .width(kBookWidth)
                   .height(rows)
                   .levels(1)
                   .sampler(Texture::Sampler::SAMPLER_2D)
                   .format(Texture::InternalFormat::RGBA32F)
                   .build(*_engine);

  const TextureSampler nearest(TextureSampler::MinFilter::NEAREST,
                               TextureSampler::MagFilter::NEAREST);

  for (uint32_t at = 0; at < count; at += kInstancesPerDraw) {
    const uint32_t chunk = std::min(kInstancesPerDraw, count - at);

    MaterialInstance *material = _instancedMaterial->createInstance();
    material->setParameter("book", grown.book, nearest);
    material->setParameter("base", int32_t(at));
    material->setParameter("range", grown.range);
    material->setParameter("fadeFrom", grown.range * kFadeFrom);

    utils::Entity entity = utils::EntityManager::get().create();
    RenderableManager::Builder(1)
        // Every member is culled by this one box, so it has to cover all of
        // them. A box around the mesh rather than around the population would
        // make the lot disappear as soon as the camera left the origin.
        .boundingBox(box)
        .material(0, material)
        .geometry(0, RenderableManager::PrimitiveType::TRIANGLES, _vertexBuffer,
                  _indexBuffer, 0, 36)
        // No instance buffer: each copy is handed nothing but its own number,
        // and reads its transform out of the book with it.
        .instances(chunk)
        .receiveShadows((flags & 2) != 0)
        .castShadows((flags & 1) != 0)
        .build(*_engine, entity);

    _scene->addEntity(entity);

    grown.entities.push_back(entity);
    grown.materials.push_back(material);
  }

  grown.count = count;
  grown.flags = flags;
  grown.order.clear();
  grown.shown.assign(grown.entities.size(), true);
}

/// Puts the members in an order that keeps neighbours together.
///
/// Only when the size changes, not on every write: a hundred thousand members
/// is a hundred thousand keys to sort, which is worth doing once for a forest
/// and not sixty times a second for one that is swaying. Members drift a
/// little between sorts and the draws' boxes are recomputed every time
/// anyway, so a slightly stale order costs nothing but a slightly looser box.
- (void)sortPopulation:(Grown &)grown transforms:(const float *)transforms {
  grown.order.resize(grown.count);
  if (grown.count == 0) return;

  float3 least{std::numeric_limits<float>::max()};
  float3 most{std::numeric_limits<float>::lowest()};
  for (uint32_t i = 0; i < grown.count; i++) {
    const float *m = transforms + size_t(i) * 16;
    const float3 at{m[12], m[13], m[14]};
    least = min(least, at);
    most = max(most, at);
  }

  const float3 span = max(most - least, float3{1e-4f});
  std::vector<std::pair<uint64_t, uint32_t>> keys(grown.count);

  for (uint32_t i = 0; i < grown.count; i++) {
    const float *m = transforms + size_t(i) * 16;
    const float3 at = (float3{m[12], m[13], m[14]} - least) / span;
    keys[i] = {mortonOf(uint32_t(std::clamp(at.x, 0.0f, 1.0f) * 1023.0f),
                        uint32_t(std::clamp(at.y, 0.0f, 1.0f) * 1023.0f),
                        uint32_t(std::clamp(at.z, 0.0f, 1.0f) * 1023.0f)),
               i};
  }

  std::sort(keys.begin(), keys.end());
  for (uint32_t i = 0; i < grown.count; i++) grown.order[i] = keys[i].second;
}

/// Writes a population's transforms and colours into the book it already has,
/// and works out where each draw's own members are.
///
/// Only ever called when the revision has moved.
- (void)fillPopulation:(Grown &)grown
            transforms:(const float *)transforms
               colours:(const float *)colours {
  if (grown.book == nullptr || grown.count == 0) return;
  if (grown.order.size() != grown.count) {
    [self sortPopulation:grown transforms:transforms];
  }

  const uint32_t texels = grown.count * kTexelsPerMember;
  const uint32_t rows = (texels + kBookWidth - 1) / kBookWidth;
  const size_t pixels = size_t(rows) * kBookWidth;

  auto *page = new float[pixels * 4];
  std::fill(page, page + pixels * 4, 0.0f);

  const size_t draws = grown.entities.size();
  grown.middles.assign(draws, float3{0.0f});
  grown.radii.assign(draws, 0.0f);

  std::vector<float3> least(draws, float3{std::numeric_limits<float>::max()});
  std::vector<float3> most(draws, float3{std::numeric_limits<float>::lowest()});

  for (uint32_t slot = 0; slot < grown.count; slot++) {
    const uint32_t member = grown.order[slot];

    // Column-major coming in, rows going out: element (row, column) of a
    // column-major sixteen is at column * 4 + row, and the shader wants the
    // rows so that each one carries a component of the translation in its
    // fourth place.
    const float *m = transforms + size_t(member) * 16;
    float *to = page + size_t(slot) * kTexelsPerMember * 4;

    for (int row = 0; row < 3; row++) {
      to[row * 4 + 0] = m[0 * 4 + row];
      to[row * 4 + 1] = m[1 * 4 + row];
      to[row * 4 + 2] = m[2 * 4 + row];
      to[row * 4 + 3] = m[3 * 4 + row];
    }

    const float *colour = colours + size_t(member) * 3;
    to[12] = colour[0];
    to[13] = colour[1];
    to[14] = colour[2];
    to[15] = 1.0f;

    // How far a member reaches from where it stands, taken from the longest
    // of its three axes. A box drawn round the positions alone clips whatever
    // is tall.
    const float reach =
        std::max({length(float3{m[0], m[1], m[2]}),
                  length(float3{m[4], m[5], m[6]}),
                  length(float3{m[8], m[9], m[10]})});
    const float3 at{m[12], m[13], m[14]};

    const size_t draw = std::min(size_t(slot / kInstancesPerDraw), draws - 1);
    least[draw] = min(least[draw], at - reach);
    most[draw] = max(most[draw], at + reach);
  }

  auto &renderables = _engine->getRenderableManager();
  for (size_t draw = 0; draw < draws; draw++) {
    if (least[draw].x > most[draw].x) continue;

    const float3 middle = (least[draw] + most[draw]) * 0.5f;
    const float3 half = (most[draw] - least[draw]) * 0.5f;

    grown.middles[draw] = middle;
    grown.radii[draw] = length(half);

    // Each draw is culled by its own box now, rather than by one drawn round
    // the whole population. That is the difference between a camera in one
    // corner of a map paying for that corner and paying for the map.
    auto instance = renderables.getInstance(grown.entities[draw]);
    if (instance) {
      renderables.setAxisAlignedBoundingBox(instance, Box{middle, half});
    }
  }

  grown.book->setImage(
      *_engine, 0,
      Texture::PixelBufferDescriptor(
          page, pixels * 4 * sizeof(float),
          Texture::PixelBufferDescriptor::PixelDataFormat::RGBA,
          Texture::PixelBufferDescriptor::PixelDataType::FLOAT,
          [](void *buffer, size_t, void *) {
            delete[] static_cast<float *>(buffer);
          }));
}

/// Takes out of the scene whatever is further away than it is drawn from.
///
/// Called once a frame, because it depends on where the camera is. Filament
/// culls by what is in front of the camera; this is the other half of it —
/// what is close enough to be worth drawing at all. A map is mostly things
/// too far away to see, and a range is what lets one be loaded whole.
- (void)rangePopulations {
  const float3 eye = _camera->getPosition();

  for (auto &entry : _populations) {
    Grown &grown = entry.second;
    if (grown.range <= 0 || grown.middles.size() != grown.entities.size()) {
      continue;
    }

    for (size_t draw = 0; draw < grown.entities.size(); draw++) {
      // Measured to the nearest part of the draw rather than to its middle,
      // so a large group does not vanish while part of it is still close.
      // To the nearest part of the draw rather than to its middle, so a
      // large group does not vanish while part of it is still close — and
      // only once every member in it has finished sinking, or taking it out
      // is the pop the sinking exists to avoid.
      const float away =
          std::max(length(grown.middles[draw] - eye) - grown.radii[draw], 0.0f);
      const bool wanted = away <= grown.range;

      if (draw >= grown.shown.size()) grown.shown.resize(draw + 1, true);
      if (wanted == grown.shown[draw]) continue;

      if (wanted) {
        _scene->addEntity(grown.entities[draw]);
      } else {
        _scene->remove(grown.entities[draw]);
      }
      grown.shown[draw] = wanted;
    }
  }
}

- (void)applyPopulations:(const int32_t *)keys
                  counts:(const int32_t *)counts
                  meshes:(const int32_t *)meshes
                   flags:(const int32_t *)flags
               revisions:(const int32_t *)revisions
                  ranges:(const float *)ranges
                  bounds:(const float *)bounds
                   paths:(NSArray<NSString *> *)paths
                 changed:(const int32_t *)changed
            changedCount:(uint32_t)changedCount
              transforms:(const float *)transforms
                 colours:(const float *)colours
                   count:(uint32_t)count {
  if (_disposed) return;

  const uint64_t generation = ++_populationGeneration;

  // Where in the packed buffers each changed population's members begin. The
  // sender packs them end to end in the order it names them.
  std::unordered_map<int32_t, size_t> arriving;
  size_t at = 0;
  for (uint32_t c = 0; c < changedCount; c++) {
    for (uint32_t i = 0; i < count; i++) {
      if (keys[i] != changed[c]) continue;
      arriving[changed[c]] = at;
      at += size_t(counts[i]);
      break;
    }
  }

  for (uint32_t i = 0; i < count; i++) {
    Grown &grown = _populations[keys[i]];
    grown.seen = generation;

    const uint32_t wanted = uint32_t(std::max(counts[i], 0));

    // A different size, a different mesh or different flags is a different
    // set of renderables. Anything else is a write into the ones there are.
    if (grown.count != wanted || grown.flags != flags[i] ||
        grown.entities.empty()) {
      [self growPopulation:grown count:wanted bounds:bounds + i * 6 flags:flags[i]];
    }

    if (grown.range != ranges[i]) {
      grown.range = ranges[i];
      for (auto *material : grown.materials) {
        material->setParameter("range", grown.range);
        material->setParameter("fadeFrom", grown.range * kFadeFrom);
      }
    }

    auto found = arriving.find(keys[i]);
    if (found != arriving.end() && wanted > 0) {
      [self fillPopulation:grown
                transforms:transforms + found->second * 16
                   colours:colours + found->second * 3];
      grown.revision = revisions[i];
    }
  }

  // Anything not named this time has gone.
  for (auto it = _populations.begin(); it != _populations.end();) {
    if (it->second.seen == generation) {
      ++it;
      continue;
    }
    [self clearPopulation:it->second];
    it = _populations.erase(it);
  }
}


/// Which compiled surface a set of flags asks for: shading first, then blend
/// mode.
///
/// The shadow catcher sits outside that grid rather than adding a fourth row
/// to it. Its blending is not a choice — a surface that is only its own
/// shadow is see-through by definition — so five variants of it would be four
/// packages compiled to be unreachable.
- (int)surfaceIndexFor:(int32_t)flags {
  const int shading = flags & 3;
  const int blend = (flags >> 2) & 15;
  if (shading == 3) return kShadowCatcherSurface;
  if (shading < 0 || shading > 2 || blend < 0 || blend > 4) return 0;
  return shading * 5 + blend;
}

/// Builds a surface the first time something is made of it.
///
/// Ten compiled packages rather than one, because blending is the only thing
/// about a material that a uniform cannot change — and lazily, because a
/// scene of opaque lit objects should not compile the four blending variants
/// it never draws.
- (Material *)surfaceAt:(int)index {
  static const uint8_t *packages[kSurfaceCount] = {
      klit_opaqueMaterial,        klit_transparentMaterial,
      klit_fadeMaterial,          klit_maskedMaterial,
      klit_addMaterial,           kunlit_opaqueMaterial,
      kunlit_transparentMaterial, kunlit_fadeMaterial,
      kunlit_maskedMaterial,      kunlit_addMaterial,
      kvideo_opaqueMaterial,      kvideo_transparentMaterial,
      kvideo_fadeMaterial,        kvideo_maskedMaterial,
      kvideo_addMaterial,         kshadowcatcherMaterial,
  };
  static const size_t sizes[kSurfaceCount] = {
      klit_opaqueMaterial_len,        klit_transparentMaterial_len,
      klit_fadeMaterial_len,          klit_maskedMaterial_len,
      klit_addMaterial_len,           kunlit_opaqueMaterial_len,
      kunlit_transparentMaterial_len, kunlit_fadeMaterial_len,
      kunlit_maskedMaterial_len,      kunlit_addMaterial_len,
      kvideo_opaqueMaterial_len,      kvideo_transparentMaterial_len,
      kvideo_fadeMaterial_len,        kvideo_maskedMaterial_len,
      kvideo_addMaterial_len,         kshadowcatcherMaterial_len,
  };
  if (index < 0 || index >= kSurfaceCount) index = 0;
  if (_surfaces[index] == nullptr) {
    _surfaces[index] =
        Material::Builder().package(packages[index], sizes[index]).build(*_engine);
  }
  return _surfaces[index];
}

/// A single white pixel, for every sampler a material leaves empty.
///
/// Filament requires every sampler in a material to be bound whether the
/// shader reads it or not, and an unbound one is undefined rather than
/// ignored. One texture stands in for all of them; the `has` flag beside it
/// is what actually decides whether it is read.
- (Texture *)blankTexture {
  if (_blankTexture != nullptr) return _blankTexture;
  _blankTexture = Texture::Builder()
                      .width(1)
                      .height(1)
                      .levels(1)
                      .format(Texture::InternalFormat::RGBA8)
                      .build(*_engine);
  uint8_t *pixel = new uint8_t[4]{255, 255, 255, 255};
  _blankTexture->setImage(
      *_engine, 0,
      Texture::PixelBufferDescriptor(
          pixel, 4, Texture::Format::RGBA, Texture::Type::UBYTE,
          [](void *buffer, size_t, void *) {
            delete[] static_cast<uint8_t *>(buffer);
          }));
  return _blankTexture;
}

/// Fills in every parameter of the standard surface with what a material
/// that says nothing would have.
///
/// Needed because Filament requires every sampler to be bound whether the
/// shader reads it or not — an object drawn in a plain colour still has five
/// maps, all of them the blank one, all of them switched off.
- (void)setDefaultsOn:(MaterialInstance *)instance {
  Texture *blank = [self blankTexture];
  TextureSampler sampler(TextureSampler::MinFilter::LINEAR_MIPMAP_LINEAR,
                         TextureSampler::MagFilter::LINEAR);
  instance->setParameter("baseColor", float4{0.8f, 0.8f, 0.8f, 1.0f});
  instance->setParameter("metallic", 0.0f);
  instance->setParameter("roughness", 0.4f);
  instance->setParameter("reflectance", 0.5f);
  instance->setParameter("emissive", float3{0.0f, 0.0f, 0.0f});
  instance->setParameter("emissiveIntensity", 0.0f);
  instance->setParameter("ambientOcclusion", 1.0f);
  instance->setParameter("normalScale", 1.0f);
  instance->setParameter("uvTransform", float4{1.0f, 1.0f, 0.0f, 0.0f});
  static const char *kNames[5] = {"baseColorMap", "normalMap",
                                  "metallicRoughnessMap", "occlusionMap",
                                  "emissiveMap"};
  static const char *kFlags[5] = {"hasBaseColorMap", "hasNormalMap",
                                  "hasMetallicRoughnessMap", "hasOcclusionMap",
                                  "hasEmissiveMap"};
  for (int i = 0; i < 5; i++) {
    instance->setParameter(kNames[i], blank, sampler);
    instance->setParameter(kFlags[i], false);
  }
}

/// Loads an image, or hands back the one already loaded for that path.
///
/// The colour space is part of the identity: the same file read as sRGB and
/// as linear are two different textures, and a normal map decoded as though
/// it were a colour bends every normal towards flat.
- (Texture *)textureAtPath:(NSString *)path srgb:(bool)srgb {
  std::string identity = std::string(path.UTF8String) + (srgb ? "|s" : "|l");

  // What a pass drew, rather than a file. Looked up every time rather than
  // cached: the target behind a name is rebuilt whenever the view is resized,
  // and a material still holding the old texture would be sampling something
  // the engine has destroyed.
  const std::string wanted(path.UTF8String);
  if (wanted.rfind(kTargetScheme, 0) == 0) {
    return [self targetTextureNamed:wanted.substr(strlen(kTargetScheme))];
  }

  auto found = _ownTextures.find(identity);
  if (found != _ownTextures.end()) return found->second;

  // A failure is cached as null too. Forty objects naming a file that is not
  // there would otherwise each read the disk, every frame, forever.
  NSData *data = [NSData dataWithContentsOfFile:path];
  Texture *texture = nullptr;
  if (data != nil) {
    NSString *extension = path.pathExtension.lowercaseString;
    const char *mime = "image/png";
    gltfio::TextureProvider *provider = _ownStbTextures;
    if ([extension isEqualToString:@"jpg"] || [extension isEqualToString:@"jpeg"]) {
      mime = "image/jpeg";
    } else if ([extension isEqualToString:@"ktx2"]) {
      mime = "image/ktx2";
      provider = _ownKtxTextures;
    }
    texture = provider->pushTexture(
        static_cast<const uint8_t *>(data.bytes), data.length, mime,
        srgb ? gltfio::TextureProvider::TextureFlags::sRGB
             : gltfio::TextureProvider::TextureFlags::NONE);
    if (texture != nullptr) {
      // The texture is usable now and its pixels arrive later, so an object
      // made of it appears white for a frame or two rather than not at all.
      _texturesPending++;
    }
  }
  _ownTextures[identity] = texture;
  return texture;
}

/// Gives the decoders a chance to hand over anything they have finished.
///
/// Called once a frame while something is outstanding, and not at all when
/// nothing is — which is every frame after the first few.
- (void)pollTextures {
  if (_texturesPending == 0) return;

  _ownStbTextures->updateQueue();
  _ownKtxTextures->updateQueue();

  int popped = 0;
  while (_ownStbTextures->popTexture() != nullptr) popped++;
  while (_ownKtxTextures->popTexture() != nullptr) popped++;
  _texturesPending -= popped;
  if (_texturesPending < 0) _texturesPending = 0;

  // An image that never finishes would otherwise have this polling both
  // decoders for the life of the application. A decode takes a handful of
  // frames; six hundred is ten seconds of them, and past that the answer is
  // that it is not coming.
  _pollsWithoutProgress = popped > 0 ? 0 : _pollsWithoutProgress + 1;
  if (_pollsWithoutProgress > 600) {
    NSLog(@"[orbis] %d texture(s) never finished decoding; giving up polling",
          _texturesPending);
    _texturesPending = 0;
    _pollsWithoutProgress = 0;
  }
}

/// Builds the sampler a material's wrap and filter settings describe.
- (TextureSampler)samplerFor:(int32_t)flags {
  const int wrap = (flags >> 10) & 3;
  const bool sharp = ((flags >> 12) & 1) != 0;
  TextureSampler sampler(
      sharp ? TextureSampler::MinFilter::NEAREST
            : TextureSampler::MinFilter::LINEAR_MIPMAP_LINEAR,
      sharp ? TextureSampler::MagFilter::NEAREST
            : TextureSampler::MagFilter::LINEAR);
  TextureSampler::WrapMode mode = TextureSampler::WrapMode::REPEAT;
  if (wrap == 1) mode = TextureSampler::WrapMode::CLAMP_TO_EDGE;
  if (wrap == 2) mode = TextureSampler::WrapMode::MIRRORED_REPEAT;
  sampler.setWrapModeS(mode);
  sampler.setWrapModeT(mode);
  return sampler;
}

/// Writes everything about one material into its instance.
- (void)write:(Surfaced &)surface
    withParams:(const float *)params
          maps:(const int32_t *)maps
   texturePaths:(NSArray<NSString *> *)texturePaths
     textureSrgb:(const int32_t *)textureSrgb
          video:(int32_t)video {
  MaterialInstance *instance = surface.instance;
  const int shading = surface.flags & 3;
  const bool unlit = shading == 1;
  const TextureSampler sampler = [self samplerFor:surface.flags];

  // A catcher has one parameter and no maps. Everything else the writer
  // sets below would be a parameter this material does not declare, and
  // Filament treats that as a mistake rather than ignoring it.
  if (shading == 3) {
    instance->setParameter("baseColor",
                           float4{params[0], params[1], params[2], params[3]});
    return;
  }

  // A screen has its own short list: a tint, a transform, and the frame.
  if (shading == 2) {
    instance->setParameter("baseColor",
                           float4{params[0], params[1], params[2], params[3]});
    instance->setParameter(
        "uvTransform", float4{params[13], params[14], params[15], params[16]});
    Movie *movie = (video >= 0 && video < static_cast<int32_t>(_movieOrder.size()))
                       ? _movieOrder[video]
                       : nullptr;
    Texture *frame = movie != nullptr ? movie->texture : nullptr;
    // An external image only ever clamps, and only ever filters linearly.
    // Asking for anything else is not refused, it is ignored.
    const TextureSampler screen(TextureSampler::MinFilter::LINEAR,
                                TextureSampler::MagFilter::LINEAR,
                                TextureSampler::WrapMode::CLAMP_TO_EDGE);
    if (frame == nullptr) {
      if (_blankExternal == nullptr) {
        _blankExternal = Texture::Builder()
                             .sampler(Texture::Sampler::SAMPLER_EXTERNAL)
                             .format(Texture::InternalFormat::RGBA8)
                             .build(*_engine);
      }
      frame = _blankExternal;
    }
    instance->setParameter("videoTexture", frame, screen);
    instance->setParameter("hasVideo", movie != nullptr && movie->texture != nullptr);
    return;
  }

  instance->setParameter("baseColor",
                         float4{params[0], params[1], params[2], params[3]});
  if (unlit) {
    // Projected from the camera rather than wrapped on the surface, which is
    // what makes a reflection target a mirror instead of a decal.
    instance->setParameter("screenMapped",
                           ((surface.flags >> 13) & 1) != 0);
  }
  instance->setParameter("emissive", float3{params[7], params[8], params[9]});
  instance->setParameter("emissiveIntensity", params[10]);
  instance->setParameter(
      "uvTransform", float4{params[13], params[14], params[15], params[16]});

  if (!unlit) {
    instance->setParameter("metallic", params[4]);
    instance->setParameter("roughness", params[5]);
    instance->setParameter("reflectance", params[6]);
    instance->setParameter("ambientOcclusion", params[11]);
    instance->setParameter("normalScale", params[12]);
  }

  // The names are in the order the packed maps are, which is the order the
  // Dart side lists them. A shorter list for the unlit surface, because it
  // has nothing to do with the other four.
  static const char *kMapNames[kMaterialMaps] = {
      "baseColorMap", "normalMap", "metallicRoughnessMap", "occlusionMap",
      "emissiveMap"};
  static const char *kMapFlags[kMaterialMaps] = {
      "hasBaseColorMap", "hasNormalMap", "hasMetallicRoughnessMap",
      "hasOcclusionMap", "hasEmissiveMap"};

  // What a pass drew has one level and is never tiled, so it is bound with a
  // sampler of its own rather than the material's.
  //
  // Not a nicety. The ordinary sampler asks for LINEAR_MIPMAP_LINEAR, and
  // minifying a texture that has no mips through it is undefined — which on
  // Metal comes out as flat magenta across the whole surface, with nothing
  // logged. A mirror that is entirely the missing-texture colour is a long
  // afternoon if the sampler is not the first place you look.
  const TextureSampler drawn(TextureSampler::MinFilter::LINEAR,
                             TextureSampler::MagFilter::LINEAR,
                             TextureSampler::WrapMode::CLAMP_TO_EDGE);

  const size_t count = unlit ? 1 : kMaterialMaps;
  for (size_t i = 0; i < count; i++) {
    Texture *texture = nullptr;
    bool fromPass = false;
    const int32_t index = maps[i];
    if (index >= 0 && index < static_cast<int32_t>(texturePaths.count)) {
      fromPass = [texturePaths[index] hasPrefix:@(kTargetScheme)];
      texture = [self textureAtPath:texturePaths[index]
                               srgb:textureSrgb[index] != 0];
    }
    const bool present = texture != nullptr;
    instance->setParameter(kMapNames[i],
                           present ? texture : [self blankTexture],
                           present && fromPass ? drawn : sampler);
    instance->setParameter(kMapFlags[i], present);

    if (fromPass) {
      const std::string path(texturePaths[index].UTF8String);
      _targetBindings.push_back({instance, kMapNames[i],
                                 path.substr(strlen(kTargetScheme))});
    }
  }
}

/// Sets up the parts of a material that are rasteriser state rather than
/// shader input.
- (void)applyRasterState:(Surfaced &)surface
           withThreshold:(float)threshold
                    bias:(float)bias {
  MaterialInstance *instance = surface.instance;
  const int culling = (surface.flags >> 6) & 3;
  const bool doubleSided = ((surface.flags >> 8) & 1) != 0;
  const bool depthWrite = ((surface.flags >> 9) & 1) != 0;

  // Order matters: turning double-sided lighting on disables culling as a
  // side effect, so the culling mode is set afterwards and wins.
  instance->setDoubleSided(doubleSided);
  MaterialInstance::CullingMode mode = MaterialInstance::CullingMode::BACK;
  if (culling == 1) mode = MaterialInstance::CullingMode::FRONT;
  if (culling == 2 || doubleSided) mode = MaterialInstance::CullingMode::NONE;
  instance->setCullingMode(mode);
  instance->setDepthWrite(depthWrite);
  // Pushed away in the depth test only, without moving where it is drawn:
  // which of two things sharing a plane is behind. The slope term goes with
  // the constant one, or a surface seen nearly edge-on needs a bias so large
  // that it separates visibly when seen face-on.
  instance->setPolygonOffset(bias, bias * 1000.0f);
  // Only where it means anything: Filament asserts rather than ignores a
  // threshold set on a material that does not punch pixels out.
  if (((surface.flags >> 2) & 15) == 3) instance->setMaskThreshold(threshold);
}


/// Opens a file and starts a decoder for it.
///
/// The pixel format is asked for explicitly: Filament's external images take
/// 32-bit BGRA or biplanar YUV and nothing else, and a decoder left to choose
/// will happily hand back something neither of them.
- (void)open:(Movie &)movie atPath:(const std::string &)path {
  [self close:movie];
  movie.path = path;
  if (path.empty()) return;

  NSString *text = [NSString stringWithUTF8String:path.c_str()];
  NSURL *url = [text hasPrefix:@"http"] ? [NSURL URLWithString:text]
                                        : [NSURL fileURLWithPath:text];
  if (url == nil) return;

  AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
  movie.output = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferMetalCompatibilityKey : @YES,
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
  }];
  [item addOutput:movie.output];

  movie.player = [AVPlayer playerWithPlayerItem:item];
  // Without this the player pauses itself the moment a buffer runs short,
  // and a file on the local disk stutters for no reason a viewer can see.
  movie.player.automaticallyWaitsToMinimizeStalling = NO;

  // The external image is the decoder's own buffer, so the texture is a
  // handle rather than storage: no width, no height, no format, and nothing
  // uploaded when the picture changes.
  movie.texture = Texture::Builder()
                      .sampler(Texture::Sampler::SAMPLER_EXTERNAL)
                      .format(Texture::InternalFormat::RGBA8)
                      .build(*_engine);

  __weak AVPlayer *player = movie.player;
  movie.endObserver = [[NSNotificationCenter defaultCenter]
      addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                  object:item
                   queue:[NSOperationQueue mainQueue]
              usingBlock:^(NSNotification *note) {
                // Looping is done here rather than with a queue player,
                // because a queue restarts by loading the file again and the
                // gap that leaves is exactly what a loop is meant to hide.
                OrbisRenderer *renderer = self;
                if (renderer == nil || player == nil) return;
                [renderer restartIfLooping:player];
              }];
}

/// Sends a finished video back to the start, if it was asked to loop.
- (void)restartIfLooping:(AVPlayer *)player {
  for (auto &entry : _movies) {
    Movie &movie = entry.second;
    if (movie.player != player) continue;
    if (!movie.looping) return;
    [movie.player seekToTime:kCMTimeZero
             toleranceBefore:kCMTimeZero
              toleranceAfter:kCMTimeZero];
    if ((movie.flags & 1) != 0) [movie.player playImmediatelyAtRate:movie.rate];
    return;
  }
}

/// Stops a video and gives back everything it was holding.
- (void)close:(Movie &)movie {
  if (movie.endObserver != nil) {
    [[NSNotificationCenter defaultCenter] removeObserver:movie.endObserver];
    movie.endObserver = nil;
  }
  if (movie.player != nil) {
    [movie.player pause];
    movie.player = nil;
  }
  movie.output = nil;
  if (movie.texture != nullptr) {
    _engine->destroy(movie.texture);
    movie.texture = nullptr;
  }
  if (movie.showing != nullptr) {
    CVPixelBufferRelease(movie.showing);
    movie.showing = nullptr;
  }
  movie.flags = -1;
  movie.seekToken = -1;
}


/// States how much of the frame's work actually happens.
///
/// One pipeline with dials, not a choice of pipelines. Everything here either
/// configures the view or is remembered for the lights, which read it when
/// they set their own shadow options — a cascade count is a property of the
/// light that casts, but nobody wants to set it per light.
/// Reads a cubemap `cmgen` baked, and the harmonics it wrote beside it.
///
/// Returns null and says why rather than throwing: an environment is an asset
/// somebody typed a path to, and a scene that refuses to draw because the
/// path was wrong is worse than one drawn by its lights alone.
- (Texture *)cubemapAtPath:(NSString *)path
                  harmonics:(float3 *)harmonics
                   hasThose:(bool *)hasThose
                       note:(NSString *)note {
  *hasThose = false;

  NSData *data = [NSData dataWithContentsOfFile:path];
  if (data == nil) {
    _assetNotes[note] = [NSString stringWithFormat:@"%@ could not be read.",
                                          path.lastPathComponent];
    return nullptr;
  }

  // The bundle owns the pixels and has to outlive the upload, so it is handed
  // to createTexture along with the callback that frees it once the driver has
  // taken a copy. Freeing it here would be a race with the render thread.
  auto *bundle = new image::Ktx1Bundle(
      static_cast<const uint8_t *>(data.bytes),
      static_cast<uint32_t>(data.length));

  if (!bundle->isCubemap()) {
    _assetNotes[note] = [NSString
        stringWithFormat:
            @"%@ is not a cubemap. cmgen writes one; a flat image will not do.",
            path.lastPathComponent];
    delete bundle;
    return nullptr;
  }

  *hasThose = bundle->getSphericalHarmonics(harmonics);

  Texture *texture = ktxreader::Ktx1Reader::createTexture(
      _engine, *bundle, false,
      [](void *userdata) {
        delete static_cast<image::Ktx1Bundle *>(userdata);
      },
      bundle);
  if (texture == nullptr) {
    _assetNotes[note] =
        [NSString stringWithFormat:@"%@ is not a KTX this build can read.",
                                   path.lastPathComponent];
    delete bundle;
  }
  return texture;
}

- (void)setEnvironmentRadiance:(NSString *)radiance
                        skybox:(NSString *)skybox
                        params:(const float *)params {
  if (_disposed || _engine == nullptr) return;

  const std::string wantedRadiance(radiance.UTF8String);
  const std::string wantedSkybox(skybox.UTF8String);
  const bool sameFiles = wantedRadiance == _environmentRadiancePath &&
                         wantedSkybox == _environmentSkyboxPath;

  // The numbers can move without the files changing — an environment being
  // turned, or brought up and down — and rebuilding a cubemap for that would
  // be reading a file off disk on every frame of a drag.
  if (sameFiles &&
      memcmp(params, _environmentParams, sizeof(_environmentParams)) == 0) {
    return;
  }

  const bool onlyNumbersMoved = sameFiles && _environmentRadiance != nullptr;
  memcpy(_environmentParams, params, sizeof(_environmentParams));

  if (onlyNumbersMoved) {
    [self rebuildEnvironmentLight];
    if (_environmentSkybox != nullptr) {
      _showingEnvironmentSkybox = params[2] != 0.0f;
      _scene->setSkybox(_showingEnvironmentSkybox ? _environmentSkybox
                                                  : _skybox);
    }
    return;
  }

  [self releaseEnvironment];
  _environmentRadiancePath = wantedRadiance;
  _environmentSkyboxPath = wantedSkybox;

  if (!wantedRadiance.empty()) {
    float3 harmonics[9];
    bool hasHarmonics = false;
    _environmentRadiance = [self cubemapAtPath:radiance
                                     harmonics:harmonics
                                      hasThose:&hasHarmonics
                                          note:@"environment"];
    if (_environmentRadiance != nullptr) {
      auto builder = IndirectLight::Builder();
      builder.reflections(_environmentRadiance);
      _environmentHasHarmonics = hasHarmonics;
      if (hasHarmonics) {
        for (int i = 0; i < 9; i++) _environmentHarmonics[i] = harmonics[i];
        // Three bands, which is what cmgen writes and what a diffuse
        // response actually needs: nine coefficients describe every low
        // frequency a matte surface can tell apart.
        builder.irradiance(3, harmonics);
      } else {
        _assetNotes[@"environment"] =
            @"This cubemap has no baked harmonics, so nothing matte is lit by "
            @"it. Bake it with cmgen rather than converting it by hand.";
      }
      _environmentLight = builder.intensity(_environmentParams[0])
                              .rotation(mat3f::rotation(_environmentParams[1],
                                                        float3{0, 1, 0}))
                              .build(*_engine);
    }
  }

  if (!wantedSkybox.empty()) {
    float3 unused[9];
    bool ignored = false;
    _environmentSkyTexture = [self cubemapAtPath:skybox
                                       harmonics:unused
                                        hasThose:&ignored
                                            note:@"skybox"];
    if (_environmentSkyTexture != nullptr) {
      _environmentSkybox = Skybox::Builder()
                               .environment(_environmentSkyTexture)
                               .showSun(false)
                               .build(*_engine);
      if (_environmentSkybox == nullptr) {
        _assetNotes[@"skybox"] =
            @"The cubemap loaded but no backdrop could be built from it.";
      }
    }

  }

  if (_environmentLight != nullptr) {
    // The flat ambient steps aside rather than being blended with: a scene
    // lit by a photograph of a room and by an even wash is lit twice.
    if (_ambient != nullptr) {
      _engine->destroy(_ambient);
      _ambient = nullptr;
    }
    _scene->setIndirectLight(_environmentLight);
  } else {
    // Nothing loaded, so the sky the day cycle has been writing goes back.
    [self setAmbientColour:_ambientColour intensity:_ambientIntensity];
  }

  _showingEnvironmentSkybox =
      _environmentSkybox != nullptr && _environmentParams[2] != 0.0f;

  if (_showingEnvironmentSkybox) {
    _scene->setSkybox(_environmentSkybox);
  } else if (_skybox != nullptr) {
    _scene->setSkybox(_skybox);
  }
}

/// Builds the indirect light again for a change of brightness or rotation.
///
/// Rather than mutated: an IndirectLight's intensity and rotation are fixed
/// when it is built. The cubemap behind it is not rebuilt, which is the
/// expensive half.
- (void)rebuildEnvironmentLight {
  if (_environmentRadiance == nullptr) return;

  IndirectLight *previous = _environmentLight;

  auto builder = IndirectLight::Builder();
  builder.reflections(_environmentRadiance);
  // From the copy kept when the file was read. The bundle is long gone and
  // Filament does not hand harmonics back, so this is the only place they
  // survive.
  if (_environmentHasHarmonics) {
    builder.irradiance(3, _environmentHarmonics);
  }

  IndirectLight *rebuilt =
      builder.intensity(_environmentParams[0])
          .rotation(mat3f::rotation(_environmentParams[1], float3{0, 1, 0}))
          .build(*_engine);

  _scene->setIndirectLight(rebuilt);
  if (previous != nullptr) _engine->destroy(previous);
  _environmentLight = rebuilt;
}

/// Gives back everything an environment was holding.
- (void)releaseEnvironment {
  if (_engine == nullptr) return;

  if (_environmentLight != nullptr) {
    _scene->setIndirectLight(nullptr);
    _engine->destroy(_environmentLight);
    _environmentLight = nullptr;
  }
  if (_environmentSkybox != nullptr) {
    if (_skybox != nullptr) _scene->setSkybox(_skybox);
    _engine->destroy(_environmentSkybox);
    _environmentSkybox = nullptr;
  }
  _showingEnvironmentSkybox = false;
  if (_environmentRadiance != nullptr) {
    _engine->destroy(_environmentRadiance);
    _environmentRadiance = nullptr;
  }
  if (_environmentSkyTexture != nullptr) {
    _engine->destroy(_environmentSkyTexture);
    _environmentSkyTexture = nullptr;
  }
  _environmentRadiancePath.clear();
  _environmentSkyboxPath.clear();
  _environmentHasHarmonics = false;
}

- (void)setRenderGraph:(const float *)passes
                 count:(uint32_t)count
               targets:(const float *)targets
           targetCount:(uint32_t)targetCount
                 names:(NSArray<NSString *> *)names {
  if (_disposed || _engine == nullptr) return;
  if (count > kMaxPasses) count = kMaxPasses;

  std::vector<float> passParams(passes, passes + count * kPassStride);
  std::vector<float> targetParams(targets,
                                  targets + targetCount * kTargetStride);
  std::vector<std::string> targetNames;
  targetNames.reserve(names.count);
  for (NSString *name in names) targetNames.emplace_back(name.UTF8String);

  // A graph arrives on every frame like everything else, and rebuilding views
  // and render targets sixty times a second to say nothing changed is the
  // whole cost of the feature paid for nothing.
  if (passParams == _graphPassParams && targetParams == _graphTargetParams &&
      targetNames == _graphTargetNames) {
    return;
  }
  _graphPassParams = std::move(passParams);
  _graphTargetParams = std::move(targetParams);
  _graphTargetNames = std::move(targetNames);

  [self releaseGraph];
  [self releaseEnvironment];

  // Nothing is bound to anything any more, so whatever is still retired can
  // go — and has to, because Filament asserts on a texture outliving its
  // engine.
  for (const RetiredTexture &retired : _retiredTextures) {
    _engine->destroy(retired.texture);
  }
  _retiredTextures.clear();
  _targetBindings.clear();

  _targets.resize(targetCount);
  for (uint32_t i = 0; i < targetCount; i++) {
    GraphTarget &target = _targets[i];
    const float *row = targets + i * kTargetStride;
    target.name =
        i < _graphTargetNames.size() ? _graphTargetNames[i] : std::string();
    target.width = static_cast<uint32_t>(std::max(0.0f, row[0]));
    target.height = static_cast<uint32_t>(std::max(0.0f, row[1]));
    target.scale = row[2] > 0.0f ? row[2] : 1.0f;
    target.keepsDepth = row[3] != 0.0f;
    target.keepsColour = row[4] != 0.0f;
  }

  _passes.resize(count);
  for (uint32_t i = 0; i < count; i++) {
    GraphPass &pass = _passes[i];
    const float *row = passes + i * kPassStride;
    pass.kind = static_cast<int>(row[0]);
    pass.into = static_cast<int>(row[1]);
    if (pass.into >= static_cast<int>(targetCount)) pass.into = -1;
    // The top bit is hiding, and a pass is not allowed to ask for it: an
    // object switched off should stay off however the graph is written.
    pass.layers = static_cast<uint8_t>(static_cast<int>(row[2])) & kAllLayers;
    pass.clears = row[3] != 0.0f;
    for (int p = 0; p < 4; p++) pass.plane[p] = row[8 + p];
  }

  // Built here rather than only at the top of the frame, because materials
  // are bound straight after this and a material sampling a target that does
  // not exist yet gets the blank white texture instead. That is not a
  // rendering fault anybody can see the cause of — it is a mirror that is
  // simply white, on the first frame and every frame after, because nothing
  // re-binds it.
  [self prepareTargets];
}

/// Makes sure every target a pass writes exists at the right size.
///
/// Called at the top of a frame rather than when the graph arrives, because
/// a target that follows the view has no size until the view has one — and
/// the view's size changes on a window drag, which is not when a graph is
/// sent.
- (void)prepareTargets {
  [self sweepRetiredTextures];

  bool rebuilt = false;
  for (GraphTarget &target : _targets) {
    uint32_t wide = target.width;
    uint32_t tall = target.height;
    if (wide == 0 || tall == 0) {
      wide = static_cast<uint32_t>(std::lround(_width * target.scale));
      tall = static_cast<uint32_t>(std::lround(_height * target.scale));
    }
    wide = std::max(1u, wide);
    tall = std::max(1u, tall);

    if (target.target != nullptr && target.builtWidth == wide &&
        target.builtHeight == tall) {
      continue;
    }

    [self releaseTarget:target];

    auto builder = RenderTarget::Builder();
    if (target.keepsColour) {
      // Sixteen bits a channel because what a pass draws is linear light
      // that another pass will sample and light with. Eight bits would clip
      // every highlight in a reflection to white.
      target.colour = Texture::Builder()
                          .width(wide)
                          .height(tall)
                          .levels(1)
                          .usage(Texture::Usage::COLOR_ATTACHMENT |
                                 Texture::Usage::SAMPLEABLE)
                          .format(Texture::InternalFormat::RGBA16F)
                          .build(*_engine);
      builder.texture(RenderTarget::AttachmentPoint::COLOR, target.colour);
    }
    if (target.keepsDepth) {
      target.depth = Texture::Builder()
                         .width(wide)
                         .height(tall)
                         .levels(1)
                         .usage(Texture::Usage::DEPTH_ATTACHMENT)
                         .format(Texture::InternalFormat::DEPTH32F)
                         .build(*_engine);
      builder.texture(RenderTarget::AttachmentPoint::DEPTH, target.depth);
    }

    // Neither colour nor depth is a target that cannot be drawn into. Left
    // null rather than half-built: a pass writing it is skipped and named,
    // which is a legible failure.
    if (target.colour == nullptr && target.depth == nullptr) continue;

    target.target = builder.build(*_engine);
    target.builtWidth = wide;
    target.builtHeight = tall;

    rebuilt = true;
  }

  // A texture cannot be resized, so a target that follows the view is a new
  // texture every time the window changes — and every material sampling the
  // old one is left pointing at a texture nothing writes to any more. What
  // that looks like is the missing-texture magenta, for ever, because a host
  // showing a scene that does not change never publishes again and nothing
  // asks for the binding a second time.
  //
  // So it is renewed here, by whoever rebuilt it.
  if (rebuilt) [self rebindTargets];
}

/// Points every material sampler that reads a pass at the texture that pass
/// now draws into.
- (void)rebindTargets {
  const TextureSampler drawn(TextureSampler::MinFilter::LINEAR,
                             TextureSampler::MagFilter::LINEAR,
                             TextureSampler::WrapMode::CLAMP_TO_EDGE);

  for (const TargetBinding &binding : _targetBindings) {
    Texture *texture = [self targetTextureNamed:binding.target];
    if (texture == nullptr) continue;
    binding.instance->setParameter(binding.parameter.c_str(), texture, drawn);
  }
}

/// The view a pass draws through, made on first use and kept.
- (View *)viewForPass:(GraphPass &)pass {
  if (pass.view != nullptr) return pass.view;

  pass.view = _engine->createView();
  pass.view->setScene(_scene);

  pass.cameraEntity = utils::EntityManager::get().create();
  pass.camera = _engine->createCamera(pass.cameraEntity);
  pass.view->setCamera(pass.camera);

  // No post on an off-screen pass. What another pass will sample has to stay
  // linear light: tone-mapping it here would bake a display curve into a
  // reflection and then light the scene with it.
  pass.view->setPostProcessingEnabled(false);
  return pass.view;
}

/// Points a pass's camera where it should be looking.
- (void)aimPass:(GraphPass &)pass wide:(uint32_t)wide tall:(uint32_t)tall {
  const double aspect = double(wide) / double(std::max(1u, tall));
  mat4 model = _camera->getModelMatrix();

  if (pass.kind == kPassReflection) {
    model = mat4(reflectionAbout(pass.plane)) * model;
    // Mirroring the world turns every triangle inside out, so what was the
    // front face is now the back. Without this a reflection is a view of the
    // insides of everything in it.
    pass.view->setFrontFaceWindingInverted(true);
  } else {
    pass.view->setFrontFaceWindingInverted(false);
  }

  pass.camera->setModelMatrix(mat4f(model));
  pass.camera->setProjection(_fieldOfView > 0 ? _fieldOfView : 50.0, aspect,
                             0.1, 1000.0);
  pass.camera->setExposure(_camera->getAperture(), _camera->getShutterSpeed(),
                           _camera->getSensitivity());
}

/// Gives up a target's render target now and its textures later.
///
/// Later because a material may be sampling one. A window being dragged
/// rebuilds every target that follows the view, and the materials pointing at
/// them are not re-bound until the host publishes again — so destroying the
/// texture here would leave the driver reading freed memory for however many
/// frames that takes. The same pattern the spent material instances use, and
/// for the same reason.
- (void)releaseTarget:(GraphTarget &)target {
  if (_engine == nullptr) return;
  if (target.target != nullptr) {
    // Nothing samples a render target, only the textures behind it, so this
    // one can go immediately.
    _engine->destroy(target.target);
    target.target = nullptr;
  }
  if (target.colour != nullptr) {
    _retiredTextures.push_back({target.colour, _materialGeneration});
    target.colour = nullptr;
  }
  if (target.depth != nullptr) {
    _retiredTextures.push_back({target.depth, _materialGeneration});
    target.depth = nullptr;
  }
  target.builtWidth = 0;
  target.builtHeight = 0;
}

/// Destroys the textures nothing can still be bound to.
///
/// A texture retired before the last publish has had a publish to re-bind
/// every material that was sampling it, so nothing points at it any more.
/// One retired *during* the current publish has not, and waits.
- (void)sweepRetiredTextures {
  if (_engine == nullptr) return;
  auto it = _retiredTextures.begin();
  while (it != _retiredTextures.end()) {
    if (it->afterGeneration < _materialGeneration) {
      _engine->destroy(it->texture);
      it = _retiredTextures.erase(it);
    } else {
      ++it;
    }
  }
}

/// Gives back every view, camera and target the graph was holding.
- (void)releaseGraph {
  if (_engine == nullptr) {
    _passes.clear();
    _targets.clear();
    return;
  }

  for (GraphPass &pass : _passes) {
    if (pass.view != nullptr) {
      _engine->destroy(pass.view);
      pass.view = nullptr;
    }
    if (!pass.cameraEntity.isNull()) {
      _engine->destroyCameraComponent(pass.cameraEntity);
      utils::EntityManager::get().destroy(pass.cameraEntity);
      pass.cameraEntity = utils::Entity();
      pass.camera = nullptr;
    }
  }
  for (GraphTarget &target : _targets) [self releaseTarget:target];

  _passes.clear();
  _targets.clear();
}

/// The texture a pass drew, by the name the graph gave it.
- (Texture *)targetTextureNamed:(const std::string &)name {
  for (GraphTarget &target : _targets) {
    if (target.name == name) return target.colour;
  }
  return nullptr;
}

- (void)setPipeline:(const float *)params count:(NSUInteger)count {
  if (_disposed || _view == nullptr) return;
  if (count > 32) count = 32;

  // Nothing moved. Worth checking first: half of what follows dirties a
  // render target or a shadow map, and a scene republished on every frame of
  // a drag changes none of it.
  if (count == _pipelineCount &&
      std::memcmp(_pipelineParams, params, sizeof(float) * count) == 0) {
    return;
  }
  const bool shadowsChanged =
      _pipelineCount != count ||
      std::memcmp(_pipelineParams, params, sizeof(float) * 10) != 0;
  std::memcpy(_pipelineParams, params, sizeof(float) * count);
  _pipelineCount = count;

  const bool shadowing = params[0] != 0.0f;
  _view->setShadowingEnabled(shadowing);

  switch (static_cast<int>(params[1])) {
    case 1:
      _view->setShadowType(ShadowType::DPCF);
      break;
    case 2:
      _view->setShadowType(ShadowType::PCSS);
      break;
    case 3:
      _view->setShadowType(ShadowType::VSM);
      break;
    default:
      _view->setShadowType(ShadowType::PCF);
      break;
  }

  SoftShadowOptions soft;
  soft.penumbraScale = params[9];
  soft.penumbraRatioScale = 1.0f;
  _view->setSoftShadowOptions(soft);

  // The multisample count is the one setting here that reallocates every
  // buffer in the view, so it is set through the same comparison as the rest
  // rather than every frame.
  MultiSampleAntiAliasingOptions msaa;
  msaa.enabled = params[14] > 1.0f;
  msaa.sampleCount = static_cast<uint8_t>(params[14] < 1 ? 1 : params[14]);
  _view->setMultiSampleAntiAliasingOptions(msaa);

  DynamicResolutionOptions resolution;
  resolution.enabled = true;
  resolution.homogeneousScaling = true;
  resolution.minScale = filament::math::float2{params[11], params[11]};
  resolution.maxScale = filament::math::float2{params[12], params[12]};
  resolution.sharpness = params[13];
  resolution.quality = View::QualityLevel::HIGH;
  _view->setDynamicResolutionOptions(resolution);

  const int flags = static_cast<int>(params[15]);
  View::RenderQuality quality;
  quality.hdrColorBuffer =
      (flags & 1) != 0 ? View::QualityLevel::ULTRA : View::QualityLevel::HIGH;
  _view->setRenderQuality(quality);

  // Where the light grid is anchored. Only worth setting when the host has
  // sent the two numbers — a shorter pipeline block is one from before they
  // existed, and Filament's own defaults are the right answer for it.
  if (_pipelineCount >= 18) {
    const float near = _pipelineParams[16] > 0 ? _pipelineParams[16] : 5.0f;
    // Far has to be beyond near or the grid has no depth to divide.
    const float far =
        _pipelineParams[17] > near ? _pipelineParams[17] : near + 1.0f;
    _view->setDynamicLightingOptions(near, far);
  }
  _view->setFrustumCullingEnabled((flags & 2) != 0);
  _view->setScreenSpaceRefractionEnabled((flags & 4) != 0);

  // Shadow options live on the light, not on the view, so every light that
  // already exists has to be told again. Only when something about shadows
  // actually changed: this walks every light in the scene.
  if (shadowsChanged) [self refreshShadowOptions];
}

/// Writes the pipeline's shadow settings onto one light.
- (void)shadowOptionsFor:(utils::Entity)entity {
  auto &lights = _engine->getLightManager();
  auto instance = lights.getInstance(entity);
  if (!instance) return;
  if (_pipelineCount == 0) return;

  LightManager::ShadowOptions options = lights.getShadowOptions(instance);
  options.mapSize = static_cast<uint32_t>(_pipelineParams[2]);
  const int cascades = static_cast<int>(_pipelineParams[3]);
  options.shadowCascades = static_cast<uint8_t>(cascades < 1   ? 1
                                                : cascades > 4 ? 4
                                                               : cascades);
  options.shadowFar = _pipelineParams[4];
  options.constantBias = _pipelineParams[6];
  options.normalBias = _pipelineParams[7];
  const int shadowFlags = static_cast<int>(_pipelineParams[8]);
  options.stable = (shadowFlags & 1) != 0;
  options.screenSpaceContactShadows = (shadowFlags & 2) != 0;

  // Where each cascade hands over to the next. Practical splits are the
  // usual compromise: evenly spaced wastes the near cascades on ground the
  // camera is standing on, and logarithmic wastes the far ones on sky.
  if (options.shadowCascades > 1) {
    const float far = options.shadowFar > 0 ? options.shadowFar : 100.0f;
    LightManager::ShadowCascades::computePracticalSplits(
        options.cascadeSplitPositions, options.shadowCascades, 0.1f, far,
        _pipelineParams[5]);
  }
  lights.setShadowOptions(instance, options);
}

/// Tells every light in the scene about a change to the shadow settings.
- (void)refreshShadowOptions {
  for (auto &entry : _lit) [self shadowOptionsFor:entry.second.entity];
}

- (void)applyVideos:(const int64_t *)keys
              flags:(const int32_t *)flags
             params:(const float *)params
              paths:(NSArray<NSString *> *)paths
              count:(uint32_t)count {
  if (_disposed) return;

  const uint64_t generation = ++_videoGeneration;
  _movieOrder.clear();
  _movieOrder.reserve(count);

  for (uint32_t i = 0; i < count; i++) {
    Movie &movie = _movies[keys[i]];
    movie.seen = generation;
    const float *values = params + i * kVideoParams;
    const std::string path =
        i < paths.count ? std::string(paths[i].UTF8String) : std::string();

    // A different file is a different video, whatever the key says. Anything
    // else — rate, volume, playing — is a change to this one.
    if (movie.player == nil || movie.path != path) [self open:movie atPath:path];
    if (movie.player == nil) {
      _movieOrder.push_back(&movie);
      continue;
    }

    movie.looping = (flags[i] & 2) != 0;

    // The seek is reconciled by its token rather than by its target, so
    // saying the same seek sixty times a second is one seek and not sixty.
    const int32_t token = static_cast<int32_t>(values[3]);
    if (token != movie.seekToken) {
      movie.seekToken = token;
      if (values[2] >= 0) {
        [movie.player seekToTime:CMTimeMakeWithSeconds(values[2], 600)
                 toleranceBefore:kCMTimeZero
                  toleranceAfter:kCMTimeZero];
      }
    }

    if (values[1] != movie.volume) {
      movie.volume = values[1];
      movie.player.volume = values[1];
    }

    const bool playing = (flags[i] & 1) != 0;
    if (flags[i] != movie.flags || values[0] != movie.rate) {
      movie.flags = flags[i];
      movie.rate = values[0];
      if (playing) {
        [movie.player playImmediatelyAtRate:movie.rate];
      } else {
        [movie.player pause];
      }
    }

    _movieOrder.push_back(&movie);
  }

  for (auto it = _movies.begin(); it != _movies.end();) {
    if (it->second.seen == generation) {
      ++it;
      continue;
    }
    [self close:it->second];
    it = _movies.erase(it);
  }
}

/// Takes whatever frame each decoder has ready and puts it on the GPU.
///
/// Called once a frame. A video that has not advanced hands back nothing and
/// costs a single comparison; the picture already on the texture stays.
- (void)pumpVideos {
  if (_movies.empty()) return;
  for (auto &entry : _movies) {
    Movie &movie = entry.second;
    if (movie.output == nil || movie.texture == nullptr) continue;

    const CMTime at = [movie.output itemTimeForHostTime:CACurrentMediaTime()];
    if (![movie.output hasNewPixelBufferForItemTime:at]) continue;
    CVPixelBufferRef buffer =
        [movie.output copyPixelBufferForItemTime:at itemTimeForDisplay:nullptr];
    if (buffer == nullptr) continue;

    movie.texture->setExternalImage(*_engine, buffer);
    // The one just replaced, not the one just set: the new buffer is what the
    // next draw reads, and releasing it here would pull the picture out from
    // under a frame that has not happened yet.
    if (movie.showing != nullptr) CVPixelBufferRelease(movie.showing);
    movie.showing = buffer;
  }
}

- (void)applyMaterials:(const int64_t *)keys
                 flags:(const int32_t *)flags
                params:(const float *)params
                  maps:(const int32_t *)maps
          texturePaths:(NSArray<NSString *> *)texturePaths
           textureSrgb:(const int32_t *)textureSrgb
                videos:(const int32_t *)videos
                 count:(uint32_t)count {
  if (_disposed) return;

  // Last publish's leavings, now that everything has been re-dressed.
  for (MaterialInstance *spent : _materialsSpent) {
    _engine->destroy(spent);
  }
  _materialsSpent.clear();

  const uint64_t generation = ++_materialGeneration;
  _materialOrder.clear();
  // Rebuilt by the writes below, so an instance that has gone does not
  // outlive its entry here.
  _targetBindings.clear();
  _materialOrder.reserve(count);
  _materialRebuilt.clear();
  _materialRebuilt.reserve(count);

  for (uint32_t i = 0; i < count; i++) {
    Surfaced &surface = _materials[keys[i]];
    surface.seen = generation;
    const float *values = params + i * kMaterialParams;
    const int32_t *entries = maps + i * kMaterialMaps;

    // A change of blend mode or shading is a different compiled material, so
    // the instance is replaced rather than reconfigured. Everything else is
    // set on the instance in place.
    const int wanted = [self surfaceIndexFor:flags[i]];
    const bool rebuild =
        surface.instance == nullptr ||
        [self surfaceIndexFor:surface.flags] != wanted ||
        surface.flags == -1;
    if (rebuild) {
      if (surface.instance != nullptr) {
        _materialsSpent.push_back(surface.instance);
      }
      surface.instance = [self surfaceAt:wanted]->createInstance();
      if ((flags[i] & 3) == 0) [self setDefaultsOn:surface.instance];
      surface.written = false;
    }

    if (rebuild || surface.flags != flags[i]) {
      surface.flags = flags[i];
      [self applyRasterState:surface
                withThreshold:values[17]
                         bias:values[18]];
      // A new sampler means every map has to be bound again, so the numbers
      // are rewritten with them rather than compared.
      surface.written = false;
    }

    const bool sameParams =
        (surface.flags & 3) != 2 && surface.written &&
        std::memcmp(surface.params, values, sizeof(float) * kMaterialParams) == 0 &&
        std::memcmp(surface.maps, entries, sizeof(int32_t) * kMaterialMaps) == 0;
    if (!sameParams) {
      std::memcpy(surface.params, values, sizeof(float) * kMaterialParams);
      std::memcpy(surface.maps, entries, sizeof(int32_t) * kMaterialMaps);
      surface.written = true;
      [self write:surface
            withParams:values
                  maps:entries
          texturePaths:texturePaths
           textureSrgb:textureSrgb
                 video:videos[i]];
      if (((surface.flags >> 2) & 15) == 3) {
        surface.instance->setMaskThreshold(values[17]);
      }
      surface.instance->setPolygonOffset(values[18], values[18] * 1000.0f);
    }

    _materialOrder.push_back(surface.instance);
    _materialRebuilt.push_back(rebuild);
  }

  // A material nothing is made of any more. Its instance goes; the textures
  // it used stay, because the next scene almost always wants them again and
  // an image is expensive to read twice.
  for (auto it = _materials.begin(); it != _materials.end();) {
    if (it->second.seen == generation) {
      ++it;
      continue;
    }
    if (it->second.instance != nullptr) {
      _materialsSpent.push_back(it->second.instance);
    }
    it = _materials.erase(it);
  }
}

/// Puts one object onto a material, or back onto the ones it came with.
- (void)dress:(Drawn &)drawn withMaterial:(int32_t)index {
  auto &renderableManager = _engine->getRenderableManager();
  MaterialInstance *instance =
      (index >= 0 && index < static_cast<int32_t>(_materialOrder.size()))
          ? _materialOrder[index]
          : nullptr;

  if (drawn.instance != nullptr) {
    const utils::Entity *entities = drawn.instance->getEntities();
    const size_t entityCount = drawn.instance->getEntityCount();

    // The file's own materials, kept the first time one is overridden. Every
    // primitive in order, so putting them back is the same walk.
    if (instance != nullptr && drawn.ownMaterials.empty()) {
      for (size_t i = 0; i < entityCount; i++) {
        auto renderable = renderableManager.getInstance(entities[i]);
        if (!renderable) continue;
        for (size_t p = 0; p < renderableManager.getPrimitiveCount(renderable); p++) {
          drawn.ownMaterials.push_back(
              renderableManager.getMaterialInstanceAt(renderable, p));
        }
      }
    }

    size_t slot = 0;
    for (size_t i = 0; i < entityCount; i++) {
      auto renderable = renderableManager.getInstance(entities[i]);
      if (!renderable) continue;
      for (size_t p = 0; p < renderableManager.getPrimitiveCount(renderable); p++) {
        MaterialInstance *chosen = instance;
        if (chosen == nullptr) {
          if (slot >= drawn.ownMaterials.size()) { slot++; continue; }
          chosen = drawn.ownMaterials[slot];
        }
        slot++;
        if (chosen != nullptr) {
          renderableManager.setMaterialInstanceAt(renderable, p, chosen);
        }
      }
    }
    return;
  }

  if (!drawn.entity) return;
  auto renderable = renderableManager.getInstance(drawn.entity);
  if (!renderable) return;
  // No material named: back to the object's own instance, which is what its
  // colour is written into.
  MaterialInstance *chosen = instance != nullptr ? instance : drawn.material;
  if (chosen != nullptr) {
    renderableManager.setMaterialInstanceAt(renderable, 0, chosen);
  }
}

- (void)applyObjects:(const int64_t *)keys
          transforms:(const float *)transforms
             colours:(const float *)colours
              meshes:(const int32_t *)meshes
               flags:(const int32_t *)flags
           materials:(const int32_t *)materials
               paths:(NSArray<NSString *> *)paths
               count:(uint32_t)count {
  if (_disposed) return;

  const uint64_t generation = ++_objectGeneration;
  auto &transformManager = _engine->getTransformManager();
  NSMutableDictionary<NSString *, NSString *> *notes =
      [NSMutableDictionary dictionary];

  for (uint32_t i = 0; i < count; i++) {
    std::string path;
    const int32_t meshIndex = meshes[i];
    if (meshIndex >= 0 && meshIndex < static_cast<int32_t>(paths.count)) {
      path = paths[meshIndex].UTF8String;
    }

    // Default-constructed on first sight, which is how a new object announces
    // itself: there is no separate "added" message, only a key nobody has
    // seen before.
    Drawn &drawn = _drawn[keys[i]];

    // Two objects claiming one identity: the second would take the first's
    // place, and one of them would appear to have been deleted. Keys are the
    // host's to keep unique, and this is where that goes wrong.
    if (drawn.seen == generation) {
      notes[@"keys"] = @"Two objects in this scene are sharing one key, so "
                       @"only one of them is drawn.";
      continue;
    }

    // A different file is a different object, so it is built again. Nothing
    // else is: the rest is written into what is already there.
    const bool exists = drawn.entity || drawn.instance != nullptr;
    if (exists && drawn.path != path) {
      [self recycle:drawn];
      drawn = Drawn{};
    }
    if (!drawn.entity && drawn.instance == nullptr) {
      [self build:drawn withPath:path];
    }
    drawn.seen = generation;

    mat4f placement;
    std::memcpy(&placement, transforms + i * 16, sizeof(float) * 16);
    // Compared rather than written blindly. Setting a transform dirties the
    // node and everything under it, and a scene republished on every frame of
    // a drag is one object moving and the rest standing perfectly still.
    if (!drawn.placed ||
        std::memcmp(&placement, &drawn.transform, sizeof(mat4f)) != 0) {
      drawn.transform = placement;
      drawn.placed = true;
      const utils::Entity root =
          drawn.instance != nullptr ? drawn.instance->getRoot() : drawn.entity;
      transformManager.setTransform(transformManager.getInstance(root),
                                    placement);
    }

    // A mesh brings its own materials out of the file, so the object's colour
    // reaches the placeholder cube and nothing else. Tinting somebody's model
    // by a swatch they never chose is worse than ignoring the swatch.
    if (drawn.material != nullptr) {
      const float3 colour = {colours[i * 3], colours[i * 3 + 1],
                             colours[i * 3 + 2]};
      if (colour.x != drawn.colour.x || colour.y != drawn.colour.y ||
          colour.z != drawn.colour.z) {
        drawn.colour = colour;
        drawn.material->setParameter("baseColor",
                                     float4{colour.x, colour.y, colour.z, 1.0f});
      }
    }

    if (flags[i] != drawn.flags) {
      drawn.flags = flags[i];
      [self applyFlags:flags[i] toDrawn:drawn];
    }

    // Compared rather than written, because dressing an object walks every
    // primitive it has and a model can have hundreds. The instance behind the
    // index may have changed underneath, but that is a change to the material
    // and the renderable is already pointing at it.
    // Re-dressed when the index moved, and also when the material at that
    // index was built afresh: the renderable holds the instance, not the
    // material, so a material that changed its blend mode is a new instance
    // and the old one is about to go.
    const int32_t wearing = materials[i];
    const bool remade = wearing >= 0 &&
                        wearing < static_cast<int32_t>(_materialRebuilt.size()) &&
                        _materialRebuilt[wearing];
    if (wearing != drawn.surface || remade) {
      drawn.surface = wearing;
      [self dress:drawn withMaterial:wearing];
    }
  }

  // Whatever this publish did not mention has left the scene. Sweeping by
  // stamp rather than by a removal message means a host cannot leak an object
  // by forgetting to say it went.
  for (auto it = _drawn.begin(); it != _drawn.end();) {
    if (it->second.seen == generation) {
      ++it;
      continue;
    }
    [self recycle:it->second];
    it = _drawn.erase(it);
  }

  _objectNotes = notes;
  _sceneIsOwnedByHost = true;
}

/// Writes one light's parameters into Filament.
///
/// Each setter is guarded by the kind that gives it meaning: a falloff radius
/// on a directional light or a cone angle on a point light are not harmless
/// no-ops inside Filament, they are questions it was never asked.
- (void)writeLight:(const Lit &)lit {
  auto &lights = _engine->getLightManager();
  auto instance = lights.getInstance(lit.entity);
  if (!instance) return;

  const float *p = lit.params;
  lights.setColor(instance, LinearColor{p[0], p[1], p[2]});
  lights.setIntensity(instance, p[3]);

  const float3 direction = {p[7], p[8], p[9]};
  // A zero direction would normalise to NaN and take the frame with it.
  if (lit.kind != 1 && length(direction) > 1e-6f) {
    lights.setDirection(instance, normalize(direction));
  }

  if (lit.kind == 0) {
    lights.setSunAngularRadius(instance, p[13]);
    // The disk in the sky is drawn at the light's own colour and brightness,
    // and the halo is the glow around it. A wide soft one reads as a sun
    // through air; a tight one reads as a moon on a clear night.
    lights.setSunHaloSize(instance, p[15]);
    lights.setSunHaloFalloff(instance, p[16]);
  } else {
    lights.setPosition(instance, float3{p[4], p[5], p[6]});
    lights.setFalloff(instance, p[10]);
    if (lit.kind == 2) lights.setSpotLightCone(instance, p[11], p[12]);
  }

  // Read only by percentage-closer soft shadows, so for now this is a value
  // carried faithfully rather than one that shows. It is what the penumbra
  // will be made of when the shadow type becomes somebody's to choose.
  LightManager::ShadowOptions options = lights.getShadowOptions(instance);
  // How big the light actually is, which is what area shadows work their
  // penumbra out from. Carried faithfully whatever the shadow kind, because
  // switching to area shadows should not need every light touched again.
  options.shadowBulbRadius = p[14];
  lights.setShadowOptions(instance, options);
  // And the pipeline's own settings, which a light that has just been built
  // has never been told.
  [self shadowOptionsFor:lit.entity];
}

- (void)applyLights:(const int64_t *)keys
              kinds:(const int32_t *)kinds
              flags:(const int32_t *)flags
             params:(const float *)params
              count:(uint32_t)count {
  if (_disposed) return;

  const uint64_t generation = ++_lightGeneration;
  auto &lights = _engine->getLightManager();
  auto &entities = utils::EntityManager::get();

  NSMutableDictionary<NSString *, NSString *> *notes =
      [NSMutableDictionary dictionary];
  uint32_t directional = 0;
  uint32_t punctual = 0;

  for (uint32_t i = 0; i < count; i++) {
    const int32_t kind = kinds[i];
    const float *p = params + i * kLightStride;

    // Filament shades one directional light per view. A second is dropped
    // rather than blended, and being told is the difference between a scene
    // that looks wrong and a scene that says why.
    if (kind == 0 && ++directional > 1) {
      notes[@"directional"] =
          @"Only one directional light is drawn. The others are ignored.";
      continue;
    }
    if (kind != 0) punctual++;

    Lit &lit = _lit[keys[i]];

    // The kind is fixed when a light is built, so changing it is a rebuild.
    // Only changing it is: a light being dragged keeps its entity, and with it
    // its shadow map, which is what stops the shadow flickering as it moves.
    if (lit.kind != kind) {
      if (lit.entity) {
        _scene->remove(lit.entity);
        _engine->destroy(lit.entity);
        entities.destroy(lit.entity);
      }
      lit = Lit{};
      lit.kind = kind;
      lit.entity = entities.create();
      LightManager::Builder(kind == 0   ? LightManager::Type::SUN
                            : kind == 2 ? LightManager::Type::FOCUSED_SPOT
                                        : LightManager::Type::POINT)
          .build(*_engine, lit.entity);
      _scene->addEntity(lit.entity);
    }
    lit.seen = generation;

    if (!lit.applied ||
        std::memcmp(p, lit.params, sizeof(lit.params)) != 0) {
      std::memcpy(lit.params, p, sizeof(lit.params));
      lit.applied = true;
      [self writeLight:lit];
    }

    if (flags[i] != lit.flags) {
      lit.flags = flags[i];
      auto instance = lights.getInstance(lit.entity);
      if (instance) lights.setShadowCaster(instance, (flags[i] & 1) != 0);
    }
  }

  if (punctual > kPunctualLightBudget) {
    notes[@"punctual"] = [NSString
        stringWithFormat:@"%u point and spot lights is past the %u this view "
                         @"shades. The ones furthest from the camera stop "
                         @"lighting anything.",
                         punctual, kPunctualLightBudget];
  }

  for (auto it = _lit.begin(); it != _lit.end();) {
    if (it->second.seen == generation) {
      ++it;
      continue;
    }
    if (it->second.entity) {
      _scene->remove(it->second.entity);
      _engine->destroy(it->second.entity);
      entities.destroy(it->second.entity);
    }
    it = _lit.erase(it);
  }

  _lightNotes = notes;
}

- (void)setPostProcess:(const float *)params count:(NSUInteger)count {
  if (_disposed || params == nullptr) return;

  // The same numbers as last frame mean the same view, and setting an option
  // struct makes Filament rebuild internal state. Comparing forty floats is
  // cheaper than doing that sixty times a second to say nothing changed.
  if (count == _postCount &&
      memcmp(params, _postParams, count * sizeof(float)) == 0) {
    return;
  }
  if (count > kMaxPostParams) count = kMaxPostParams;
  memcpy(_postParams, params, count * sizeof(float));
  _postCount = count;

  NSUInteger at = 0;
  auto next = [&]() -> float { return at < count ? params[at++] : 0.0f; };
  auto flag = [&]() -> bool { return next() > 0.5f; };

  const bool on = flag();
  const int antiAliasing = (int)next();
  const bool dither = flag();

  _view->setPostProcessingEnabled(on);
  // Everything below still runs when post-processing is off; Filament simply
  // ignores it. Reading the whole array either way keeps the offsets in one
  // place rather than in two.

  BloomOptions bloom;
  bloom.enabled = flag() && on;
  bloom.strength = next();
  bloom.levels = (uint8_t)std::clamp((int)next(), 1, 11);
  bloom.threshold = flag();
  bloom.lensFlare = flag();
  const float flareStrength = next();
  // Filament folds the flare into the bloom chain, so its own strength is the
  // ghost spacing and chromatic split rather than a separate amount. A flare
  // asked for at nothing is a flare turned off.
  if (flareStrength <= 0.0f) bloom.lensFlare = false;
  _view->setBloomOptions(bloom);

  DepthOfFieldOptions dof;
  dof.enabled = flag() && on;
  const float focus = next();
  dof.cocScale = next();
  dof.maxForegroundCOC = next();
  dof.maxBackgroundCOC = next();
  _view->setDepthOfFieldOptions(dof);
  // Where the sharp plane is belongs to the camera rather than to the effect:
  // it is the lens focusing, and the same distance means the same shot
  // whether or not the blur is switched on.
  if (dof.enabled && focus > 0.0f) {
    _camera->setFocusDistance(focus);
  }

  VignetteOptions vignette;
  vignette.enabled = flag() && on;
  vignette.midPoint = next();
  vignette.roundness = next();
  vignette.feather = next();
  const float vr = next();
  const float vg = next();
  const float vb = next();
  vignette.color = LinearColorA{vr, vg, vb, 1.0f};
  _view->setVignetteOptions(vignette);

  AmbientOcclusionOptions occlusion;
  occlusion.enabled = flag() && on;
  occlusion.radius = next();
  occlusion.intensity = next();
  occlusion.bias = next();
  const int aoQuality = std::clamp((int)next(), 0, 3);
  occlusion.quality = (QualityLevel)aoQuality;
  occlusion.bentNormals = flag();
  _view->setAmbientOcclusionOptions(occlusion);

  ScreenSpaceReflectionsOptions reflections;
  reflections.enabled = flag() && on;
  reflections.thickness = next();
  reflections.bias = next();
  reflections.maxDistance = next();
  reflections.stride = std::max(1.0f, next());
  _view->setScreenSpaceReflectionsOptions(reflections);

  const bool grading = flag();
  const int toneMapping = (int)next();
  const float exposure = next();
  const float contrast = next();
  const float saturation = next();
  const float vibrance = next();
  const float temperature = next();
  const float tint = next();
  float shadows[3], midtones[3], highlights[3];
  for (int i = 0; i < 3; ++i) shadows[i] = next();
  for (int i = 0; i < 3; ++i) midtones[i] = next();
  for (int i = 0; i < 3; ++i) highlights[i] = next();

  // Only when the grading numbers themselves have moved. A ColorGrading is a
  // baked lookup table rather than a struct of numbers, so rebuilding one
  // because somebody nudged the bloom would be a 32-cubed texture built to say
  // the colour did not change.
  const NSUInteger gradingFrom = at - 8 - 9;
  const bool gradingMoved =
      _colorGrading == nullptr ||
      memcmp(params + gradingFrom, _gradingParams,
             (8 + 9) * sizeof(float)) != 0;
  if (gradingMoved) {
    memcpy(_gradingParams, params + gradingFrom, (8 + 9) * sizeof(float));
  }

  if (gradingMoved)
    [self applyGrading:grading
          toneMapper:toneMapping
            exposure:exposure
            contrast:contrast
          saturation:saturation
            vibrance:vibrance
         temperature:temperature
                tint:tint
             shadows:shadows
            midtones:midtones
          highlights:highlights];

  // Temporal sampling needs the history buffer that only its own option turns
  // on, so the two settings have to agree.
  TemporalAntiAliasingOptions taa;
  taa.enabled = on && antiAliasing == 2;
  _view->setTemporalAntiAliasingOptions(taa);
  _view->setAntiAliasing(on && antiAliasing == 1 ? AntiAliasing::FXAA
                                                 : AntiAliasing::NONE);
  _view->setDithering(dither ? Dithering::TEMPORAL : Dithering::NONE);
}

/// Builds the colour grading, and keeps the one it built.
///
/// A ColorGrading is an engine resource with a lookup table baked into it, not
/// a struct of numbers — building one per frame would be a 32-cubed texture
/// per frame. This makes a new one only when the numbers have moved.
- (void)applyGrading:(BOOL)enabled
          toneMapper:(int)toneMapper
            exposure:(float)exposure
            contrast:(float)contrast
          saturation:(float)saturation
            vibrance:(float)vibrance
         temperature:(float)temperature
                tint:(float)tint
             shadows:(const float *)shadows
            midtones:(const float *)midtones
          highlights:(const float *)highlights {
  ColorGrading::Builder builder;

  // Tone mapping happens whether or not the rest of the grading is on:
  // something has to decide how light becomes pixels, and a clip at one is a
  // worse answer than a curve.
  switch (toneMapper) {
    case 1: builder.toneMapping(ColorGrading::ToneMapping::ACES); break;
    case 2: builder.toneMapping(ColorGrading::ToneMapping::ACES_LEGACY); break;
    case 3: builder.toneMapping(ColorGrading::ToneMapping::LINEAR); break;
    case 4: builder.toneMapping(ColorGrading::ToneMapping::LINEAR); break;
    default: builder.toneMapping(ColorGrading::ToneMapping::FILMIC); break;
  }

  if (enabled) {
    builder.exposure(exposure)
        .contrast(contrast)
        .saturation(saturation)
        .vibrance(vibrance)
        .whiteBalance(temperature, tint)
        // One call for all three, which is how Filament has it: the three
        // ranges overlap and the fourth argument is where they meet, so
        // setting one without the others would be setting half a decision.
        .shadowsMidtonesHighlights(
            {shadows[0], shadows[1], shadows[2], 0.0f},
            {midtones[0], midtones[1], midtones[2], 0.0f},
            {highlights[0], highlights[1], highlights[2], 0.0f},
            // The defaults: shadows fade out by a fifth of the range and
            // highlights come in at two thirds.
            {0.0f, 0.333f, 0.550f, 1.0f});
  }

  ColorGrading *built = builder.build(*_engine);
  if (built == nullptr) return;

  _view->setColorGrading(built);
  // Destroyed after the new one is in place, since the view was still holding
  // it a line ago and Filament reads it on the driver thread.
  if (_colorGrading != nullptr) _engine->destroy(_colorGrading);
  _colorGrading = built;
}

- (void)setFogEnabled:(BOOL)enabled params:(const float *)params {
  if (_disposed) return;

  FogOptions fog;
  fog.enabled = enabled;
  fog.color = LinearColor{params[0], params[1], params[2]};
  fog.density = params[3];
  fog.distance = params[4];
  // Never past the sky.
  //
  // Filament fogs everything in the view, and the sky is geometry like
  // anything else: a dome at nine hundred metres inside fog thick enough to
  // hide a valley is a dome nobody can see. Fog that reaches it turns the
  // whole frame into one flat grey, which is exactly what it did.
  //
  // Clamped here rather than asked of every caller, because a caller who
  // forgets does not get a subtly wrong sky, they get no sky at all.
  fog.cutOffDistance = std::min(params[5], kSkyRadius - 40.0f);
  fog.maximumOpacity = params[6];
  fog.height = params[7];
  fog.heightFalloff = params[8];
  _view->setFogOptions(fog);

  // Two things that are one thing. Filament's fog is the air between here and
  // the horizon — even, and right for distance. What it cannot do is have
  // shape: no amount of it looks like a bank of cloud lying in a valley,
  // because every cubic metre of it is the same as every other. The sheets
  // are that shape, and they sit inside the same haze rather than instead of
  // it.
  const float structure = params[9];
  const bool showing = enabled && structure > 0 && params[3] > 0;

  if (showing) {
    [self buildMist];

    // Ten sheets, each mostly transparent. What is seen is what they add up
    // to — one minus the light that gets through all of them — so each one has
    // to be far thinner than the bank as a whole. Sheets thick enough to read
    // on their own are sheets you can count.
    const float alpha = std::min(params[3] * 1.6f, 0.35f) * structure;

    // Wind arrives in metres a second and the noise is sampled in turns per
    // metre, so the rate the pattern scrolls at is the product of the two.
    // Negative because moving where the noise is read from backwards is what
    // moves the cloud forwards.
    const float2 wind = float2{params[10], params[11]};
    const float2 drift = -wind * params[12];

    for (MaterialInstance *instance : _mistInstances) {
      instance->setParameter("colour",
                             float3{params[0], params[1], params[2]});
      instance->setParameter("density", alpha);
      instance->setParameter("scale", params[12]);
      instance->setParameter("drift", drift);
      // Smooth haze at one end and torn wisps at the other, which is the
      // difference between weather and a filter over the lens.
      instance->setParameter("contrast", 1.5f + structure * 5.0f);
    }

    _mistHeight = params[7];
    _mistThickness = params[13];

    if (!_mistShowing) {
      for (utils::Entity entity : _mistEntities) _scene->addEntity(entity);
    }
  } else if (_mistShowing) {
    // Taken out of the scene rather than destroyed: turning the weather off
    // and on again is a slider, and rebuilding ten renderables under a
    // dragging finger would stutter.
    for (utils::Entity entity : _mistEntities) _scene->remove(entity);
  }

  _mistShowing = showing;
}

- (void)setSkyColour:(const float *)colour
             ambient:(float)ambient
            showBody:(BOOL)showBody {
  if (_disposed) return;

  const float3 sky = {colour[0], colour[1], colour[2]};
  const bool sameColour = _skyBuilt && sky.x == _skyColour.x &&
                          sky.y == _skyColour.y && sky.z == _skyColour.z;

  // Whether the sun's disk is drawn is fixed when a skybox is built, so only
  // that forces a new one. A colour is a setter, and a day cycle changing the
  // sky on every frame should cost one.
  if (!_skyBuilt || showBody != _skyShowsBody) {
    if (_skybox) {
      _scene->setSkybox(nullptr);
      _engine->destroy(_skybox);
    }
    _skybox = Skybox::Builder()
                  .color({sky.x, sky.y, sky.z, 1.0f})
                  .showSun(showBody)
                  .build(*_engine);
    // Kept, but not shown over an environment that is already the backdrop.
    // This runs after the environment on every publish, so installing it
    // unconditionally is a photographed sky replaced by a flat colour on the
    // frame after it loads — with nothing in the notes to say why.
    if (!_showingEnvironmentSkybox) _scene->setSkybox(_skybox);
    _skyShowsBody = showBody;
  } else if (!sameColour) {
    _skybox->setColor({sky.x, sky.y, sky.z, 1.0f});
  }

  // Lit by the sky it stands under, which is what makes the two read as one
  // environment rather than a backdrop behind an unrelated scene.
  //
  // The irradiance is fixed when an indirect light is built, so a change of
  // colour is a new one; a change of only its strength is a setter. Under a
  // day cycle both move together, and this object holds nine floats — the
  // rebuild is the cheap kind.
  if (!_skyBuilt || !sameColour) {
    [self setAmbientColour:sky intensity:ambient];
  } else if (ambient != _skyAmbient && _ambient) {
    _ambient->setIntensity(ambient);
  }

  _skyColour = sky;
  _skyAmbient = ambient;
  _skyBuilt = true;
}

- (void)setCameraPosition:(const float *)position
                   target:(const float *)target
              fieldOfView:(float)fieldOfView
             orthographic:(BOOL)orthographic
               viewHeight:(float)viewHeight
                       at:(double)at {
  if (_disposed) return;

  // Recorded, not applied.
  //
  // Two reasons, and the second one is a bug rather than a preference. The
  // first: this arrives on whatever clock the application runs on, and the
  // picture is drawn on the display's — two loops at similar but unequal
  // rates, so some frames were drawn twice with the same camera and some
  // skipped a whole word. Measured on a camera following a moving subject,
  // that is frames where the camera did not move at all next to frames where
  // it moved eight times as far, which is exactly what a judder is. The
  // picture now works out where the camera is at the moment it is drawn.
  //
  // The second: Filament's camera is not safe to touch from two threads, and
  // this is the platform thread while the engine's own thread is reading it.
  Aimed aimed;
  aimed.position = {position[0], position[1], position[2]};
  aimed.target = {target[0], target[1], target[2]};
  aimed.fieldOfView = fieldOfView;
  aimed.orthographic = orthographic;
  aimed.viewHeight = viewHeight;
  aimed.at = at;
  aimed.arrived = CFAbsoluteTimeGetCurrent();
  aimed.valid = true;

  [_aimLock lock];
  _aimedWas = _aimedNow;
  _aimedNow = aimed;
  [_aimLock unlock];

  // What the application itself is producing, before anything here touches
  // it. If its own motion is uneven then no amount of sampling will be even,
  // and the fault is on the other side of the message.
  if (_pacing && _toldAt > 0) {
    const double over = at - _toldAt;
    if (over > 1e-5 && over < 0.25) {
      const float speed = float(length(aimed.position - _toldFrom) / over);
      if (_toldCount > 0) _toldJerkTotal += std::abs(speed - _toldSpeedWas);
      _toldSpeedTotal += speed;
      _toldSpeedWas = speed;
      _toldCount++;
    }
  }
  _toldFrom = aimed.position;
  _toldAt = at;

  _cameraUpdates++;
}

/// Puts the camera where it should be at this instant.
///
/// Called once a frame, on the thread that draws. Between two words the
/// camera carries on at the speed those two implied, which turns a set of
/// steps arriving on somebody else's clock into a continuous motion sampled
/// on this one.
- (void)placeCamera {
  [_aimLock lock];
  const Aimed now = _aimedNow;
  const Aimed was = _aimedWas;
  [_aimLock unlock];

  if (!now.valid) return;

  const double span = now.at - was.at;

  // A gap that long is not a rate, it is a pause — the application was busy,
  // or has only just started. Starting from it would fling the camera.
  if (!was.valid || span <= 1e-5 || span >= 0.25) {
    _movingKnown = false;
    _spanUsual = 0;
    _carriedPosition = {0.0f, 0.0f, 0.0f};
    _carriedTarget = {0.0f, 0.0f, 0.0f};
    _spokeAt = now.at;
    _spokePosition = now.position;
    _spokeTarget = now.target;
    _fieldOfView = now.fieldOfView;
    _camera->lookAt(now.position, now.target, {0, 1, 0});
    [self projectWith:now.fieldOfView
         orthographic:now.orthographic
                 tall:now.viewHeight];
    return;
  }

  // The usual gap between words, followed. Everything below is measured in
  // these rather than in the last gap, which is far too noisy to steer by.
  _spanUsual = _spanUsual <= 0 ? span : _spanUsual + (span - _spanUsual) * 0.1;

  // Where the two clocks stand relative to each other, followed slowly.
  //
  // Each word carries the application's own time and arrives at some moment
  // here, and the difference is how far apart the clocks read. That difference
  // is steady; no single measurement of it is, because messages do not arrive
  // evenly. Following it slowly gives a reading that moves smoothly, which is
  // the whole point — a jumpy answer here would put the judder straight back.
  const double reading = now.at - now.arrived;
  if (!_clocksAligned || std::abs(reading - _clockOffset) > 0.25) {
    _clockOffset = reading;
    _clocksAligned = true;
  } else {
    _clockOffset += (reading - _clockOffset) * 0.05;
  }

  const double appNow = CFAbsoluteTimeGetCurrent() + _clockOffset;

  // How far from a given word the moment being drawn is.
  //
  // One expression, used both to draw and to work out how wrong the last
  // prediction was. Two nearly-identical versions of this is how a correction
  // ends up adding error instead of removing it.
  const double behind = -std::max(span, _spanUsual);
  const double reach = kCarryOn * _spanUsual;
  const auto leadFrom = [&](double word) {
    return float(std::clamp(
        appNow - word - kDrawBehind * _spanUsual, behind, reach));
  };

  if (now.at != _spokeAt) {
    // What would have been drawn this instant on the strength of the last
    // word, so the difference can be carried rather than appearing as a jump.
    const float wasLead = leadFrom(_spokeAt);
    const float3 wouldBe = _spokePosition + _aimVelocity * wasLead;
    const float3 wouldLook = _spokeTarget + _lookVelocity * wasLead;

    // How fast it is going, followed rather than taken fresh each time.
    //
    // Two positions and the time between them is a speed, and a noisy one:
    // the application's frames are not evenly spaced either, so a gap that
    // happens to be half the usual makes the speed twice the truth. Following
    // the estimate settles in about three words — fast enough to keep up with
    // a camera that is genuinely accelerating, slow enough to ignore the
    // timing noise underneath it.
    const float over = float(span);
    const float3 aimStep = (now.position - was.position) / over;
    const float3 lookStep = (now.target - was.target) / over;
    const float lensStep = (now.fieldOfView - was.fieldOfView) / over;

    if (!_movingKnown) {
      _aimVelocity = aimStep;
      _lookVelocity = lookStep;
      _lensVelocity = lensStep;
      _movingKnown = true;
    } else {
      constexpr float follow = 0.35f;
      _aimVelocity += (aimStep - _aimVelocity) * follow;
      _lookVelocity += (lookStep - _lookVelocity) * follow;
      _lensVelocity += (lensStep - _lensVelocity) * follow;
    }

    const float nowLead = leadFrom(now.at);
    _carriedPosition += wouldBe - (now.position + _aimVelocity * nowLead);
    _carriedTarget += wouldLook - (now.target + _lookVelocity * nowLead);

    _spokeAt = now.at;
    _spokePosition = now.position;
    _spokeTarget = now.target;
  }

  // The carried difference fades over a few frames rather than all at once.
  // It is the difference that decays, not the position, so the camera still
  // arrives exactly where it was told rather than trailing behind.
  const double drawnAt = CFAbsoluteTimeGetCurrent();
  const double gap = _placedAt > 0 ? drawnAt - _placedAt : 0;
  _placedWas = _placedAt;
  _placedAt = drawnAt;
  const float keep = float(std::exp(-std::max(gap, 0.0) / kAbsorb));
  _carriedPosition *= keep;
  _carriedTarget *= keep;

  const float by = leadFrom(now.at);

  if (_pacing) {
    _reachedCount++;
    if (appNow - now.at - kDrawBehind * _spanUsual >= reach) _saturated++;
  }

  // Read from the latest word at the speed the last few implied, rather than
  // by interpolating between the last two.
  //
  // Interpolating is the obvious thing and it is worse — measurably, by three
  // times. The two words either side are irregularly spaced, so dividing by
  // the gap between them turns their timing noise straight into speed, which
  // is the thing being got rid of. A followed speed has that noise taken out
  // of it already.
  const float3 position = now.position + _aimVelocity * by + _carriedPosition;
  const float3 target = now.target + _lookVelocity * by + _carriedTarget;
  const float fieldOfView = now.fieldOfView + _lensVelocity * by;

  _fieldOfView = fieldOfView;
  _orthographic = now.orthographic;
  _viewHeight = now.viewHeight;
  _camera->lookAt(position, target, {0, 1, 0});
  [self projectWith:fieldOfView
       orthographic:now.orthographic
               tall:now.viewHeight];
}

/// Sets how the camera turns the world into a picture.
///
/// The two kinds do not blend into one another — halfway between a flat view
/// and one with perspective is not a view of anything — so a camera that
/// changes kind changes it outright, and only the numbers move.
- (void)projectWith:(float)fieldOfView
       orthographic:(bool)orthographic
               tall:(float)tall {
  const double aspect = double(_width) / double(_height);

  if (orthographic) {
    const double half = std::max(tall, 0.001f) * 0.5;
    const double wide = half * aspect;
    // The near plane still has to be in front of the camera. It is tempting to
    // put it behind — nothing gets larger as it approaches a flat view, so a
    // negative near is geometrically fine — but the depth buffer is not
    // geometry: a range spanning zero maps depths onto each other, and then
    // the sky wins against the ground and the whole frame is sky.
    _camera->setProjection(Camera::Projection::ORTHO, -wide, wide, -half, half,
                           0.1, 4000.0);
    return;
  }

  _camera->setProjection(fieldOfView > 0 ? fieldOfView : 50.0, aspect, 0.1,
                         1000.0);
}

- (void)setExposure:(float)aperture
            shutter:(float)shutter
        sensitivity:(float)sensitivity {
  if (_disposed) return;
  // Filament asks for these in the units a photographer would state them in,
  // which is also how they arrive, so there is nothing to convert.
  _camera->setExposure(aperture, shutter, sensitivity);
}

- (void)allocateBuffers {
  _surface->allocate(_engine, _width, _height, _swapChains, kOrbisBufferCount);
  _backIndex = 0;
  _presentedIndex = -1;
}

- (void)releaseBuffers {
  _surface->release(_engine, _swapChains, kOrbisBufferCount);
}

- (void)applyViewportSize {
  _view->setViewport({0, 0, _width, _height});
  [self projectWith:_fieldOfView
       orthographic:_orthographic
               tall:_viewHeight];
}

- (void)resizeToWidth:(uint32_t)width height:(uint32_t)height {
  [_presentLock lock];
  _pendingWidth = MAX(width, 1u);
  _pendingHeight = MAX(height, 1u);
  [_presentLock unlock];
}

/// Draws every pass of the frame, in the order the graph put them in.
///
/// A graph nobody set is one pass, every layer, into the picture — which is
/// the frame this drew before there were passes at all, and is why a host
/// that has never heard of a graph pays nothing for one.
- (void)renderPasses {
  if (_passes.empty()) {
    _view->setVisibleLayers(0xFF, kAllLayers);
    _renderer->render(_view);
    return;
  }

  [self prepareTargets];

  for (GraphPass &pass : _passes) {
    const CFAbsoluteTime began = CFAbsoluteTimeGetCurrent();

    if (pass.into < 0) {
      _view->setVisibleLayers(0xFF, pass.layers);
      _renderer->render(_view);
    } else {
      GraphTarget &into = _targets[pass.into];
      // A target that could not be built is a pass that does not run. The
      // frame still draws, which is the difference between one broken
      // reflection and a black window.
      if (into.target != nullptr) {
        View *view = [self viewForPass:pass];
        view->setRenderTarget(into.target);
        view->setViewport({0, 0, into.builtWidth, into.builtHeight});
        view->setVisibleLayers(0xFF, pass.layers);
        [self aimPass:pass wide:into.builtWidth tall:into.builtHeight];
        _renderer->render(view);
      }
    }

    pass.milliseconds = (CFAbsoluteTimeGetCurrent() - began) * 1000.0;
  }
}

/// What each pass of the last frame cost, and how much it drew.
///
/// Read off the frame that has already happened rather than measured on
/// demand: asking a renderer to time itself when somebody looks changes what
/// is being timed.
- (NSArray<NSNumber *> *)passTimings {
  NSMutableArray<NSNumber *> *out =
      [NSMutableArray arrayWithCapacity:_passes.size() * 2];
  for (const GraphPass &pass : _passes) {
    [out addObject:@(pass.milliseconds)];
    [out addObject:@(pass.drawn)];
  }
  return out;
}

- (void)renderAtTime:(double)time {
  if (_disposed) return;
  try {
    [self drawAtTime:time];
  } catch (const std::exception &error) {
    NSLog(@"[orbis] render failed, stopping this viewport: %s", error.what());
    _disposed = YES;
  } catch (...) {
    NSLog(@"[orbis] render failed for an unknown reason.");
    _disposed = YES;
  }
}

- (void)drawAtTime:(double)time {

  // Resizing reallocates swap chains, which only the engine's own thread may
  // do, so a request from the UI thread is applied here instead of there.
  [_presentLock lock];
  BOOL needsResize = (_pendingWidth != _width || _pendingHeight != _height);
  uint32_t newWidth = _pendingWidth;
  uint32_t newHeight = _pendingHeight;
  [_presentLock unlock];

  if (needsResize) {
    [_presentLock lock];
    _presentedIndex = -1;  // nothing valid at the new size yet
    [_presentLock unlock];
    [self releaseBuffers];
    _width = newWidth;
    _height = newHeight;
    [self allocateBuffers];
    [self applyViewportSize];
  }

  [self placeCamera];
  [self rangePopulations];

  SwapChain *target = _swapChains[_backIndex];
  if (!target) return;

  // The placeholder turns so an unconfigured viewport is visibly alive. A
  // scene sent by a host is left exactly where the host put it — a renderer
  // that quietly animates somebody's content is worse than a still one.
  if (!_sceneIsOwnedByHost) {
    auto found = _drawn.find(kPlaceholderKey);
    if (found != _drawn.end() && found->second.entity) {
      auto &transforms = _engine->getTransformManager();
      transforms.setTransform(
          transforms.getInstance(found->second.entity),
          mat4f::rotation(time * 0.7, float3{0, 1, 0}) *
              mat4f::rotation(time * 0.35, float3{1, 0, 0}));
    }
  }

  [self updateCloudsAtTime:time];
  [self updateMistAtTime:time];
  [self updateRainAtTime:time];
  [self pollTextures];
  [self pumpVideos];

  if (!_renderer->beginFrame(target)) return;
  [self renderPasses];
  _renderer->endFrame();

  // Flutter may sample the moment this returns, so the frame has to be on the
  // surface before it is advertised as presented.
  _engine->flushAndWait();

  [_presentLock lock];
  _presentedIndex = _backIndex;
  _backIndex = (_backIndex + 1) % kOrbisBufferCount;
  [_presentLock unlock];

  // Debug aid: dumps exactly the buffer Flutter samples, which separates a
  // rendering fault from a handoff fault. Enabled by an environment variable
  // so it costs nothing when unset.
  if (_frameCount == 0) _startedAt = CFAbsoluteTimeGetCurrent();

  // How often the picture is drawn against how often it is told what to
  // draw. A camera that arrives at a different rate from the one it is drawn
  // at judders however smooth its own solution is.
  if (_pacing) {
    // What the frame actually cost the GPU, which is the number that matters:
    // how often it is presented is the display's business, and no amount of
    // headroom shows up there.
    const auto history = _renderer->getFrameInfoHistory(1);
    if (!history.empty() &&
        history[0].gpuFrameDuration > 0) {
      _gpuTotal += history[0].gpuFrameDuration / 1.0e6;
      _gpuCount++;
    }

    const double now = CFAbsoluteTimeGetCurrent();
    if (_pacedAt == 0) _pacedAt = now;
    // How far the camera moved between this frame and the last. Even motion
    // drawn evenly gives steps that are all the same size; a camera arriving
    // at a different rate from the one it is drawn at gives some frames two
    // steps and some none, which is what a judder is.
    // Not how big the steps are — a camera really does speed up and slow
    // down, and a figure of eight does it constantly. What judder is, is the
    // step changing from one frame to the next: real acceleration is smooth,
    // so consecutive steps differ by very little, while a camera arriving on
    // somebody else's clock gives one long step then a short one.
    // Per second, not per frame. Frames are not evenly spaced — the display
    // link wanders between sixty and eighty — so a camera moving perfectly
    // smoothly still covers different distances between them. Dividing by the
    // gap asks the only question that matters: was it going at an even speed.
    // Measured against when the camera was *sampled*, not when the frame was
    // presented. Those differ by however long the frame took to draw, and
    // dividing by the wrong one reports the renderer's own variation as if it
    // were the camera's.
    const float3 where = _camera->getPosition();
    const double gap = _placedAt - _placedWas;
    const float step = gap > 1e-6 ? float(length(where - _pacedFrom) / gap) : 0;
    _pacedFrom = where;
    if (_frameCount > 3 && gap > 1e-6) {
      _stepTotal += step;
      _jerkTotal += std::abs(step - _stepWas);
      _stepCount++;
    }
    _stepWas = step;

    if (_frameCount > 0 && _frameCount % 120 == 0) {
      const double over = now - _pacedAt;
      const float mean = _stepCount > 0 ? _stepTotal / _stepCount : 0;
      const float jerk = _stepCount > 0 ? _jerkTotal / _stepCount : 0;
      const float told =
          _toldCount > 1 ? _toldJerkTotal / (_toldCount - 1) : 0;
      const float toldMean = _toldCount > 0 ? _toldSpeedTotal / _toldCount : 0;
      NSLog(@"[orbis] gpu %.2f ms (%.0f/s if unbound); %.1f drawn/s, "
            @"%.1f camera/s; drawn unevenness %.0f%%, "
            @"told unevenness %.0f%%, prediction saturated %.0f%% of frames",
            _gpuCount > 0 ? _gpuTotal / _gpuCount : 0,
            _gpuCount > 0 && _gpuTotal > 0 ? 1000.0 * _gpuCount / _gpuTotal : 0,
            120.0 / over, _cameraUpdates / over,
            mean > 0 ? 100.0 * jerk / mean : 0,
            toldMean > 0 ? 100.0 * told / toldMean : 0,
            _reachedCount > 0 ? 100.0 * _saturated / _reachedCount : 0);
      _gpuTotal = 0;
      _gpuCount = 0;
      _toldSpeedTotal = 0;
      _toldJerkTotal = 0;
      _toldCount = 0;
      _reachedTotal = 0;
      _reachedCount = 0;
      _saturated = 0;
      _pacedAt = now;
      _cameraUpdates = 0;
      _stepTotal = 0;
      _jerkTotal = 0;
      _stepCount = 0;
    }
  }

  // Which frame to catch. Sixty by default, because that is a second in and
  // everything has settled. A number picks that frame instead; the word
  // `flash` waits for a strike, which is the only way to catch one — a bolt
  // lasts a tenth of a second and lands on whichever frame it lands on.
  const char *dumpAt = getenv("ORBIS_DUMP_FRAME");
  ++_frameCount;

  bool due = false;
  if (dumpAt) {
    if (strcmp(dumpAt, "flash") == 0) {
      due = _skyFlash > 0.5f && !_dumped;
    } else {
      const int wanted = atoi(dumpAt) > 1 ? atoi(dumpAt) : 60;
      due = _frameCount == wanted;
    }
  }

  if (due) {
    _dumped = true;
    // What sixty frames actually cost, so a change to the sky can be judged
    // on its price as well as on how it looks.
    const double elapsed = CFAbsoluteTimeGetCurrent() - _startedAt;
    NSLog(@"[orbis] 60 frames in %.2fs (%.1f ms each)", elapsed,
          elapsed * 1000.0 / 60.0);
    _surface->writeFrame(_presentedIndex);
  }
}

- (nullable CVPixelBufferRef)copyPresentedBuffer {
  [_presentLock lock];
  // Opaque on the way out of the surface and concrete here, which is the one
  // place on this platform that is entitled to know: the plugin hands it
  // straight to Flutter's texture registry, and the registry wants a
  // CVPixelBuffer.
  void *buffer = _surface->retainPresented(_presentedIndex);
  [_presentLock unlock];
  return (CVPixelBufferRef)buffer;
}

- (void)dispose {
  if (_disposed) return;
  _disposed = YES;

  // Filament asserts on anything still alive when the engine goes down, so the
  // teardown mirrors construction in reverse.
  [self removeEverything];

  // The graph's own views, cameras and targets, before the scene they point
  // at goes. _disposed is already set, so releaseGraph has to be able to run
  // afterwards — it checks the engine rather than that flag for exactly this.
  [self releaseGraph];

  for (auto &pair : _meshes) {
    if (pair.second.asset) _assetLoader->destroyAsset(pair.second.asset);
  }
  _meshes.clear();

  delete _resourceLoader;
  _resourceLoader = nullptr;
  gltfio::AssetLoader::destroy(&_assetLoader);
  _materialProvider->destroyMaterials();
  delete _materialProvider;
  _materialProvider = nullptr;
  delete _stbTextures;
  delete _ktxTextures;

  // Materials before their textures, and both before the engine goes: an
  // instance still pointing at a destroyed texture is a use-after-free the
  // next time anything is drawn.
  for (auto &entry : _materials) {
    if (entry.second.instance != nullptr) _engine->destroy(entry.second.instance);
  }
  for (MaterialInstance *spent : _materialsSpent) {
    _engine->destroy(spent);
  }
  _materialsSpent.clear();
  _materials.clear();
  _materialOrder.clear();
  _materialRebuilt.clear();
  for (auto &entry : _ownTextures) {
    if (entry.second != nullptr) _engine->destroy(entry.second);
  }
  _ownTextures.clear();
  delete _ownStbTextures;
  delete _ownKtxTextures;
  for (auto &entry : _movies) [self close:entry.second];
  _movies.clear();
  _movieOrder.clear();
  if (_blankTexture != nullptr) _engine->destroy(_blankTexture);
  if (_blankExternal != nullptr) _engine->destroy(_blankExternal);
  for (Material *surface : _surfaces) {
    if (surface != nullptr) _engine->destroy(surface);
  }

  auto &entities = utils::EntityManager::get();
  _engine->destroyCameraComponent(_cameraEntity);
  entities.destroy(_cameraEntity);
  for (auto &entry : _populations) [self clearPopulation:entry.second];
  _populations.clear();
  if (_instancedMaterial != nullptr) _engine->destroy(_instancedMaterial);

  _engine->destroy(_skybox);
  if (_ambient) _engine->destroy(_ambient);
  for (size_t sheet = 0; sheet < _mistEntities.size(); sheet++) {
    _scene->remove(_mistEntities[sheet]);
    _engine->destroy(_mistEntities[sheet]);
    entities.destroy(_mistEntities[sheet]);
    _engine->destroy(_mistInstances[sheet]);
  }
  _mistEntities.clear();
  _mistInstances.clear();

  if (_cloudEntity) {
    _scene->remove(_cloudEntity);
    _engine->destroy(_cloudEntity);
    entities.destroy(_cloudEntity);
    _cloudEntity = utils::Entity();
  }
  if (_cloudInstance) {
    _engine->destroy(_cloudInstance);
    _cloudInstance = nullptr;
  }
  if (_cloudMaterial) {
    _engine->destroy(_skyVertices);
    _engine->destroy(_skyIndices);
    _engine->destroy(_cloudMaterial);
    _cloudMaterial = nullptr;
  }

  for (size_t pane = 0; pane < _rainEntities.size(); pane++) {
    _scene->remove(_rainEntities[pane]);
    _engine->destroy(_rainEntities[pane]);
    entities.destroy(_rainEntities[pane]);
    _engine->destroy(_rainInstances[pane]);
  }
  _rainEntities.clear();
  _rainInstances.clear();

  if (_mistMaterial) {
    _engine->destroy(_mistMaterial);
    _mistMaterial = nullptr;
  }
  if (_rainMaterial) {
    _engine->destroy(_rainMaterial);
    _rainMaterial = nullptr;
  }
  if (_quadVertices) {
    _engine->destroy(_quadVertices);
    _engine->destroy(_quadIndices);
    _quadVertices = nullptr;
  }

  _engine->destroy(_vertexBuffer);
  _engine->destroy(_indexBuffer);
  [self releaseBuffers];
  _engine->destroy(_view);
  _engine->destroy(_scene);
  _engine->destroy(_renderer);
  Engine::destroy(&_engine);
  _engine = nullptr;

  // After the engine, because releasing the buffers needs it — the surface
  // owns the images and the engine owns the chains onto them.
  delete _surface;
  _surface = nullptr;
}

- (NSDictionary<NSString *, NSString *> *)notes {
  // Two sources, one answer. An unreadable file stays reported until it is
  // fixed, because it is read once; a light the scene has too many of stops
  // being reported the moment the scene stops having too many.
  NSMutableDictionary<NSString *, NSString *> *all =
      [NSMutableDictionary dictionaryWithDictionary:_assetNotes];
  [all addEntriesFromDictionary:_objectNotes];
  [all addEntriesFromDictionary:_lightNotes];
  return all;
}

- (void)dealloc {
  [self dispose];
}

@end
