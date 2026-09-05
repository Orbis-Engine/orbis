#import "OrbisRenderer.h"

#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

#include <filament/Camera.h>
#include <filament/Engine.h>
#include <filament/IndexBuffer.h>
#include <filament/IndirectLight.h>
#include <filament/LightManager.h>
#include <filament/Material.h>
#include <filament/MaterialInstance.h>
#include <filament/RenderableManager.h>
#include <filament/Renderer.h>
#include <filament/Scene.h>
#include <filament/Skybox.h>
#include <filament/SwapChain.h>
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
#include <math/mat4.h>
#include <utils/EntityManager.h>

#include <map>
#include <string>
#include <unordered_map>
#include <vector>
#include <utils/Panic.h>

#include <algorithm>
#include <cmath>
#include <exception>

#include "generated/lit_material.h"
#include "generated/mist_material.h"
#include "generated/clouds_material.h"
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

  /// The publish that last mentioned this object. Anything not stamped by the
  /// current one has left the scene.
  uint64_t seen = 0;
};

/// One light as the renderer holds it between frames.
///
/// The whole parameter block is kept rather than the fields that matter,
/// because comparing sixty-four bytes is cheaper than a dozen setter calls
/// that each dirty something downstream.
struct Lit {
  utils::Entity entity;
  int32_t kind = -1;
  int32_t flags = -1;
  float params[18] = {};
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
constexpr uint8_t kVisibleLayer = 0x01;
constexpr uint8_t kHiddenLayer = 0x02;

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

/// An IOSurface-backed BGRA buffer — the format Filament's Apple swap chain
/// requires and the one Flutter's compositor can adopt without a readback.
CVPixelBufferRef CreatePixelBuffer(uint32_t width, uint32_t height) {
  NSDictionary *attributes = @{
    (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
    (NSString *)kCVPixelBufferMetalCompatibilityKey : @YES,
  };
  CVPixelBufferRef buffer = nullptr;
  CVReturn result = CVPixelBufferCreate(
      kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
      (__bridge CFDictionaryRef)attributes, &buffer);
  return result == kCVReturnSuccess ? buffer : nullptr;
}

}  // namespace

@interface OrbisRenderer ()
- (void)startWithWidth:(uint32_t)width height:(uint32_t)height;
- (void)drawAtTime:(double)time;
@end

@implementation OrbisRenderer {
  Engine *_engine;
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
  Material *_material;
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

  CVPixelBufferRef _buffers[kOrbisBufferCount];
  SwapChain *_swapChains[kOrbisBufferCount];
  NSInteger _backIndex;
  NSInteger _presentedIndex;

  uint32_t _width;
  uint32_t _height;
  uint32_t _pendingWidth;
  uint32_t _pendingHeight;
  float _fieldOfView;

  NSLock *_presentLock;
  BOOL _disposed;
  int _frameCount;
}

- (nullable instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height {
  if (!(self = [super init])) return nil;

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

- (void)startWithWidth:(uint32_t)width height:(uint32_t)height {
  _width = MAX(width, 1u);
  _height = MAX(height, 1u);
  _pendingWidth = _width;
  _pendingHeight = _height;
  _presentedIndex = -1;
  _presentLock = [[NSLock alloc] init];

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
  _view->setVisibleLayers(0xFF, kVisibleLayer);

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
  [self applyObjects:key
          transforms:identity
             colours:colour
              meshes:noMesh
               flags:flags
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
  for (int i = 0; i < 24; i++) vertices[i] = {kPositions[i], quats[i]};

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

  _material = Material::Builder()
                  .package(klitMaterial, klitMaterial_len)
                  .build(*_engine);
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
                       .package(kcloudsMaterial, kcloudsMaterial_len)
                       .build(*_engine);

  const int rings = kSkyRings;
  const int segments = kSkySegments;
  const int count = (rings + 1) * (segments + 1);

  auto *vertices = new MistVertex[count];
  for (int ring = 0; ring <= rings; ring++) {
    // From a little below the horizon to straight up.
    const float t = float(ring) / float(rings);
    const float elevation = (-0.06f + 1.06f * t) * float(M_PI) * 0.5f;

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

- (void)setCloudsEnabled:(BOOL)enabled params:(const float *)params {
  if (_disposed) return;

  const float cover = params[3];
  const bool showing = enabled && cover > 0.01f;

  if (showing) {
    [self buildClouds];

    _cloudInstance->setParameter("colour",
                                 float3{params[0], params[1], params[2]});
    _cloudInstance->setParameter("cover", cover);
    _cloudInstance->setParameter("wind", float2{params[4], params[5]});
    _cloudInstance->setParameter("scale", params[6]);
    _cloudInstance->setParameter("altitude", std::max(params[7], 1.0f));

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
    _assetNotes[native] = @"The file could not be read.";
    return nullptr;
  }

  gltfio::FilamentInstance *first = nullptr;
  entry.asset = _assetLoader->createInstancedAsset(
      static_cast<const uint8_t *>(data.bytes),
      static_cast<uint32_t>(data.length), &first, 1);

  if (entry.asset == nullptr) {
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
  renderables.setLayerMask(instance, 0xFF,
                           (flags & kVisible) ? kVisibleLayer : kHiddenLayer);
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
  drawn.material = _material->createInstance();
  drawn.material->setParameter("roughness", 0.4f);
  drawn.material->setParameter("metallic", 0.0f);

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

- (void)applyObjects:(const int64_t *)keys
          transforms:(const float *)transforms
             colours:(const float *)colours
              meshes:(const int32_t *)meshes
               flags:(const int32_t *)flags
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
        drawn.material->setParameter("baseColor", colour);
      }
    }

    if (flags[i] != drawn.flags) {
      drawn.flags = flags[i];
      [self applyFlags:flags[i] toDrawn:drawn];
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
  options.shadowBulbRadius = p[14];
  lights.setShadowOptions(instance, options);
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
    const float *p = params + i * 16;

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

- (void)setFogEnabled:(BOOL)enabled params:(const float *)params {
  if (_disposed) return;

  FogOptions fog;
  fog.enabled = enabled;
  fog.color = LinearColor{params[0], params[1], params[2]};
  fog.density = params[3];
  fog.distance = params[4];
  fog.cutOffDistance = params[5];
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
    _scene->setSkybox(_skybox);
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
              fieldOfView:(float)fieldOfView {
  if (_disposed) return;

  _camera->lookAt({position[0], position[1], position[2]},
                  {target[0], target[1], target[2]}, {0, 1, 0});
  _camera->setProjection(fieldOfView, double(_width) / double(_height), 0.1,
                         1000.0);
  _fieldOfView = fieldOfView;
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
  for (int i = 0; i < kOrbisBufferCount; i++) {
    _buffers[i] = CreatePixelBuffer(_width, _height);
    _swapChains[i] =
        _buffers[i] ? _engine->createSwapChain(
                          (void *)_buffers[i],
                          SwapChain::CONFIG_APPLE_CVPIXELBUFFER)
                    : nullptr;
  }
  _backIndex = 0;
  _presentedIndex = -1;
}

- (void)releaseBuffers {
  for (int i = 0; i < kOrbisBufferCount; i++) {
    if (_swapChains[i]) {
      _engine->destroy(_swapChains[i]);
      _swapChains[i] = nullptr;
    }
    if (_buffers[i]) {
      CVPixelBufferRelease(_buffers[i]);
      _buffers[i] = nullptr;
    }
  }
}

- (void)applyViewportSize {
  _view->setViewport({0, 0, _width, _height});
  _camera->setProjection(_fieldOfView > 0 ? _fieldOfView : 50.0,
                         double(_width) / double(_height), 0.1, 1000.0);
}

- (void)resizeToWidth:(uint32_t)width height:(uint32_t)height {
  [_presentLock lock];
  _pendingWidth = MAX(width, 1u);
  _pendingHeight = MAX(height, 1u);
  [_presentLock unlock];
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

  if (!_renderer->beginFrame(target)) return;
  _renderer->render(_view);
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
  if (++_frameCount == 60 && getenv("ORBIS_DUMP_FRAME")) {
    // The app is sandboxed, so this goes to the container's temporary
    // directory rather than anywhere the caller might name.
    NSString *path =
        [NSTemporaryDirectory() stringByAppendingPathComponent:@"orbis_frame.png"];
    [self writeBuffer:_buffers[_presentedIndex] toPath:path.UTF8String];
  }
}

- (void)writeBuffer:(CVPixelBufferRef)buffer toPath:(const char *)path {
  if (!buffer) return;
  CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGContextRef context = CGBitmapContextCreate(
      CVPixelBufferGetBaseAddress(buffer), CVPixelBufferGetWidth(buffer),
      CVPixelBufferGetHeight(buffer), 8, CVPixelBufferGetBytesPerRow(buffer),
      space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
  CGImageRef image = CGBitmapContextCreateImage(context);
  CFURLRef url = CFURLCreateFromFileSystemRepresentation(
      nullptr, (const UInt8 *)path, strlen(path), false);
  CGImageDestinationRef destination =
      CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, nullptr);
  CGImageDestinationAddImage(destination, image, nullptr);
  BOOL wrote = CGImageDestinationFinalize(destination);
  NSLog(@"[orbis] frame %d (%zux%zu) -> %s : %@", _frameCount,
        CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), path,
        wrote ? @"written" : @"REFUSED");
  CFRelease(destination);
  CFRelease(url);
  CGImageRelease(image);
  CGContextRelease(context);
  CGColorSpaceRelease(space);
  CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
}

- (nullable CVPixelBufferRef)copyPresentedBuffer {
  [_presentLock lock];
  CVPixelBufferRef buffer =
      _presentedIndex >= 0 ? _buffers[_presentedIndex] : nullptr;
  if (buffer) CVPixelBufferRetain(buffer);
  [_presentLock unlock];
  return buffer;
}

- (void)dispose {
  if (_disposed) return;
  _disposed = YES;

  // Filament asserts on anything still alive when the engine goes down, so the
  // teardown mirrors construction in reverse.
  [self removeEverything];

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

  auto &entities = utils::EntityManager::get();
  _engine->destroyCameraComponent(_cameraEntity);
  entities.destroy(_cameraEntity);
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

  _engine->destroy(_material);
  _engine->destroy(_vertexBuffer);
  _engine->destroy(_indexBuffer);
  [self releaseBuffers];
  _engine->destroy(_view);
  _engine->destroy(_scene);
  _engine->destroy(_renderer);
  Engine::destroy(&_engine);
  _engine = nullptr;
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
