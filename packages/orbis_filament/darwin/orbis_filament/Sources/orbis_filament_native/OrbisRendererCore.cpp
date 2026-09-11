#include "OrbisRendererCore.h"

// The renderer's work, in the order OrbisRenderer.mm had it. See the header
// for how this file maps onto the old one.

#include <filament/LightManager.h>
#include <filament/Options.h>
#include <filament/RenderableManager.h>
#include <filament/TransformManager.h>
#include <filament/Viewport.h>
#include <geometry/SurfaceOrientation.h>
#include <gltfio/materials/uberarchive.h>
#include <image/Ktx1Bundle.h>
#include <ktxreader/Ktx1Reader.h>
#include <utils/EntityManager.h>
#include <utils/Panic.h>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <limits>

#include "OrbisBackend.h"
#include "OrbisDecals.h"

// M_PI is POSIX rather than C++, and MSVC only defines it when asked to.
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

using namespace filament;
using namespace filament::math;

namespace orbis {
namespace {

// The compiled materials and the lookup tables, as the C arrays setup.sh
// writes. In an anonymous namespace because xxd chooses their names and
// makes them global: a library other hosts link should not export
// `klit_opaqueMaterial` into their symbol table, and two copies of the
// renderer in one binary — as there briefly were while it moved — would not
// link at all.
#include "generated/lit_opaque_material.h"
#include "generated/sharpen_material.h"
#include "generated/smaa_edges_material.h"
#include "generated/smaa_weights_material.h"
#include "generated/smaa_blend_material.h"
#include "generated/bounce_material.h"
#include "generated/irradiance_material.h"
#include "generated/copy_material.h"
// SMAA's precomputed tables, fetched by setup.sh from the reference
// implementation. MIT, Jorge Jimenez et al. — see LICENSES/SMAA.txt.
#include "generated/AreaTex.h"
#include "generated/SearchTex.h"
#include "generated/LtcTables.h"
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

}  // namespace

Renderer::Renderer(OrbisSurface *surface, OrbisBackend backend) {
  // Made by the host rather than here: where a frame goes is the one part of
  // presenting that differs by platform, and the host is what knows which.
  _surface = surface;
  _backendAsked = backend;
}

Renderer::~Renderer() {
  dispose();
  // A renderer that never started still owns the surface it was given.
  delete _surface;
  _surface = nullptr;
}

bool Renderer::initWithWidth(uint32_t width, uint32_t height) {
  // Before Filament, because starting Filament allocates through it. The
  // host made it; a renderer given none has nowhere to present.
  if (_surface == nullptr) return false;

  // Filament reports misuse by throwing, and an uncaught throw here would take
  // the whole application down rather than the one viewport that failed. The
  // message is worth keeping: it names the precondition, which is most of the
  // diagnosis.
  try {
    startWithWidth(width, height);
  } catch (const std::exception &error) {
    orbis::log("[orbis] Filament refused to start: %s", error.what());
    return false;
  } catch (...) {
    orbis::log("[orbis] Filament refused to start for an unknown reason.");
    return false;
  }
  return true;
}

/// Says why Filament is about to abort.
///
/// Its preconditions throw, and the throw cannot be caught from here — not by
/// type and not by `...` — so the process goes down with only a stack to show
/// for it. This runs *before* the throw, which is the one place the reason
/// can be read.
static void orbisReportPanic(void *user, const utils::Panic &panic) {
  orbis::log("[orbis] Filament refused: %s\n  at %s (%s:%d)", panic.getReason(),
        panic.getFunction(), panic.getFile(), panic.getLine());
}

void Renderer::startWithWidth(uint32_t width, uint32_t height) {
  const double startedFrom = orbis::now();
  utils::Panic::setPanicHandler(orbisReportPanic, nullptr);
  _width = std::max(width, 1u);
  _height = std::max(height, 1u);
  _pendingWidth = _width;
  _pendingHeight = _height;
  _presentedIndex = -1;
  _pacing = getenv("ORBIS_PACE") != nullptr;

  // Asked for at the highest the device will give, because the standard
  // surface needs a tenth sampler and Filament rations them by feature level:
  // a material may have nine below the third, whatever the hardware could
  // manage. Metal on anything Orbis runs on reports the third — but it is
  // asked for rather than assumed, because an engine built above what the
  // device supports fails to build at all rather than falling back.
  //
  // Which backend is the platform's, or the host's if it named one: see
  // OrbisBackend.cpp. Tried in turn where there is something to fall back to
  // — Vulkan then OpenGL off Apple — because a machine with no Vulkan driver
  // should still draw rather than refuse to start. On Apple there is one
  // candidate, Metal, exactly as before.
  Engine::Builder builder;
  const std::vector<OrbisBackend> candidates =
      orbis::backendCandidates(_backendAsked);
  for (OrbisBackend candidate : candidates) {
    builder.backend(orbis::filamentBackend(candidate));
    try {
      _engine = builder.build();
    } catch (const std::exception &error) {
      orbis::log("[orbis] %s would not start: %s",
                 orbis::backendName(candidate), error.what());
      _engine = nullptr;
    }
    if (_engine != nullptr) {
      _backend = candidate;
      break;
    }
  }
  ASSERT_PRECONDITION(_engine != nullptr, "%s is unavailable.",
                      orbis::backendName(candidates.front()));

  // Raised after the fact rather than in the builder for the same reason:
  // this one clamps to what is supported instead of refusing, so a device
  // that cannot manage it keeps the surfaces it can compile rather than
  // getting a renderer that will not start.
  const Engine::FeatureLevel supported = _engine->getSupportedFeatureLevel();
  if (supported > Engine::FeatureLevel::FEATURE_LEVEL_1) {
    _engine->setActiveFeatureLevel(supported);
  }

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
  setSkyColour(defaultSky, kDefaultAmbientIntensity, true);

  startAssetLoader();
  buildGeometry();
  allocateBuffers();
  applyViewportSize();

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
  const int32_t noShapes[1] = {0};
  const float noWeights[1] = {0};
  applyObjects(key, identity, colour, noMesh, flags, noMaterial, noShapes, noWeights, {}, 1);
  _sceneIsOwnedByHost = false;

  const int64_t sunKey[1] = {kPlaceholderKey};
  const int32_t sunKind[1] = {0};
  const int32_t sunFlags[1] = {1};
  const float sun[18] = {1.0f, 0.96f, 0.9f, 110000.0f, 0,     0,
                         0,     -0.6f, -1.0f, -0.8f,     0,     0,
                         0,     0.53f, 0.1f,  10.0f,     80.0f, 0};
  applyLights(sunKey, sunKind, sunFlags, sun, 1);

  orbis::log("[orbis] engine ready in %.0f ms",
        (orbis::now() - startedFrom) * 1000);
}

void Renderer::buildGeometry() {
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
void Renderer::buildQuad() {
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
void Renderer::buildMist() {
  if (_mistMaterial != nullptr) return;
  buildQuad();

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
void Renderer::updateMistAtTime(double time) {
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
void Renderer::buildClouds() {
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
void Renderer::updateCloudsAtTime(double time) {
  if (!_cloudsShowing || !_cloudEntity) return;

  auto &transforms = _engine->getTransformManager();
  const float3 eye = _camera->getPosition();

  transforms.setTransform(
      transforms.getInstance(_cloudEntity),
      mat4f::translation(eye) * mat4f::scaling(float3{kSkyRadius}));

  _cloudInstance->setParameter("time", float(time));
  _cloudInstance->setParameter("eye", eye);
}

void Renderer::setSkyEnabled(bool enabled, const float *params) {
  // The third thing that wants to be the backdrop. An environment's cubemap
  // is behind everything; this dome is geometry in front of it, so leaving it
  // on hides a photographed sky completely — and there is nothing on screen
  // to say which of the two is winning.
  if (_showingEnvironmentSkybox) enabled = false;

  if (_disposed) return;

  const bool showing = enabled;

  if (showing) {
    buildClouds();

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
void Renderer::buildRain() {
  if (_rainMaterial != nullptr) return;
  buildQuad();

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
void Renderer::updateRainAtTime(double time) {
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

void Renderer::setPrecipitationEnabled(bool enabled, const float *params) {
  if (_disposed) return;

  const bool showing = enabled && params[3] > 0;

  if (showing) {
    buildRain();

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

void Renderer::setAmbientColour(float3 colour, float intensity) {
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

void Renderer::startAssetLoader() {
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
Mesh *Renderer::meshAtPath(const std::string &path) {
  auto found = _meshes.find(path);
  if (found != _meshes.end()) {
    return found->second.asset ? &found->second : nullptr;
  }

  // Recorded either way, so a missing file is read from disk once rather than
  // on every frame of a drag.
  Mesh &entry = _meshes[path];

  const std::string &native = path;
  const double readFrom = orbis::now();
  std::vector<uint8_t> data;
  if (!orbis::readFile(native, data)) {
    orbis::log("[orbis] mesh unreadable: %s", native.c_str());
    _assetNotes[native] = "The file could not be read.";
    return nullptr;
  }

  const double parsedFrom = orbis::now();
  gltfio::FilamentInstance *first = nullptr;
  entry.asset = _assetLoader->createInstancedAsset(
      data.data(), static_cast<uint32_t>(data.size()), &first, 1);

  if (entry.asset == nullptr) {
    orbis::log("[orbis] mesh not glTF: %s (%lu bytes)", native.c_str(),
               (unsigned long)data.size());
    _assetNotes[native] = "This is not a glTF file that Filament can read.";
    return nullptr;
  }

  const double providedFrom = orbis::now();

  // The glTF's own path, so it can find the .bin and the textures sitting
  // beside it. A .glb carries everything and does not need it.
  //
  // The file, not the directory it is in. Filament takes the last component
  // off this to get the directory, so handing it a directory throws away the
  // real one: a scene at assets/bistro/Bistro.gltf looked for its textures in
  // assets/Textures, found none of the four hundred, and drew every surface
  // black. Nothing failed — loadResources still returned true — so the scene
  // rendered in the right shape with no colour in it, and in daylight at a
  // hundred thousand lux it was still black, which is what finally said this
  // was not a lighting problem.
  _resourceLoader->setConfiguration({
      .engine = _engine,
      .gltfPath = path.c_str(),
      .normalizeSkinningWeights = true,
  });

  // Begun rather than waited for.
  //
  // loadResources decodes every texture before it returns, and this scene has
  // four hundred of them — so the application stopped dead for several seconds
  // on a mesh that was, geometrically, ready almost at once. Filament will
  // decode them on its own threads instead, and the frame loop nudges it along
  // by calling asyncUpdateLoad until it says it is finished.
  //
  // What that buys is that the scene appears immediately. The geometry is
  // there on the next frame and the textures arrive over the following ones,
  // which is a scene assembling itself rather than an application that has
  // hung.
  // Which of the files it names are actually there.
  //
  // Worth doing before the load rather than trusting the result of it: the
  // loader reports success whether or not a texture opened. A scene of four
  // hundred images once failed every one of them — the base path was wrong by
  // a directory — and still returned true, so the geometry appeared with no
  // colour on it and nothing anywhere said why. Two hours of that is what
  // this loop is for.
  {
    const char *const *uris = entry.asset->getResourceUris();
    const size_t count = entry.asset->getResourceUriCount();
    std::vector<std::string> sample;
    size_t missing = 0;

    // Which files this model names, resolved to where they are.
    //
    // Worked out first and read second, because reading four hundred files
    // one after another spends nearly all of its time waiting: the disk can
    // serve many at once and a single-file-at-a-time loop asks it for one.
    const std::string beside = orbis::deletingLastPathComponent(native);
    std::vector<Wanted> wanted;
    wanted.reserve(count);
    for (size_t i = 0; i < count; i++) {
      if (uris[i] == nullptr) continue;
      const std::string uri(uris[i]);
      // Data URIs carry their own bytes and embedded resources have no URI at
      // all; only a file on disk can be missing.
      if (orbis::hasPrefix(uri, "data:")) continue;

      // A glTF URI is a URI, so a space in a file name arrives as %20. The
      // path has to be the decoded form or the file is looked for under a
      // name nothing on disk has — and the answer would be "missing", which
      // is the one kind of wrong that sounds authoritative.
      const std::string name = orbis::removingPercentEncoding(uri);
      wanted.push_back(
          {uris[i], orbis::appendingPathComponent(beside, name), nullptr, 0});
    }

    // Read them all at once. The reads touch nothing shared — each writes
    // only its own slot — so this needs no lock, and the files come back in
    // whatever order the disk finds convenient.
    if (!wanted.empty()) {
      // The body captures the pointer, not the vector: capturing the vector
      // copies it, and a copy is not where the bytes are wanted.
      Wanted *slots = wanted.data();
      orbis::parallelFor(wanted.size(),
                         [slots](size_t i) { readWholeFile(slots[i]); });
    }

    // Handed over one at a time, because Filament is not being called from
    // several threads at once and this is not where the time was.
    for (const Wanted &one : wanted) {
      if (one.bytes == nullptr) {
        missing++;
        // A few names, not four hundred. The count is the number that
        // matters and the names are only there to recognise them by.
        if (sample.size() < 3) {
          sample.push_back(orbis::lastPathComponent(one.path));
        }
        continue;
      }
      _resourceLoader->addResourceData(
          one.uri, filament::backend::BufferDescriptor(
                       one.bytes, one.size,
                       [](void *buffer, size_t, void *) { free(buffer); }));
    }

    if (missing > 0) {
      std::string names;
      for (size_t i = 0; i < sample.size(); i++) {
        names += (i == 0 ? "" : ", ") + sample[i];
      }
      _assetNotes[native] = orbis::format(
          "%lu of its %lu files are missing, starting with "
          "%s. It will draw untextured.",
          (unsigned long)missing, (unsigned long)count, names.c_str());
      orbis::log("[orbis] %s: %s", native.c_str(), _assetNotes[native].c_str());
    }
  }

  if (!_resourceLoader->asyncBeginLoad(entry.asset)) {
    orbis::log("[orbis] mesh resources failed: %s", native.c_str());
    _assetNotes[native] = "Its geometry or textures could not be loaded.";
  } else {
    _loadingResources = true;
    // What the load cost, in the three parts it is actually made of.
    //
    // "It takes a few seconds" is not a thing anybody can act on: reading the
    // file, parsing it, and decoding its textures are three different costs
    // with three different fixes, and until they are separated the only
    // available move is to guess. Printed rather than measured on request
    // because a load happens once and the number is wanted the first time,
    // not after somebody has reproduced it.
    _loadingName = native;
    _loadingResourceCount = entry.asset->getResourceUriCount();
    _loadingFrom = orbis::now();
    orbis::log("[orbis] %s: read %.0f ms, parsed %.0f ms, %zu files handed over "
               "in %.0f ms",
               orbis::lastPathComponent(native).c_str(),
               (parsedFrom - readFrom) * 1000,
               (providedFrom - parsedFrom) * 1000, _loadingResourceCount,
               (_loadingFrom - providedFrom) * 1000);
  }

  // Deliberately not calling releaseSourceData: more instances can only be
  // made while it is still there, and a second object using this mesh is the
  // ordinary case rather than the exception.
  entry.all.push_back(first);
  entry.spare.push_back(first);
  return &entry;
}

/// A copy of a mesh to give an object, from the pool if one is spare.
gltfio::FilamentInstance *Renderer::takeInstanceOf(Mesh *mesh) {
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
void Renderer::recycle(Drawn &drawn) {
  if (drawn.instance != nullptr) {
    // Back onto the materials the file brought with it, before it goes in the
    // pool. An instance pooled while still pointing at an overriding material
    // outlives that material — the material is swept the moment nothing is
    // made of it — and the next object to take the instance out draws with a
    // pointer to something destroyed. Which is a crash, and the way to get
    // one is to turn a material off and on again.
    if (!drawn.ownMaterials.empty()) {
      dress(drawn, -1);
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
  // Borrowed, so only forgotten. The pool lets it go once nobody asks.
  drawn.pooled = nullptr;
}

/// Empties the scene of everything a host put in it.
void Renderer::removeEverything() {
  for (auto &pair : _drawn) recycle(pair.second);
  _drawn.clear();
  // After the objects, which were the only things wearing these.
  _colourPool.clear([this](MaterialInstance *spent) { _engine->destroy(spent); });

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
void Renderer::applyFlags(int32_t flags, utils::Entity entity) {
  auto &renderables = _engine->getRenderableManager();
  auto instance = renderables.getInstance(entity);
  // Not every entity in a glTF file is renderable — a joint or an empty
  // carries no geometry — so the ones without a component are skipped.
  if (!instance) return;
  renderables.setCastShadows(instance, (flags & kCastsShadows) != 0);
  renderables.setReceiveShadows(instance, (flags & kReceivesShadows) != 0);
  // Contact shadows are asked for twice in Filament: by the light, and by
  // every surface that is to receive them. Without the second the light's
  // switch does nothing at all — measured: the frame was byte-identical with
  // it on and off. Every receiver says yes here, so the pipeline's contact
  // switch is the one that decides; with it off, no light marches anything.
  renderables.setScreenSpaceContactShadows(
      instance, (flags & kReceivesShadows) != 0);
  renderables.setLayerMask(
      instance, 0xFF, (flags & kVisible) ? layerBitOf(flags) : kHiddenLayer);
}

/// Dials a mesh's shapes in, on every renderable the model is made of.
///
/// A glTF's morph targets belong to its primitives, and one model is usually
/// several — so the weights go to each of them rather than to the asset. A
/// renderable that has no shapes is skipped rather than refused: a scene that
/// sets a weight on the wrong object should do nothing, not stop.
void Renderer::morph(const Drawn &drawn, const float *weights, size_t count) {
  if (drawn.instance == nullptr || count == 0) return;

  auto &renderables = _engine->getRenderableManager();
  const utils::Entity *entities = drawn.instance->getEntities();
  const size_t parts = drawn.instance->getEntityCount();

  for (size_t part = 0; part < parts; part++) {
    auto instance = renderables.getInstance(entities[part]);
    if (!instance) continue;

    // Filament refuses more weights than the primitive was built with, and
    // that is a precondition rather than an error code — it takes the process
    // with it. A model with four shapes told about six gets four.
    const size_t room = renderables.getMorphTargetCount(instance);
    if (room == 0) continue;
    renderables.setMorphWeights(instance, weights, std::min(count, room), 0);
  }
}

/// Applies them to a whole object, which for a mesh is every part of it.
void Renderer::applyFlags(int32_t flags, const Drawn &drawn) {
  if (drawn.instance != nullptr) {
    const utils::Entity *entities = drawn.instance->getEntities();
    const size_t count = drawn.instance->getEntityCount();
    for (size_t i = 0; i < count; i++) {
      applyFlags(flags, entities[i]);
    }
    return;
  }
  applyFlags(flags, drawn.entity);
}

/// Builds one object: a mesh instance if it names a file that loads, and the
/// placeholder cube otherwise.
void Renderer::build(Drawn &drawn, const std::string &path) {
  drawn.path = path;

  if (!path.empty()) {
    Mesh *mesh = meshAtPath(path);
    if (mesh != nullptr) drawn.instance = takeInstanceOf(mesh);
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
  drawn.material = surfaceAt(0)->createInstance();
  setDefaultsOn(drawn.material);

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

double Renderer::gpuMilliseconds() {
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

/// What recent frames cost this renderer on the CPU, in milliseconds.
///
/// The other half of the answer. A frame has two costs and they fail
/// differently: the GPU number moves when the picture gets more expensive to
/// draw, and this one moves when the renderer gets more expensive to *drive* —
/// a scene reconciled less carefully, an allocation per frame that was not
/// there before, work done per object that used to be done per scene. A change
/// that leaves the picture identical can double this and never touch the GPU.
///
/// Filament already records beginFrame and endFrame, so this costs nothing to
/// collect. Median rather than mean, for the same reason as the GPU number: a
/// mean is dragged about by the one frame in thirty that hit a hitch, and what
/// anybody wants to know is what a frame usually costs.
double Renderer::cpuMilliseconds() {
  if (_disposed) return 0;

  const auto history = _renderer->getFrameInfoHistory(16);
  std::vector<double> costs;
  costs.reserve(history.size());

  for (const auto &frame : history) {
    // Both ends have to be real. A frame still in flight reports PENDING, and
    // treating that as a timestamp gives a duration of minus several years.
    if (frame.beginFrame > 0 && frame.endFrame > frame.beginFrame) {
      costs.push_back(double(frame.endFrame - frame.beginFrame) / 1.0e6);
    }
  }

  if (costs.empty()) return 0;
  std::sort(costs.begin(), costs.end());
  return costs[costs.size() / 2];
}

bool Renderer::hasPopulations() {
  return !_populations.empty();
}

/// Takes a population apart. Every buffer it holds is its own.
void Renderer::clearPopulation(Grown &grown) {
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

/// The instance buffer every population draw is given.
///
/// It holds identities and is never written to again. See the note where it
/// is bound for why a buffer that carries nothing is not optional.
filament::InstanceBuffer *Renderer::identityInstances() {
  if (_identityInstances == nullptr) {
    filament::math::mat4f nothing[kInstancesPerDraw];
    _identityInstances = filament::InstanceBuffer::Builder(kInstancesPerDraw)
                             .localTransforms(nothing)
                             .build(*_engine);
  }
  return _identityInstances;
}

/// Builds the renderables one population needs, in chunks of what Filament
/// will draw at once.
void Renderer::growPopulation(Grown &grown, uint32_t count, const float *bounds, int32_t flags) {
  clearPopulation(grown);
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
    // Bits two and three: how a member goes at the range. Sinking suits
    // anything planted, shrinking anything scattered, and neither suits a
    // continuous surface — so the population says which it is.
    material->setParameter("fadeMode", int32_t((flags >> 2) & 3));

    utils::Entity entity = utils::EntityManager::get().create();
    RenderableManager::Builder(1)
        // Every member is culled by this one box, so it has to cover all of
        // them. A box around the mesh rather than around the population would
        // make the lot disappear as soon as the camera left the origin.
        .boundingBox(box)
        .material(0, material)
        .geometry(0, RenderableManager::PrimitiveType::TRIANGLES, _vertexBuffer,
                  _indexBuffer, 0, 36)
        // Sixty-four identities, shared by every draw in every population.
        //
        // A member's real transform comes out of the book, so this buffer
        // carries nothing — and it still has to be here. Filament indexes a
        // block of per-renderable uniforms by `instance_index` to build the
        // world position the vertex shader is handed, and asking for copies
        // *without* an instance buffer leaves every slot but the first
        // undefined: they hold whatever the renderable drawn before them left
        // there. The shader reads that position back to recover where the
        // camera is, so a stale slot puts its cube somewhere else entirely —
        // and since what was drawn before depends on the order draws are
        // submitted in, the cube moves when the camera turns. Which is what
        // "blocks floating in random places when rotating" was.
        .instances(chunk, identityInstances())
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
void Renderer::sortPopulation(Grown &grown, const float *transforms) {
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
void Renderer::fillPopulation(Grown &grown, const float *transforms, const float *colours) {
  if (grown.book == nullptr || grown.count == 0) return;
  if (grown.order.size() != grown.count) {
    sortPopulation(grown, transforms);
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
void Renderer::rangePopulations() {
  const float3 eye = _camera->getPosition();

  for (auto &entry : _populations) {
    Grown &grown = entry.second;

    // Where the camera is, told to the material rather than left for it to
    // work out. It has to reach every population, ranged or not, because it
    // is what every member's position is now measured from — see the note on
    // `cameraAt` in instanced.mat.
    for (auto *material : grown.materials) {
      material->setParameter("cameraAt", filament::math::float3{eye});
    }

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
      // Flat, like the shader's own test, and for the same reason: a draw
      // judged on height leaves while the ground it stands on stays.
      const float3 apart = grown.middles[draw] - eye;
      const float across = std::sqrt(apart.x * apart.x + apart.z * apart.z);
      const float away = std::max(across - grown.radii[draw], 0.0f);

      // A cell of slack, because the shader measures to the middle of a
      // sixteen-block cell and a member can stand eleven from it. Dropping a
      // draw the shader would still have drawn from is the one mistake this
      // cannot make: it is a hole, and the holes are what this was.
      const bool wanted = away <= grown.range + kCellSide;

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

bool Renderer::hasSplats() {
  return _splats != nullptr && !_splats->empty();
}

void Renderer::applySplats(const int32_t *keys, const int32_t *flags, const int32_t *revisions, const float *params, const std::vector<std::string> &paths, const int32_t *changed, const int32_t *changedCounts, uint32_t changedCount, const uint8_t *data, size_t dataLength, uint32_t count) {
  if (_disposed) return;
  if (_splats == nullptr) {
    if (count == 0) return;
    _splats = std::make_unique<orbis::SplatScene>(*_engine, *_scene);
  }

  // Where each changed cloud's records begin in the packed bytes.
  std::unordered_map<int32_t, std::pair<size_t, size_t>> arriving;
  size_t at = 0;
  for (uint32_t c = 0; c < changedCount; c++) {
    const size_t bytes = size_t(std::max(changedCounts[c], 0)) *
                         orbis::kSplatRecordBytes;
    if (at + bytes > dataLength) break;
    arriving[changed[c]] = {at, bytes};
    at += bytes;
  }

  std::vector<orbis::SplatRequest> requests(count);
  for (uint32_t i = 0; i < count; i++) {
    orbis::SplatRequest &request = requests[i];
    request.key = keys[i];
    request.flags = flags[i];
    request.revision = revisions[i];
    request.params = params + size_t(i) * orbis::kSplatParams;
    request.path = i < paths.size() ? std::string(paths[i]) : "";
    auto found = arriving.find(keys[i]);
    if (found != arriving.end()) {
      request.data = data + found->second.first;
      request.bytes = found->second.second;
    }
  }

  std::vector<std::pair<std::string, std::string>> notes;
  _splats->apply(requests, notes);

  _splatNotes.clear();
  for (const auto &note : notes) {
    _splatNotes[note.first] = note.second;
    orbis::log("[orbis] splats: %s: %s", note.first.c_str(), note.second.c_str());
  }
}

void Renderer::applyPopulations(const int32_t *keys, const int32_t *counts, const int32_t *meshes, const int32_t *flags, const int32_t *revisions, const float *ranges, const float *bounds, const std::vector<std::string> &paths, const int32_t *changed, uint32_t changedCount, const float *transforms, const float *colours, uint32_t count) {
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
      growPopulation(grown, wanted, bounds + i * 6, flags[i]);
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
      fillPopulation(grown, transforms + found->second * 16, colours + found->second * 3);
      grown.revision = revisions[i];
    }
  }

  // Anything not named this time has gone.
  for (auto it = _populations.begin(); it != _populations.end();) {
    if (it->second.seen == generation) {
      ++it;
      continue;
    }
    clearPopulation(it->second);
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
int Renderer::surfaceIndexFor(int32_t flags) {
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
Material *Renderer::surfaceAt(int index) {
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
Texture *Renderer::blankTexture() {
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
void Renderer::setDefaultsOn(MaterialInstance *instance) {
  Texture *blank = blankTexture();
  TextureSampler sampler(TextureSampler::MinFilter::LINEAR_MIPMAP_LINEAR,
                         TextureSampler::MagFilter::LINEAR);
  sampler.setAnisotropy(8.0f);
  instance->setParameter("baseColor", float4{0.8f, 0.8f, 0.8f, 1.0f});
  instance->setParameter("metallic", 0.0f);
  instance->setParameter("roughness", 0.4f);
  instance->setParameter("reflectance", 0.5f);
  instance->setParameter("emissive", float3{0.0f, 0.0f, 0.0f});
  instance->setParameter("emissiveIntensity", 0.0f);
  instance->setParameter("ambientOcclusion", 1.0f);
  instance->setParameter("normalScale", 1.0f);
  instance->setParameter("uvTransform", float4{1.0f, 1.0f, 0.0f, 0.0f});

  // No coat, no grain, no sheen — said explicitly, for the same reason as
  // the blend below: undefined is not nought, and a surface that came up
  // varnished because nobody said otherwise is a hard fault to place.
  instance->setParameter("clearCoat", 0.0f);
  instance->setParameter("clearCoatRoughness", 0.1f);
  instance->setParameter("anisotropy", 0.0f);
  instance->setParameter("sheenColor", float3{0.0f, 0.0f, 0.0f});
  instance->setParameter("sheenRoughness", 0.3f);
  instance->setParameter("wind", float4{0.0f, 0.0f, 0.0f, 0.0f});

  // Not blending, said explicitly. A material declares these whether or not
  // it uses them, and one left unset is undefined rather than nought.
  instance->setParameter("blendMode", int32_t{0});
  instance->setParameter("blendAmount", 0.0f);
  instance->setParameter("blendSharpness", 8.0f);
  instance->setParameter("blendUvTransform", float4{1.0f, 1.0f, 0.0f, 0.0f});

  // Every map, from the one list. A sampler a material declares and nobody
  // binds is reported on every draw — and the report is right: what it would
  // sample is undefined.
  for (size_t i = 0; i < kMaterialMaps; i++) {
    instance->setParameter(kMapNames[i], blank, sampler);
    instance->setParameter(kMapFlags[i], false);
  }

  // The rectangular area lights, which only the lit surface shades — and this
  // runs for exactly the lit surfaces, the plain-coloured ones included. Bound
  // once and never again: both textures outlive every surface that reads them,
  // because the tables never change and the lights are rewritten in place.
  buildLtcTables();
  const TextureSampler tables(TextureSampler::MinFilter::LINEAR,
                              TextureSampler::MagFilter::LINEAR,
                              TextureSampler::WrapMode::CLAMP_TO_EDGE);
  // Filtered, which the fitted tables need. The rectangles in the rows below
  // are read with texelFetch, which ignores the sampler entirely, so they are
  // not interpolated into each other by sharing this one.
  instance->setParameter("lightData", _lightData, tables);

  // The rectangle's depth map. Built here if it does not exist yet rather
  // than left unbound: Filament reports a declared sampler nobody bound on
  // every draw, and it is right to — what it would read is undefined. A
  // scene with no casting rectangle still binds it and never looks at it,
  // because the flag in the light data is nought.
  buildAreaShadow();
  // Nearest, not linear. The lookup does its own filtering, and a linear tap
  // between two depths is a distance at which nothing stands; OpenGL ES also
  // refuses to filter a depth texture that has no comparison mode, and reads
  // it as nought — which here would be a shadow that silently never appears.
  const TextureSampler shadowSampler(TextureSampler::MinFilter::NEAREST,
                                     TextureSampler::MagFilter::NEAREST,
                                     TextureSampler::WrapMode::CLAMP_TO_EDGE);
  instance->setParameter("areaShadow", _areaShadow, shadowSampler);

  bindFieldTo(instance);

  // Decals, and the layer the surface is on — layer nought until an object
  // says otherwise, which is where every object that never mentions layers
  // lives.
  bindDecalsTo(instance);
  instance->setParameter("decalLayer", int32_t{1});
}

/// How much of the field reaches surfaces, held below where it feeds itself.
///
/// Reported rather than silently substituted: a host that asks for six and
/// quietly gets three has a scene that does not match its reference and no
/// way to find out why.
float Renderer::fieldStrength() {
  const float asked = _fieldParams[10];
  const float most = kFieldSafeGain / kFieldDamping;
  if (asked <= most) {
    _assetNotes.erase("fieldStrength");
    return asked;
  }
  _assetNotes["fieldStrength"] = orbis::format(
      "An irradiance field at a strength of %.1f feeds "
      "itself: it reads the picture it brightened, so the "
      "light goes round and drifts in hue rather than "
      "settling. Held at %.1f.",
      asked, most);
  return most;
}

/// Points every lit surface at the atlas holding this frame's answer.
///
/// Every frame, and it has to be: the two atlases are written in turn, so
/// which of them holds the answer changes with them, and a surface left
/// pointing at the one being written would read what is half-built. Cheap
/// because it is a handful of parameters over the surfaces that exist, and
/// skipped entirely by a scene with no field.
void Renderer::bindFieldEverywhere() {
  if (_fieldProbes == 0 || _fieldParams[0] <= 0.0f) return;
  for (auto &entry : _drawn) {
    if (entry.second.material != nullptr) {
      bindFieldTo(entry.second.material);
    }
  }
  // The batched cubes' shared surfaces are lit surfaces too. Left out, a
  // batched crate would read no bounced light, and batching would be visible.
  _colourPool.forEach([this](MaterialInstance *shared) { bindFieldTo(shared); });
  for (auto &entry : _materials) {
    if (entry.second.instance == nullptr) continue;
    if ((entry.second.flags & 3) != 0) continue;
    bindFieldTo(entry.second.instance);
  }
}

/// Gives one lit surface the field to read.
///
/// Every frame rather than once, because the two atlases are written in turn
/// and which of them holds the answer changes with them. A surface left
/// pointing at the one being written would read what is half-built.
void Renderer::bindFieldTo(MaterialInstance *instance) {
  const TextureSampler smooth(TextureSampler::MinFilter::LINEAR,
                              TextureSampler::MagFilter::LINEAR,
                              TextureSampler::WrapMode::CLAMP_TO_EDGE);
  Texture *atlas = _fieldAtlas[_fieldFront];
  const bool on =
      atlas != nullptr && _fieldProbes > 0 && _fieldParams[0] > 0.0f;
  // Bound whether or not there is a field: Filament refuses to draw a
  // material with a sampler nobody filled.
  instance->setParameter("fieldAtlas", on ? atlas : blankTexture(),
                         smooth);
  instance->setParameter(
      "fieldOrigin", float4{_fieldParams[1], _fieldParams[2], _fieldParams[3],
                            on ? 1.0f : 0.0f});
  instance->setParameter("fieldSpacing",
                         float4{_fieldParams[4], _fieldParams[5],
                                _fieldParams[6], fieldStrength()});
  instance->setParameter("fieldCounts",
                         float4{_fieldParams[7], _fieldParams[8],
                                _fieldParams[9], float(kFieldTilesPerRow)});
  const uint32_t rows =
      (std::max(_fieldProbes, 1u) + kFieldTilesPerRow - 1) / kFieldTilesPerRow;
  const float wide = float(kFieldTilesPerRow * kFieldTile);
  const float tall = float(std::max(rows, 1u) * kFieldTile);
  instance->setParameter(
      "fieldAtlasStep",
      float4{1.0f / wide, 1.0f / tall, _fieldParams[12], 0.0f});
}

/// Loads an image, or hands back the one already loaded for that path.
///
/// The colour space is part of the identity: the same file read as sRGB and
/// as linear are two different textures, and a normal map decoded as though
/// it were a colour bends every normal towards flat.
Texture *Renderer::textureAtPath(const std::string &path, bool srgb) {
  std::string identity = path + (srgb ? "|s" : "|l");

  // What a pass drew, rather than a file. Looked up every time rather than
  // cached: the target behind a name is rebuilt whenever the view is resized,
  // and a material still holding the old texture would be sampling something
  // the engine has destroyed.
  const std::string &wanted = path;
  if (wanted.rfind(kTargetScheme, 0) == 0) {
    return targetTextureNamed(wanted.substr(strlen(kTargetScheme)));
  }

  auto found = _ownTextures.find(identity);
  if (found != _ownTextures.end()) return found->second;

  // A failure is cached as null too. Forty objects naming a file that is not
  // there would otherwise each read the disk, every frame, forever.
  std::vector<uint8_t> data;
  Texture *texture = nullptr;
  if (orbis::readFile(path, data)) {
    const std::string extension = orbis::lowercasePathExtension(path);
    const char *mime = "image/png";
    gltfio::TextureProvider *provider = _ownStbTextures;
    if (extension == "jpg" || extension == "jpeg") {
      mime = "image/jpeg";
    } else if (extension == "ktx2") {
      mime = "image/ktx2";
      provider = _ownKtxTextures;
    }
    texture = provider->pushTexture(
        data.data(), data.size(), mime,
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
void Renderer::pollTextures() {
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
    orbis::log("[orbis] %d texture(s) never finished decoding; giving up polling",
          _texturesPending);
    _texturesPending = 0;
    _pollsWithoutProgress = 0;
  }
}

/// Builds the sampler a material's wrap and filter settings describe.
TextureSampler Renderer::samplerFor(int32_t flags) {
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
  // Anisotropy, unless the texture asked to be sharp.
  //
  // What it fixes is ground seen at a glancing angle, which is most of what a
  // camera at head height sees: a road or a floor stretching away is sampled
  // across a long thin footprint, and a mipmap chain can only pick one level
  // for it. Too fine and it crawls, too coarse and it is mud a few metres
  // out. Eight samples is the usual place to stop — past that the cost keeps
  // climbing and nobody can see the difference.
  if (!sharp) sampler.setAnisotropy(8.0f);
  return sampler;
}

/// Writes everything about one material into its instance.
void Renderer::write(Surfaced &surface, const float *params, const int32_t *maps, const std::vector<std::string> &texturePaths, const int32_t *textureSrgb, int32_t video) {
  MaterialInstance *instance = surface.instance;
  const int shading = surface.flags & 3;
  const bool unlit = shading == 1;
  const TextureSampler sampler = samplerFor(surface.flags);

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

    // The three extra lobes. Every one is nought by default, so a material
    // that asked for none is shaded as though they did not exist — but they
    // still have to be pushed, because an instance keeps whatever it was last
    // given and a surface that stopped being varnished would otherwise stay
    // varnished for the rest of its life.
    instance->setParameter("clearCoat", params[26]);
    instance->setParameter("clearCoatRoughness", params[27]);
    instance->setParameter("anisotropy", params[28]);
    instance->setParameter("sheenColor",
                           float3{params[29], params[30], params[31]});
    instance->setParameter("sheenRoughness", params[32]);

    // Wind. Direction on the ground, speed, and how much this surface
    // answers — the last is nought for anything rigid, which is the early
    // return in the vertex stage and therefore the cost of this feature for
    // every surface that does not use it.
    instance->setParameter(
        "wind", float4{params[33], params[34], params[35], params[36]});

    // The second surface. Only the lit material declares these, which is why
    // they are inside this branch rather than beside baseColor — Filament
    // treats a parameter a material has not declared as a mistake rather
    // than ignoring it.
    instance->setParameter("blendMode", static_cast<int32_t>(params[19]));
    instance->setParameter("blendAmount", params[20]);
    instance->setParameter("blendSharpness", params[21]);
    instance->setParameter(
        "blendUvTransform",
        float4{params[22], params[23], params[24], params[25]});
  }

  // kMapNames and kMapFlags are in the order the Dart side packs them. Only
  // the first is set for an unlit surface, which has nothing to do with the
  // rest.

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
    if (index >= 0 && index < static_cast<int32_t>(texturePaths.size())) {
      fromPass = orbis::hasPrefix(texturePaths[index], kTargetScheme);
      texture = textureAtPath(texturePaths[index], textureSrgb[index] != 0);
    }
    const bool present = texture != nullptr;
    instance->setParameter(kMapNames[i],
                           present ? texture : blankTexture(),
                           present && fromPass ? drawn : sampler);
    instance->setParameter(kMapFlags[i], present);

    if (fromPass) {
      const std::string path(texturePaths[index]);
      _targetBindings.push_back({instance, kMapNames[i],
                                 path.substr(strlen(kTargetScheme))});
    }
  }
}

/// Sets up the parts of a material that are rasteriser state rather than
/// shader input.
void Renderer::applyRasterState(Surfaced &surface, float threshold, float bias) {
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
/// The decoder is the platform's: AVFoundation on Apple, where the pixel
/// format Filament's external images need is asked for, and nothing yet
/// elsewhere, which the notes then say.
void Renderer::open(Movie &movie, const std::string &path) {
  close(movie);
  movie.path = path;
  if (path.empty()) return;

  // The platform's decoder, or none where there is not one yet — which is
  // said rather than failed: a scene with a screen in it still draws, and
  // the screen is blank.
  movie.decoder = orbis::createVideoDecoder();
  if (movie.decoder == nullptr) {
    _videoNotes[path] =
        "Video is not supported on this platform yet, so this screen is "
        "blank.";
    return;
  }
  if (!movie.decoder->open(path)) {
    movie.decoder.reset();
    return;
  }

  // The external image is the decoder's own buffer, so the texture is a
  // handle rather than storage: no width, no height, no format, and nothing
  // uploaded when the picture changes.
  movie.texture = Texture::Builder()
                      .sampler(Texture::Sampler::SAMPLER_EXTERNAL)
                      .format(Texture::InternalFormat::RGBA8)
                      .build(*_engine);
}

/// Stops a video and gives back everything it was holding.
void Renderer::close(Movie &movie) {
  // The decoder stops first — its end-of-file observer, its player, its
  // output — then the texture goes, and only then the last frame it showed,
  // which the decoder keeps until it is destroyed: releasing it while the
  // texture still pointed at it would pull the picture out from under a draw.
  if (movie.decoder != nullptr) movie.decoder->stop();
  if (movie.texture != nullptr) {
    _engine->destroy(movie.texture);
    movie.texture = nullptr;
  }
  movie.decoder.reset();
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
Texture *Renderer::cubemapAtPath(const std::string &path, float3 *harmonics,
                                 bool *hasThose, const std::string &note) {
  *hasThose = false;

  std::vector<uint8_t> data;
  if (!orbis::readFile(path, data)) {
    _assetNotes[note] = orbis::format("%s could not be read.",
                                      orbis::lastPathComponent(path).c_str());
    return nullptr;
  }

  // The bundle owns the pixels and has to outlive the upload, so it is handed
  // to createTexture along with the callback that frees it once the driver has
  // taken a copy. Freeing it here would be a race with the render thread.
  auto *bundle = new image::Ktx1Bundle(data.data(),
                                       static_cast<uint32_t>(data.size()));

  if (!bundle->isCubemap()) {
    _assetNotes[note] = orbis::format(
        "%s is not a cubemap. cmgen writes one; a flat image will not do.",
        orbis::lastPathComponent(path).c_str());
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
        orbis::format("%s is not a KTX this build can read.",
                      orbis::lastPathComponent(path).c_str());
    delete bundle;
  }
  return texture;
}

void Renderer::setEnvironmentRadiance(const std::string &radiance, const std::string &skybox, const float *params) {
  if (_disposed || _engine == nullptr) return;

  const std::string wantedRadiance(radiance);
  const std::string wantedSkybox(skybox);
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
    rebuildEnvironmentLight();
    if (_environmentSkybox != nullptr) {
      _showingEnvironmentSkybox = params[2] != 0.0f;
      _scene->setSkybox(_showingEnvironmentSkybox ? _environmentSkybox
                                                  : _skybox);
    }
    return;
  }

  releaseEnvironment();
  _environmentRadiancePath = wantedRadiance;
  _environmentSkyboxPath = wantedSkybox;

  if (!wantedRadiance.empty()) {
    float3 harmonics[9];
    bool hasHarmonics = false;
    _environmentRadiance = cubemapAtPath(radiance, harmonics, &hasHarmonics, "environment");
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
        _assetNotes["environment"] =
            "This cubemap has no baked harmonics, so nothing matte is lit by "
            "it. Bake it with cmgen rather than converting it by hand.";
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
    _environmentSkyTexture = cubemapAtPath(skybox, unused, &ignored, "skybox");
    if (_environmentSkyTexture != nullptr) {
      _environmentSkybox = Skybox::Builder()
                               .environment(_environmentSkyTexture)
                               .showSun(false)
                               .build(*_engine);
      if (_environmentSkybox == nullptr) {
        _assetNotes["skybox"] =
            "The cubemap loaded but no backdrop could be built from it.";
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
    setAmbientColour(_ambientColour, _ambientIntensity);
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
void Renderer::rebuildEnvironmentLight() {
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
void Renderer::releaseEnvironment() {
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

// Hook (screen effects): the host's god-ray and distortion settings, kept by
// the plain C++ side until an effect pass reads them.
void Renderer::setGodRays(const float *godRays, size_t count, const float *distortions, size_t distortionCount) {
  if (_disposed) return;
  _screenEffects.setGodRays(godRays, count);
  _screenEffects.setDistortions(distortions, distortionCount);
}

void Renderer::setRenderGraph(const float *passes, uint32_t count, const float *targets, uint32_t targetCount, const std::vector<std::string> &names) {
  if (_disposed || _engine == nullptr) return;
  if (count > kMaxPasses) count = kMaxPasses;

  std::vector<float> passParams(passes, passes + count * kPassStride);
  std::vector<float> targetParams(targets,
                                  targets + targetCount * kTargetStride);
  std::vector<std::string> targetNames;
  targetNames.reserve(names.size());
  for (const std::string &name : names) targetNames.emplace_back(name);

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

  releaseGraph();
  releaseEnvironment();

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
    for (int r = 0; r < 4; r++) pass.reads[r] = static_cast<int>(row[4 + r]);
    pass.effect = static_cast<int>(row[12]);
  }

  // Motion blur hook: whether this graph blurs, and whether any of its blurs
  // follow objects' own motion. What motion blur remembers and allocates all
  // waits on this, which is what keeps it free for a graph that never asks.
  {
    bool blurs = false;
    bool objects = false;
    for (const GraphPass &pass : _passes) {
      if (pass.kind != kPassEffect || pass.effect != kEffectMotionBlur) continue;
      blurs = true;
      objects = objects || pass.plane[2] >= 0.0f;
    }
    if (blurs && !_motionBlur) {
      _motionBlur = std::make_unique<orbis::MotionBlur>(*_engine);
    }
    if (_motionBlur) _motionBlur->setWanted(blurs, objects);
  }

  // Built here rather than only at the top of the frame, because materials
  // are bound straight after this and a material sampling a target that does
  // not exist yet gets the blank white texture instead. That is not a
  // rendering fault anybody can see the cause of — it is a mirror that is
  // simply white, on the first frame and every frame after, because nothing
  // re-binds it.
  prepareTargets();
}

/// Makes sure every target a pass writes exists at the right size.
///
/// Called at the top of a frame rather than when the graph arrives, because
/// a target that follows the view has no size until the view has one — and
/// the view's size changes on a window drag, which is not when a graph is
/// sent.
void Renderer::prepareTargets() {
  sweepRetiredTextures();

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

    releaseTarget(target);

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
      // Sampleable as well as attachable, so a later pass can read the
      // shape of the scene rather than only its colour. That is the whole
      // difference between an effect that can tint a picture and one that
      // knows what is in front of what — occlusion, bounced light, contact
      // shadows all begin here. It costs nothing when nothing samples it.
      target.depth = Texture::Builder()
                         .width(wide)
                         .height(tall)
                         .levels(1)
                         .usage(Texture::Usage::DEPTH_ATTACHMENT |
                                Texture::Usage::SAMPLEABLE)
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
  if (rebuilt) rebindTargets();
}

/// Points every material sampler that reads a pass at the texture that pass
/// now draws into.
void Renderer::rebindTargets() {
  const TextureSampler drawn(TextureSampler::MinFilter::LINEAR,
                             TextureSampler::MagFilter::LINEAR,
                             TextureSampler::WrapMode::CLAMP_TO_EDGE);

  for (const TargetBinding &binding : _targetBindings) {
    Texture *texture = targetTextureNamed(binding.target);
    if (texture == nullptr) continue;
    binding.instance->setParameter(binding.parameter.c_str(), texture, drawn);
  }
}

/// The view a pass draws through, made on first use and kept.
/// SMAA's lookup tables, uploaded the first time a weights pass runs.
///
/// Two channels for the area table, because a coverage answer is two numbers —
/// how much of the pixel each side of the edge takes. One for the search
/// table, which holds a distance. Both are read with linear filtering: the
/// index into them is fractional, and point-sampling a coverage table
/// quantises the anti-aliasing it is there to provide.
void Renderer::buildSmaaTables() {
  if (_smaaArea != nullptr) return;

  _smaaArea = Texture::Builder()
                  .width(AREATEX_WIDTH)
                  .height(AREATEX_HEIGHT)
                  .levels(1)
                  .format(Texture::InternalFormat::RG8)
                  .sampler(Texture::Sampler::SAMPLER_2D)
                  .build(*_engine);
  _smaaArea->setImage(
      *_engine, 0,
      Texture::PixelBufferDescriptor(
          areaTexBytes, AREATEX_SIZE,
          Texture::PixelBufferDescriptor::PixelDataFormat::RG,
          Texture::PixelBufferDescriptor::PixelDataType::UBYTE));

  _smaaSearch = Texture::Builder()
                    .width(SEARCHTEX_WIDTH)
                    .height(SEARCHTEX_HEIGHT)
                    .levels(1)
                    .format(Texture::InternalFormat::R8)
                    .sampler(Texture::Sampler::SAMPLER_2D)
                    .build(*_engine);
  _smaaSearch->setImage(
      *_engine, 0,
      Texture::PixelBufferDescriptor(
          searchTexBytes, SEARCHTEX_SIZE,
          Texture::PixelBufferDescriptor::PixelDataFormat::R,
          Texture::PixelBufferDescriptor::PixelDataType::UBYTE));
}

/// One rectangle's four texels, in the coordinates the surface shader reads.
///
/// The conversion from what an artist states to what the integral wants
/// happens here rather than in the shader, because it is the same answer for
/// every fragment the light touches.
void Renderer::packRectangle(const float *p, float *out, bool casting) {
  const float3 colour = {p[0], p[1], p[2]};
  const float lumens = p[3];
  const float3 centre = {p[4], p[5], p[6]};
  float3 normal = {p[7], p[8], p[9]};
  const float falloff = p[10];
  const float width = std::max(p[17], 1e-4f);
  const float height = std::max(p[18], 1e-4f);
  float3 tangent = {p[19], p[20], p[21]};

  // A direction that is not a direction is the commonest thing to be handed,
  // and normalising nothing gives NaN, which spreads to every pixel the light
  // reaches rather than to none of them.
  if (length(normal) < 1e-6f) normal = {0.0f, -1.0f, 0.0f};
  normal = normalize(normal);

  // The tangent only has to be roughly right: it is squared up against the
  // face here. If it was given parallel to the face's normal there is no
  // rectangle to describe, so any perpendicular will do.
  tangent = tangent - normal * dot(tangent, normal);
  if (length(tangent) < 1e-6f) {
    const float3 other =
        std::abs(normal.x) < 0.9f ? float3{1, 0, 0} : float3{0, 1, 0};
    tangent = other - normal * dot(other, normal);
  }
  tangent = normalize(tangent);

  // Crossed this way round so that cross(right, up) — which is what both the
  // integral and the shadow lookup take as the panel's axis — comes out as
  // *minus* the normal: it points from a lit surface back at the panel. The
  // integral wants that sign to keep the front lit and the back dark, and the
  // lookup wants it to tell a surface facing the panel from one edge-on to
  // it. Worth stating outright, because the identity that makes it true —
  // cross(t, cross(t, n)) is minus n — is not obvious at a glance, and both
  // readers of it would silently do the wrong thing if it flipped.
  const float3 up = cross(tangent, normal);

  // Lumens to luminance. A one-sided Lambertian panel of area A emitting a
  // luminous flux F has a luminance of F / (pi * A), and that is the unit
  // Filament's own lights arrive in, so a rectangle and a bulb of the same
  // stated brightness agree. It is also why making a panel larger does not
  // make a room brighter: the same flux is spread over more surface, which is
  // what softens the shadow rather than lifting the exposure.
  const float radiance =
      lumens / (float(M_PI) * std::max(width * height, 1e-6f));

  out[0] = centre.x;
  out[1] = centre.y;
  out[2] = centre.z;
  out[3] = 0.0f;
  out[4] = colour.x * radiance;
  out[5] = colour.y * radiance;
  out[6] = colour.z * radiance;
  // The inverse radius, so the shader multiplies rather than divides. Zero
  // means no window at all, which is a light that reaches as far as it is
  // bright enough to.
  out[7] = falloff > 1e-4f ? 1.0f / falloff : 0.0f;
  out[8] = tangent.x;
  out[9] = tangent.y;
  out[10] = tangent.z;
  out[11] = width;
  out[12] = up.x;
  out[13] = up.y;
  out[14] = up.z;
  out[15] = height;

  // Whether this one casts, and the numbers the lookup needs to turn what
  // the map holds into metres and a penumbra: see packAreaShadowSettings.
  orbis::packAreaShadowSettings(casting, _areaShadowFrame, width, height,
                                out + 16);

  if (casting) {
    // Column major, as the shader's mat4 constructor reads it: four texels,
    // each one a column.
    const filament::math::mat4f &m = _areaShadowMatrix;
    for (int c = 0; c < 4; c++) {
      out[20 + c * 4 + 0] = m[c][0];
      out[20 + c * 4 + 1] = m[c][1];
      out[20 + c * 4 + 2] = m[c][2];
      out[20 + c * 4 + 3] = m[c][3];
    }
  }
}

/// Puts this frame's rectangles on the GPU, and tells the surfaces if how
/// many there are has changed.
void Renderer::uploadRectangles(const float *rectangles, uint32_t count) {
  if (_lightData == nullptr) return;

  const size_t floats = size_t(kAreaLightTexels) * kAreaLightBudget * 4;

  std::vector<float> wanted(floats, 0.0f);
  memcpy(wanted.data(), rectangles,
         size_t(count) * kAreaLightTexels * 4 * sizeof(float));
  // How many, in the first light's spare channel. With no lights the whole
  // texture is zeros, which reads as a count of nought without needing a
  // special case for it.
  wanted[3] = float(count);

  if (wanted == _areaLightsOnGpu) return;
  _areaLightsOnGpu = wanted;

  // Its own copy rather than the vector's storage: the descriptor keeps the
  // pointer until the driver thread performs the upload, and the vector is
  // free to be reassigned before then.
  float *copy = static_cast<float *>(malloc(floats * sizeof(float)));
  memcpy(copy, wanted.data(), floats * sizeof(float));
  // Only the four columns the rectangles use, in the rows below the tables.
  _lightData->setImage(
      *_engine, 0, 0, 64, kAreaLightTexels, kAreaLightBudget,
      Texture::PixelBufferDescriptor(
          copy, floats * sizeof(float),
          Texture::PixelBufferDescriptor::PixelDataFormat::RGBA,
          Texture::PixelBufferDescriptor::PixelDataType::FLOAT,
          [](void *buffer, size_t, void *) { free(buffer); }));
}

/// Draws what the casting rectangle can see, into its own depth map.
///
/// Nothing at all when no rectangle casts, which is the usual answer: the
/// view is not rendered, so the map keeps whatever it held and the surfaces
/// never look at it because their flag is nought.
void Renderer::renderAreaShadow() {
  if (!_areaShadowCasting || _areaShadowView == nullptr) return;
  _renderer->render(_areaShadowView);
}

/// The one rectangle's depth map, and the view that draws it.
///
/// Built on first use rather than at startup, because most scenes have no
/// casting rectangle and a megapixel of depth is not worth reserving against
/// the chance of one.
void Renderer::buildAreaShadow() {
  if (_areaShadow != nullptr) return;

  _areaShadow = Texture::Builder()
                    .width(kAreaShadowSide)
                    .height(kAreaShadowSide)
                    .levels(1)
                    // Depth rather than colour: the scene is drawn with no
                    // shading at all, so there is nothing to keep but how far
                    // away it was. A colour target would mean a material of
                    // its own on every object to write distance into it.
                    .format(Texture::InternalFormat::DEPTH32F)
                    .usage(Texture::Usage::DEPTH_ATTACHMENT |
                           Texture::Usage::SAMPLEABLE)
                    .build(*_engine);

  _areaShadowTarget = RenderTarget::Builder()
                          .texture(RenderTarget::AttachmentPoint::DEPTH,
                                   _areaShadow)
                          .build(*_engine);

  _areaShadowCameraEntity = utils::EntityManager::get().create();
  _areaShadowCamera = _engine->createCamera(_areaShadowCameraEntity);

  _areaShadowView = _engine->createView();
  _areaShadowView->setScene(_scene);
  _areaShadowView->setCamera(_areaShadowCamera);
  _areaShadowView->setRenderTarget(_areaShadowTarget);
  _areaShadowView->setViewport({0, 0, kAreaShadowSide, kAreaShadowSide});
  // Nothing here is looked at, so nothing here is worth computing. Filament
  // still runs the fragment stage for anything that could discard, which is
  // why a masked leaf still cuts its own shape out of the shadow.
  _areaShadowView->setShadowingEnabled(false);
  _areaShadowView->setPostProcessingEnabled(false);
  _areaShadowView->setFrustumCullingEnabled(true);
}

/// Where the casting rectangle stands, as a matrix that turns a point in the
/// world into a place on its depth map.
///
/// A perspective frustum rather than an orthographic one, because a panel is
/// somewhere rather than everywhere: a wall two metres behind a lamp should
/// not be in its map, and a light that fills the room in front of it is what
/// the falloff radius already describes.
bool Renderer::aimAreaShadowAt(const float *p) {
  orbis::AreaShadowFrame frame;
  if (!orbis::frameAreaShadow(float3{p[4], p[5], p[6]},
                              float3{p[7], p[8], p[9]}, p[17], p[18], p[10],
                              frame)) {
    return false;
  }
  _areaShadowFrame = frame;

  // Filament's own projection: the far plane at infinity for drawing, the
  // finite one kept only for culling. A custom matrix with a finite far was
  // used here before, and it works, but it puts the map's depth on a curve
  // that depends on both planes; at infinity it is exactly near / distance,
  // which the surface can turn back into metres with one divide.
  _areaShadowCamera->setProjection(frame.fovDegrees, 1.0, frame.near,
                                   frame.far, Camera::Fov::VERTICAL);
  _areaShadowCamera->lookAt(frame.eye, frame.target, frame.up);

  // What a surface has to be multiplied by to land on the map. Filament keeps
  // the world shifted to the camera for precision, and this matrix is applied
  // to `getUserWorldPosition` — the unshifted one — so it is built from the
  // camera's own unshifted transform.
  //
  // The *rendering* projection, not the culling one, and then the remap
  // Filament applies in every vertex shader: the camera's matrix is the
  // OpenGL one, z from minus one to one, and the depth buffer holds that
  // turned into nought to one and reversed. Leaving the remap out was why
  // this shadow never showed: the surface compared a number near one against
  // a map near nought, and was lit wherever it stood. Found by drawing, per
  // pixel, whether the map held anything and which convention it agreed with
  // — it held the right depths all along.
  //
  // With the remap in place the Panel shadows example darkens 126k of its
  // 1.92M pixels by a tenth or more when the panel is asked to cast, the
  // umbra under an occluder falling to a fifth of the lit floor beside it
  // (31.0 to 6.2 levels of luminance) while the lit floor itself does not
  // move. Without it, nothing changed but the dither.
  _areaShadowMatrix = orbis::depthFromClip() *
                      filament::math::mat4f(_areaShadowCamera->getProjectionMatrix() *
                                            _areaShadowCamera->getViewMatrix());
  return true;
}

/// The two fitted tables, side by side in one texture.
///
/// One texture rather than two because a material's sampler slots are the
/// scarce thing and a tile is free. Thirty-two bit float rather than half:
/// the matrix entries reach into the tens of thousands at the smooth end of
/// the table, which is past what a half can hold, and a table that silently
/// saturates gives a mirror-smooth surface no highlight at all.
void Renderer::buildLtcTables() {
  if (_lightData != nullptr) return;

  constexpr uint32_t kSide = 64;
  constexpr size_t kTexels = size_t(kSide) * kSide;
  static_assert(sizeof(kLtcMatrix) / sizeof(float) == kTexels * 4,
                "the LTC matrix table is not 64x64 RGBA");
  static_assert(sizeof(kLtcFresnel) / sizeof(float) == kTexels * 4,
                "the LTC Fresnel table is not 64x64 RGBA");

  // Interleaved row by row, because the two tiles share rows in the texture
  // and are contiguous only in the source arrays.
  const size_t floats = kTexels * 4 * 2;
  float *packed = static_cast<float *>(malloc(floats * sizeof(float)));
  for (uint32_t y = 0; y < kSide; y++) {
    const size_t row = size_t(y) * kSide * 4;
    memcpy(packed + y * kSide * 2 * 4, kLtcMatrix + row, kSide * 4 * sizeof(float));
    memcpy(packed + y * kSide * 2 * 4 + kSide * 4, kLtcFresnel + row,
           kSide * 4 * sizeof(float));
  }

  _lightData = Texture::Builder()
                   .width(kSide * 2)
                   .height(kSide + kAreaLightBudget)
                   .levels(1)
                   .format(Texture::InternalFormat::RGBA32F)
                   .sampler(Texture::Sampler::SAMPLER_2D)
                   .usage(Texture::Usage::SAMPLEABLE |
                          Texture::Usage::UPLOADABLE)
                   .build(*_engine);
  // Freed by the callback rather than after this returns: the descriptor
  // keeps the pointer until the driver thread performs the upload, which is
  // later than here.
  _lightData->setImage(
      *_engine, 0, 0, 0, kSide * 2, kSide,
      Texture::PixelBufferDescriptor(
          packed, floats * sizeof(float),
          Texture::PixelBufferDescriptor::PixelDataFormat::RGBA,
          Texture::PixelBufferDescriptor::PixelDataType::FLOAT,
          [](void *buffer, size_t, void *) { free(buffer); }));

  // The rows the rectangles live in, started empty so that a surface binding
  // this before any light exists reads nought rather than whatever the driver
  // last had there.
  const size_t blankFloats = size_t(kAreaLightTexels) * kAreaLightBudget * 4;
  float *blank = static_cast<float *>(calloc(blankFloats, sizeof(float)));
  _lightData->setImage(
      *_engine, 0, 0, kSide, kAreaLightTexels, kAreaLightBudget,
      Texture::PixelBufferDescriptor(
          blank, blankFloats * sizeof(float),
          Texture::PixelBufferDescriptor::PixelDataFormat::RGBA,
          Texture::PixelBufferDescriptor::PixelDataType::FLOAT,
          [](void *buffer, size_t, void *) { free(buffer); }));
}

/// The compiled material one effect runs, built the first time it is asked
/// for. An effect nobody has a material for draws nothing rather than
/// drawing wrongly.
filament::Material *Renderer::materialForEffect(int effect) {
  auto found = _effectMaterials.find(effect);
  if (found != _effectMaterials.end()) return found->second;

  const uint8_t *package = nullptr;
  size_t length = 0;
  switch (effect) {
    case kEffectSharpen:
      package = ksharpenMaterial;
      length = ksharpenMaterial_len;
      break;
    case kEffectSmaaEdges:
      package = ksmaa_edgesMaterial;
      length = ksmaa_edgesMaterial_len;
      break;
    case kEffectSmaaWeights:
      package = ksmaa_weightsMaterial;
      length = ksmaa_weightsMaterial_len;
      break;
    case kEffectCopy:
      package = kcopyMaterial;
      length = kcopyMaterial_len;
      break;
    case kEffectBounce:
      package = kbounceMaterial;
      length = kbounceMaterial_len;
      break;
    case kEffectSmaaBlend:
      package = ksmaa_blendMaterial;
      length = ksmaa_blendMaterial_len;
      break;
    case kEffectMotionBlur:
      // Motion blur hook: the gather is this pass's own material, and its
      // bytes live with the rest of motion blur.
      package = orbis::MotionBlur::gatherPackage();
      length = orbis::MotionBlur::gatherPackageSize();
      break;
    default:
      // Hook (screen effects): god rays and distortion keep their compiled
      // materials in ScreenEffects.cpp.
      if (orbis::screenEffectPackage(effect, &package, &length)) break;
      _effectMaterials[effect] = nullptr;
      return nullptr;
  }

  Material *built = Material::Builder().package(package, length).build(*_engine);
  _effectMaterials[effect] = built;
  return built;
}

/// Builds the one triangle an effect pass draws, and dresses it.
///
/// A triangle rather than a quad, and bigger than the screen rather than
/// exactly it: two triangles meeting across the middle of the frame make the
/// hardware shade the pixels along that seam twice, and one oversized triangle
/// covers everything with no seam to pay for.
///
/// Positions are already in clip space — the material is `vertexDomain :
/// device`, so nothing transforms them — and the UVs are what the fragment
/// reads the source image by.
bool Renderer::buildEffect(GraphPass &pass) {
  if (pass.effectScene != nullptr) return true;

  Material *material = materialForEffect(pass.effect);
  if (material == nullptr) return false;

  static const float kCorners[] = {
      -1.0f, -1.0f, 0.0f, 0.0f,  //
       3.0f, -1.0f, 2.0f, 0.0f,  //
      -1.0f,  3.0f, 0.0f, 2.0f,  //
  };
  static const uint16_t kOrder[] = {0, 1, 2};

  auto *vertices = VertexBuffer::Builder()
                       .vertexCount(3)
                       .bufferCount(1)
                       .attribute(VertexAttribute::POSITION, 0,
                                  VertexBuffer::AttributeType::FLOAT2, 0,
                                  sizeof(float) * 4)
                       .attribute(VertexAttribute::UV0, 0,
                                  VertexBuffer::AttributeType::FLOAT2,
                                  sizeof(float) * 2, sizeof(float) * 4)
                       .build(*_engine);
  // Namespace-scope constants outlive the upload, so no callback is needed —
  // a stack array here would be freed before the driver read it.
  vertices->setBufferAt(*_engine, 0,
                        VertexBuffer::BufferDescriptor(
                            kCorners, sizeof(kCorners), nullptr));

  auto *indices = IndexBuffer::Builder()
                      .indexCount(3)
                      .bufferType(IndexBuffer::IndexType::USHORT)
                      .build(*_engine);
  indices->setBuffer(*_engine, IndexBuffer::BufferDescriptor(
                                   kOrder, sizeof(kOrder), nullptr));

  pass.effectMaterial = material->createInstance();
  pass.effectEntity = utils::EntityManager::get().create();
  RenderableManager::Builder(1)
      // Never culled: it is the screen, so a box that decides otherwise is a
      // box that is wrong.
      .boundingBox({{-1, -1, -1}, {1, 1, 1}})
      .culling(false)
      .material(0, pass.effectMaterial)
      .geometry(0, RenderableManager::PrimitiveType::TRIANGLES, vertices,
                indices, 0, 3)
      .castShadows(false)
      .receiveShadows(false)
      .build(*_engine, pass.effectEntity);

  // Its own scene, holding nothing else. The world's scene would put the
  // whole landscape behind a triangle covering the screen.
  pass.effectScene = _engine->createScene();
  pass.effectScene->addEntity(pass.effectEntity);
  return true;
}

/// Gives a view the display side of the scene's post-processing.
///
/// Only the part that turns finished linear light into a picture: the tone
/// mapper and the grade, which live together in Filament's ColorGrading, plus
/// the dithering that stops a smooth gradient banding once it is eight bits.
///
/// Deliberately not bloom, depth of field or anti-aliasing. Those read the
/// scene's own depth and history, and this view has neither — it is one
/// triangle holding a photograph of the scene. Running them here would be
/// running them on the wrong image; they belong to the pass that drew the
/// world.
void Renderer::applyPostTo(View *view) {
  if (_colorGrading != nullptr) view->setColorGrading(_colorGrading);
  view->setDithering(_view->getDithering());
  view->setAntiAliasing(AntiAliasing::NONE);
}

/// Runs one effect pass: the image it reads, over the target it writes.
void Renderer::runEffect(GraphPass &pass, GraphTarget *into) {
  if (!buildEffect(pass)) return;

  // What it sharpens. A pass that names no readable source has nothing to do,
  // and doing it anyway would sample whatever was in the sampler last.
  GraphTarget *from = nullptr;
  for (int r = 0; r < 4; r++) {
    if (pass.reads[r] < 0) continue;
    GraphTarget &candidate = _targets[pass.reads[r]];
    if (candidate.colour != nullptr) {
      from = &candidate;
      break;
    }
  }
  if (from == nullptr) return;

  const TextureSampler smooth(TextureSampler::MinFilter::LINEAR,
                              TextureSampler::MagFilter::LINEAR);
  // Every effect but the weights one calls its input `source`; that one calls
  // it `edges`, and setting a parameter a material does not declare is a
  // Filament precondition, which ends the process rather than the frame.
  if (pass.effect != kEffectSmaaWeights) {
    pass.effectMaterial->setParameter("source", from->colour, smooth);
  }

  // What each effect needs beyond the image. The first of the plane's four
  // numbers is the effect's one dial — a reflection uses those for its
  // mirror and an effect has no mirror.
  const float dial = pass.plane[0];
  const float wide = float(from->builtWidth);
  const float tall = float(from->builtHeight);
  switch (pass.effect) {
    case kEffectSharpen:
      pass.effectMaterial->setParameter("amount", dial > 0.0f ? dial : 0.6f);
      break;
    case kEffectSmaaEdges:
      pass.effectMaterial->setParameter(
          "step", filament::math::float2{1.0f / wide, 1.0f / tall});
      pass.effectMaterial->setParameter("threshold", dial > 0.0f ? dial : 0.1f);
      break;
    case kEffectSmaaWeights: {
      buildSmaaTables();
      const TextureSampler tables(TextureSampler::MinFilter::LINEAR,
                                  TextureSampler::MagFilter::LINEAR);
      // The edges are what this pass reads; `source` above already bound them.
      pass.effectMaterial->setParameter("edges", from->colour, smooth);
      pass.effectMaterial->setParameter("area", _smaaArea, tables);
      pass.effectMaterial->setParameter("search", _smaaSearch, tables);
      pass.effectMaterial->setParameter(
          "step", filament::math::float2{1.0f / wide, 1.0f / tall});
      pass.effectMaterial->setParameter("reach", dial > 0.0f ? dial : 16.0f);
      break;
    }
    case kEffectSmaaBlend: {
      // Two inputs, and the order is the graph's to state: the picture first,
      // the weights second. A blend given them the other way round mixes the
      // weights together and outputs something that looks like a fault in the
      // renderer rather than a mistake in the graph.
      GraphTarget *weights = nullptr;
      for (int r = 1; r < 4; r++) {
        if (pass.reads[r] < 0) continue;
        if (_targets[pass.reads[r]].colour == nullptr) continue;
        weights = &_targets[pass.reads[r]];
        break;
      }
      if (weights == nullptr) return;
      pass.effectMaterial->setParameter("weights", weights->colour, smooth);
      pass.effectMaterial->setParameter(
          "step", filament::math::float2{1.0f / wide, 1.0f / tall});
      break;
    }
    case kEffectBounce: {
      // Depth as well as colour, from the same target. A graph names that
      // target once and gets both, because asking a host to list the depth
      // of a thing it has already listed is a way of getting the two out of
      // step.
      if (from->depth == nullptr) return;
      // Nearest, and it matters: a linear tap between two depths is a
      // distance at which nothing stands, and the march would find a surface
      // in mid-air at every silhouette.
      const TextureSampler exact(TextureSampler::MinFilter::NEAREST,
                                 TextureSampler::MagFilter::NEAREST,
                                 TextureSampler::WrapMode::CLAMP_TO_EDGE);
      pass.effectMaterial->setParameter("depth", from->depth, exact);
      pass.effectMaterial->setParameter(
          "step", filament::math::float2{1.0f / wide, 1.0f / tall});

      // The scene's camera, not this pass's. An effect draws through a camera
      // of its own — that is what puts a triangle over the whole screen — so
      // the projection that made the depth has to be handed over rather than
      // read from the frame.
      const Camera &scene = _view->getCamera();
      const filament::math::mat4 clipFromView = scene.getProjectionMatrix();
      pass.effectMaterial->setParameter("near", float(scene.getNear()));
      // The half field of view as tangents, which turn a place on the screen
      // and a distance into a position. Read off the projection so an
      // orthographic or an off-centre camera cannot disagree with it.
      pass.effectMaterial->setParameter(
          "tangents",
          filament::math::float2{float(1.0 / clipFromView[0][0]),
                                 float(1.0 / clipFromView[1][1])});

      pass.effectMaterial->setParameter("radius", dial > 0.0f ? dial : 1.5f);
      pass.effectMaterial->setParameter("intensity", pass.plane[1] > 0.0f
                                                         ? pass.plane[1]
                                                         : 1.0f);
      pass.effectMaterial->setParameter(
          "thickness", pass.plane[2] > 0.0f ? pass.plane[2] : 0.35f);
      // Four slices of eight steps is the shape that holds up while staying
      // affordable; the shader's loops are bounded at eight and sixteen.
      const int slices = pass.plane[3] > 0.0f ? int(pass.plane[3]) : 4;
      pass.effectMaterial->setParameter("slices", int32_t(std::clamp(slices, 1, 8)));
      pass.effectMaterial->setParameter("steps", int32_t(8));
      break;
    }
    case orbis::kEffectGodRays:
    case orbis::kEffectDistortion: {
      // Hook (screen effects). The colour is `from`, as for every effect;
      // the depth is the first read that kept one, which is what lets a
      // distortion bend the god rays' output by the world's depth. The
      // scene's camera, not this pass's, for the same reason as the bounce.
      Texture *depth = nullptr;
      for (int r = 0; r < 4 && depth == nullptr; r++) {
        if (pass.reads[r] >= 0) depth = _targets[pass.reads[r]].depth;
      }
      if (depth == nullptr) return;
      if (pass.effect == orbis::kEffectGodRays) {
        _screenEffects.applyGodRays(*pass.effectMaterial, _view->getCamera(),
                                    uint32_t(wide), uint32_t(tall), depth);
      } else {
        _screenEffects.applyDistortion(*pass.effectMaterial,
                                       _view->getCamera(), uint32_t(wide),
                                       uint32_t(tall), depth);
      }
      break;
    }
    case kEffectMotionBlur:
      // Motion blur hook: the velocity, resolve and tile passes run here,
      // and the gather — this pass's own material — is dressed for the draw
      // below, which is what keeps the frame's tone mapping on it.
      if (_motionBlur) {
        _motionBlur->prepare(*_renderer, _view->getCamera(), from->colour,
                             from->depth, from->builtWidth, from->builtHeight,
                             pass.plane, *pass.effectMaterial);
      }
      break;
    default:
      break;
  }

  View *view = viewForPass(pass);
  view->setScene(pass.effectScene);

  // Neutral exposure, and it is not cosmetic. Filament scales what an unlit
  // material writes by the camera's exposure, which is right for a surface
  // being photographed and wrong for a pass whose output is *data*: an edge
  // written as one lands in the target as a thousandth, and the pass that
  // reads it back finds nothing there. It looked correct on screen only
  // because tone mapping was undoing the same scale on the way out.
  pass.camera->setExposure(1.0f);

  if (into != nullptr) {
    view->setRenderTarget(into->target);
    view->setViewport({0, 0, into->builtWidth, into->builtHeight});
    // Another pass will sample this, so it stays linear light. Tone-mapping
    // it here would bake a display curve into something still being worked
    // on, and the next effect in the chain would sharpen a picture of a
    // picture.
    view->setPostProcessingEnabled(false);
  } else {
    // The frame, which is the end of the chain and the only place a display
    // curve belongs. Post is *on* here, and that is what carries tone
    // mapping, grading and the rest across an effect chain — without it a
    // scene that went through one came out cooler and darker than the same
    // scene drawn straight to the screen, because the linear light was never
    // converted for a display.
    view->setRenderTarget(nullptr);
    view->setViewport({0, 0, _width, _height});
    view->setPostProcessingEnabled(true);
    applyPostTo(view);
  }
  _renderer->render(view);
}

View *Renderer::viewForPass(GraphPass &pass) {
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
void Renderer::aimPass(GraphPass &pass, uint32_t wide, uint32_t tall) {
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
void Renderer::releaseTarget(GraphTarget &target) {
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
void Renderer::sweepRetiredTextures() {
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
void Renderer::releaseGraph() {
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
  for (GraphTarget &target : _targets) releaseTarget(target);

  _passes.clear();
  _targets.clear();
}

/// The texture a pass drew, by the name the graph gave it.
Texture *Renderer::targetTextureNamed(const std::string &name) {
  for (GraphTarget &target : _targets) {
    if (target.name == name) return target.colour;
  }
  return nullptr;
}

void Renderer::setPipeline(const float *params, size_t count) {
  static_assert(orbis::pipeline::kPipelineStride <= 32,
                "the pipeline block has outgrown _pipelineParams: widen the "
                "array and the clamp below, or the newest dials are dropped");
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
      orbis::shadowSettingsDiffer(_pipelineParams, _pipelineCount, params, count);
  std::memcpy(_pipelineParams, params, sizeof(float) * count);
  _pipelineCount = count;

  // On or off, which kind, and the dials of the soft and variance kinds.
  orbis::applyViewShadows(*_view, params, count);

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
  if (shadowsChanged) refreshShadowOptions();
}

/// Writes the pipeline's shadow settings onto one light.
void Renderer::shadowOptionsFor(utils::Entity entity) {
  auto &lights = _engine->getLightManager();
  auto instance = lights.getInstance(entity);
  if (!instance) return;
  if (_pipelineCount == 0) return;

  LightManager::ShadowOptions options = lights.getShadowOptions(instance);
  orbis::applyLightShadows(options, _pipelineParams, _pipelineCount);
  lights.setShadowOptions(instance, options);
}

/// Tells every light in the scene about a change to the shadow settings.
void Renderer::refreshShadowOptions() {
  for (auto &entry : _lit) shadowOptionsFor(entry.second.entity);
}

void Renderer::applyVideos(const int64_t *keys, const int32_t *flags,
                           const float *params,
                           const std::vector<std::string> &paths,
                           uint32_t count) {
  if (_disposed) return;

  const uint64_t generation = ++_videoGeneration;
  _movieOrder.clear();
  _movieOrder.reserve(count);
  // Said again by this publish if it is still true, so a scene that stops
  // naming a video stops being told it cannot have it.
  _videoNotes.clear();

  for (uint32_t i = 0; i < count; i++) {
    Movie &movie = _movies[keys[i]];
    movie.seen = generation;
    const float *values = params + i * kVideoParams;
    const std::string path = i < paths.size() ? paths[i] : std::string();

    // A different file is a different video, whatever the key says. Anything
    // else — rate, volume, playing — is a change to this one.
    if (movie.decoder == nullptr || movie.path != path) open(movie, path);
    if (movie.decoder == nullptr) {
      _movieOrder.push_back(&movie);
      continue;
    }

    movie.looping = (flags[i] & 2) != 0;
    movie.decoder->setLooping(movie.looping);

    // The seek is reconciled by its token rather than by its target, so
    // saying the same seek sixty times a second is one seek and not sixty.
    const int32_t token = static_cast<int32_t>(values[3]);
    if (token != movie.seekToken) {
      movie.seekToken = token;
      if (values[2] >= 0) movie.decoder->seek(values[2]);
    }

    if (values[1] != movie.volume) {
      movie.volume = values[1];
      movie.decoder->setVolume(values[1]);
    }

    const bool playing = (flags[i] & 1) != 0;
    if (flags[i] != movie.flags || values[0] != movie.rate) {
      movie.flags = flags[i];
      movie.rate = values[0];
      if (playing) {
        movie.decoder->play(movie.rate);
      } else {
        movie.decoder->pause();
      }
    }

    _movieOrder.push_back(&movie);
  }

  for (auto it = _movies.begin(); it != _movies.end();) {
    if (it->second.seen == generation) {
      ++it;
      continue;
    }
    close(it->second);
    it = _movies.erase(it);
  }
}

/// Takes whatever frame each decoder has ready and puts it on the GPU.
///
/// Called once a frame. A video that has not advanced hands back nothing and
/// costs a single comparison; the picture already on the texture stays.
void Renderer::pumpVideos() {
  if (_movies.empty()) return;
  for (auto &entry : _movies) {
    Movie &movie = entry.second;
    if (movie.decoder == nullptr || movie.texture == nullptr) continue;
    // The decoder puts its newest frame on the texture where it lies, and
    // keeps it until the next one replaces it.
    movie.decoder->pump(*_engine, movie.texture);
  }
}

void Renderer::applyMaterials(const int64_t *keys, const int32_t *flags, const float *params, const int32_t *maps, const std::vector<std::string> &texturePaths, const int32_t *textureSrgb, const int32_t *videos, uint32_t count) {
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
    const int wanted = surfaceIndexFor(flags[i]);
    const bool rebuild =
        surface.instance == nullptr ||
        surfaceIndexFor(surface.flags) != wanted ||
        surface.flags == -1;
    if (rebuild) {
      if (surface.instance != nullptr) {
        _materialsSpent.push_back(surface.instance);
      }
      surface.instance = surfaceAt(wanted)->createInstance();
      if ((flags[i] & 3) == 0) setDefaultsOn(surface.instance);
      surface.written = false;
    }

    if (rebuild || surface.flags != flags[i]) {
      surface.flags = flags[i];
      applyRasterState(surface, values[17], values[18]);
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
      write(surface, values, entries, texturePaths, textureSrgb, videos[i]);
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
void Renderer::dress(Drawn &drawn, int32_t index) {
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
  // colour is written into — or, batched, to the one surface every cube of
  // that exact colour shares.
  MaterialInstance *chosen = instance != nullptr ? instance
                             : drawn.pooled != nullptr ? drawn.pooled
                                                       : drawn.material;
  if (chosen != nullptr) {
    renderableManager.setMaterialInstanceAt(renderable, 0, chosen);
  }
}

void Renderer::applyObjects(const int64_t *keys, const float *transforms, const float *colours, const int32_t *meshes, const int32_t *flags, const int32_t *materials, const int32_t *morphCounts, const float *morphWeights, const std::vector<std::string> &paths, uint32_t count) {
  if (_disposed) return;

  // Where this object's shapes begin in the weights, walked alongside the
  // objects: the sender packs them end to end in the order it names them.
  size_t morphAt = 0;

  const uint64_t generation = ++_objectGeneration;
  auto &transformManager = _engine->getTransformManager();

  // Motion blur hook: a publish begins. Nothing is remembered unless a graph
  // blurs objects by their own motion.
  if (_motionBlur) _motionBlur->beginPublish();
  Notes notes;

  // Every layer each shared material is worn on, so a decal masked to a
  // layer can be tested against it. A shared instance is one set of
  // uniforms for every object wearing it, so the best it can say is all of
  // their layers at once.
  std::unordered_map<MaterialInstance *, int32_t> decalWearers;
  // Who is like whom, counted before anything is built, because whether one
  // object batches depends on how many others share its key.
  //
  // Three kinds of object are counted out rather than in:
  //
  //  * A morphing one. Filament will not merge a renderable with morph
  //    targets, and its weights are its own anyway.
  //  * A hidden one. It is not drawn, so counting it could push a group over
  //    the threshold on the strength of objects that draw nothing.
  //  * A model wearing its own file's materials. gltfio gives every copy its
  //    own material instances, so two copies cannot be merged without being
  //    made to share one copy's instances — which is a change to what the
  //    other copies are made of, not just to how they are drawn. A model that
  //    wears a named Orbis material is a different matter and does batch: it
  //    already shares that material's one instance with everything else made
  //    of it, so there is nothing to arrange and merging just happens.
  _census.clear();
  if (_batching) {
    for (uint32_t i = 0; i < count; i++) {
      const bool ownFileMaterials = meshes[i] >= 0 && materials[i] < 0;
      const bool eligible = morphCounts[i] <= 0 &&
                            (flags[i] & kVisible) != 0 && !ownFileMaterials;
      _census.add(orbis::BatchCensus::keyFor(meshes[i], materials[i],
                                             colours + i * 3, flags[i],
                                             meshes[i] < 0 && materials[i] < 0),
                  eligible);
    }
  }

  for (uint32_t i = 0; i < count; i++) {
    std::string path;
    const int32_t meshIndex = meshes[i];
    if (meshIndex >= 0 && meshIndex < static_cast<int32_t>(paths.size())) {
      path = paths[meshIndex];
    }

    // Default-constructed on first sight, which is how a new object announces
    // itself: there is no separate "added" message, only a key nobody has
    // seen before.
    Drawn &drawn = _drawn[keys[i]];

    // Two objects claiming one identity: the second would take the first's
    // place, and one of them would appear to have been deleted. Keys are the
    // host's to keep unique, and this is where that goes wrong.
    if (drawn.seen == generation) {
      notes["keys"] = "Two objects in this scene are sharing one key, so "
                       "only one of them is drawn.";
      continue;
    }

    // A different file is a different object, so it is built again. Nothing
    // else is: the rest is written into what is already there.
    const bool exists = drawn.entity || drawn.instance != nullptr;
    if (exists && drawn.path != path) {
      recycle(drawn);
      drawn = Drawn{};
    }
    if (!drawn.entity && drawn.instance == nullptr) {
      build(drawn, path);
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

    // Motion blur hook: where this object stands in this publish and what it
    // draws with, so its motion can be measured against the last publish.
    if (_motionBlur && _motionBlur->wanted()) {
      if (drawn.instance != nullptr) {
        _motionBlur->place(keys[i], placement, drawn.instance->getRoot(),
                           drawn.instance->getEntities(),
                           drawn.instance->getEntityCount());
      } else {
        _motionBlur->place(keys[i], placement, drawn.entity, &drawn.entity, 1);
      }
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
      applyFlags(flags[i], drawn);
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

    // Batched: what it would otherwise wear alone, it now shares. An object
    // wearing a named material already shares that material's one instance
    // with everything else made of it, so there is nothing to do for it —
    // it merges once the engine is told to merge.
    MaterialInstance *pooled = nullptr;
    if (_census.batches(i) && wearing < 0 && drawn.material != nullptr) {
      pooled = _colourPool.take(colours + i * 3, generation,
                                [this](const float *colour) {
        MaterialInstance *made = surfaceAt(0)->createInstance();
        setDefaultsOn(made);
        made->setParameter("baseColor",
                           float4{colour[0], colour[1], colour[2], 1.0f});
        return made;
      });
    }
    const bool regrouped = pooled != drawn.pooled;
    drawn.pooled = pooled;

    if (wearing != drawn.surface || remade || regrouped) {
      drawn.surface = wearing;
      dress(drawn, wearing);
    }

    // Which layer decals see this object on. Its own instance says exactly;
    // a shared one is gathered and written once the loop is done.
    const int32_t decalBit = int32_t(layerBitOf(flags[i]));
    if (drawn.material != nullptr && drawn.decalLayer != decalBit) {
      drawn.decalLayer = decalBit;
      drawn.material->setParameter("decalLayer", decalBit);
    }
    if (wearing >= 0 && wearing < static_cast<int32_t>(_materialOrder.size())) {
      decalWearers[_materialOrder[wearing]] |= decalBit;
    }

    // How far each of the mesh's shapes is dialled in. Written every publish
    // rather than compared first: a weight is what animates, so it is the one
    // number here that is expected to differ on every frame, and a memcmp to
    // find that out is work with a known answer.
    const size_t shapes = size_t(std::max(morphCounts[i], 0));
    if (shapes > 0) {
      morph(drawn, morphWeights + morphAt, shapes);
    }
    morphAt += shapes;
  }

  // Only the lit surface paints decals, so only it has the parameter; the
  // unlit and video ones would refuse it. Compared first, because a uniform
  // write dirties the instance's whole block.
  for (const auto &worn : decalWearers) {
    MaterialInstance *instance = worn.first;
    if (!instance->getMaterial()->hasParameter("decalLayer")) continue;
    if (instance->getParameter<int32_t>("decalLayer") == worn.second) continue;
    instance->setParameter("decalLayer", worn.second);
  }

  // Whatever this publish did not mention has left the scene. Sweeping by
  // stamp rather than by a removal message means a host cannot leak an object
  // by forgetting to say it went.
  for (auto it = _drawn.begin(); it != _drawn.end();) {
    if (it->second.seen == generation) {
      ++it;
      continue;
    }
    recycle(it->second);
    it = _drawn.erase(it);
  }

  // Shared surfaces nobody asked for this time. After every object has been
  // re-dressed and every departed one recycled, so nothing still wears them.
  _colourPool.sweep(generation,
                    [this](MaterialInstance *spent) { _engine->destroy(spent); });
  _batchedObjects = _batching ? _census.batchedObjects() : 0;
  _batchGroups = _batching ? _census.batchGroups() : 0;

  // Filament's merging, only over a scene that has actually been made to
  // share something. Both halves of that are needed and neither is enough:
  // Orbis pooling material instances saves a few uniform writes and merges
  // nothing, and this flag without the pooling has nothing alike to merge.
  //
  // The flag is engine-wide, and on Filament 1.76 it is not safe. Raised over
  // some scenes it makes the frame come back *entirely* black — every channel
  // nought across all 1,920,000 pixels of the dump, sky included — while the
  // same scene with it lowered is correct. Measured, with post-processing on:
  //
  //   three thousand crates, one directional light   correct, bit-identical
  //   the same crates, nothing grouped               correct, bit-identical
  //   the thousand objects, nothing grouped          black
  //   Panel shadows, nothing grouped                 black
  //   48 crossing slabs sharing one material         black
  //
  // So it is not "nothing to merge" and it is not "something merged" either;
  // both fail in some scenes and succeed in others, and the one thing every
  // black frame has in common is that Orbis's post-processing ran (the same
  // scenes draw with ORBIS_POST=0). It is inside Filament, there is no public
  // way to ask beforehand which scene is which, and it has not been traced
  // further. Hence: this stays behind an opt-in that defaults to off, the
  // guard keeps a scene with nothing to batch running exactly as it would
  // unbatched, and a scene that opts in has to be looked at.
  //
  // ORBIS_FORCE_INSTANCING=1 raises the flag whenever batching is on, grouped
  // or not, which reproduces the black frame in one run and is how this gets
  // re-checked against a later Filament.
  static const bool forced = getenv("ORBIS_FORCE_INSTANCING") != nullptr;
  const bool merging = _batching && (_batchGroups > 0 || forced);
  if (merging != _engine->isAutomaticInstancingEnabled()) {
    _engine->setAutomaticInstancingEnabled(merging);
  }

  sweepUnnamedMeshes();

  _objectNotes = notes;
  _sceneIsOwnedByHost = true;
}

/// Whether identical objects are merged into instanced draws.
///
/// Two halves, and both are needed. Filament's own automatic instancing
/// merges consecutive draws that use the same geometry and the same material
/// instance, carrying each copy's transform in a per-instance block — and
/// `applyObjects` is what makes identical objects actually share an instance.
/// Either without the other does nothing.
///
/// Engine-wide in Filament; every viewport here has its own engine, so it is
/// this viewport's setting and nobody else's.
void Renderer::setBatching(bool enabled) {
  if (_disposed || _engine == nullptr) return;
  if (enabled == _batching) return;
  _batching = enabled;
  // Switched off at once; switched on only by `applyObjects`, and only once
  // it has found something to merge.
  if (!enabled) _engine->setAutomaticInstancingEnabled(false);
}

uint32_t Renderer::batchedObjects() {
  return _batchedObjects;
}

uint32_t Renderer::batchGroups() {
  return _batchGroups;
}

/// Drops the geometry of any file no object names any more.
///
/// A mesh is read once per path and kept, which is right while something is
/// drawn from it and a leak the moment nothing is. It never showed up on a
/// scene of authored assets, where the set of paths is fixed for the life of
/// the app. It shows up the first time geometry is *generated*: a mesh built
/// at runtime has to arrive under a name the renderer has not seen to be read
/// at all, so a host that rebuilds one chunk of a block world every time
/// somebody digs otherwise leaves every version it ever built on the GPU, and
/// the memory climbs for as long as the game is played.
///
/// Swept after the objects rather than inside `recycle`, because a path
/// leaving one object and arriving at another within the same publish is a
/// rename and not a deletion — destroying it in between would throw away
/// geometry that is about to be drawn again.
void Renderer::sweepUnnamedMeshes() {
  if (_meshes.empty()) return;

  std::set<std::string> named;
  for (const auto &pair : _drawn) {
    if (!pair.second.path.empty()) named.insert(pair.second.path);
  }

  for (auto it = _meshes.begin(); it != _meshes.end();) {
    if (named.count(it->first) != 0) {
      ++it;
      continue;
    }
    // Destroying the asset takes its instances with it, the pooled spares
    // included — which is why nothing may still be holding one, and why this
    // runs only after the object sweep has recycled them all.
    if (it->second.asset != nullptr) {
      _assetLoader->destroyAsset(it->second.asset);
    }
    // The note about why it would not load goes with it. Keeping it would
    // answer for a file nothing is asking about, and the next object to name
    // this path reads the disk again and finds out for itself.
    _assetNotes.erase(it->first);
    it = _meshes.erase(it);
  }
}

/// Writes one light's parameters into Filament.
///
/// Each setter is guarded by the kind that gives it meaning: a falloff radius
/// on a directional light or a cone angle on a point light are not harmless
/// no-ops inside Filament, they are questions it was never asked.
void Renderer::writeLight(const Lit &lit) {
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
  shadowOptionsFor(lit.entity);
}

void Renderer::applyLights(const int64_t *keys, const int32_t *kinds, const int32_t *flags, const float *params, uint32_t count) {
  if (_disposed) return;

  const uint64_t generation = ++_lightGeneration;
  auto &lights = _engine->getLightManager();
  auto &entities = utils::EntityManager::get();

  Notes notes;
  uint32_t directional = 0;
  uint32_t punctual = 0;

  // This frame's rectangles, gathered as they are met and uploaded once at
  // the end. They never become Filament lights, so they take no entity, cast
  // no shadow, and do not count against the punctual budget below.
  buildLtcTables();
  float rectangles[kAreaLightBudget * kAreaLightTexels * 4] = {};
  uint32_t rectangleCount = 0;
  uint32_t rectanglesAsked = 0;
  // Cleared every frame, so the rectangle that casts is decided by this
  // frame's scene rather than by whichever one happened to be first the last
  // time the lights changed.
  _areaShadowCasting = false;

  for (uint32_t i = 0; i < count; i++) {
    const int32_t kind = kinds[i];
    const float *p = params + i * kLightStride;

    if (kind == 3) {
      rectanglesAsked++;
      if (rectangleCount < kAreaLightBudget) {
        // One map, so the first rectangle that asks to cast gets it. The
        // rest are shaded without one rather than refused: a fill light with
        // no shadow is what a fill light looks like anyway, and dropping it
        // would take its light away as well as its shadow.
        bool casting = false;
        if ((flags[i] & 1) != 0) {
          if (!_areaShadowCasting) {
            buildAreaShadow();
            if (aimAreaShadowAt(p)) {
              _areaShadowCasting = true;
              casting = true;
            }
          } else {
            notes["areaShadows"] =
                "Only one rectangular light casts a shadow. The others are "
                "lit without one.";
          }
        }
        packRectangle(p, rectangles + rectangleCount * kAreaLightTexels * 4, casting);
        rectangleCount++;
      }
      continue;
    }

    // Filament shades one directional light per view. A second is dropped
    // rather than blended, and being told is the difference between a scene
    // that looks wrong and a scene that says why.
    if (kind == 0 && ++directional > 1) {
      notes["directional"] =
          "Only one directional light is drawn. The others are ignored.";
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
      writeLight(lit);
    }

    if (flags[i] != lit.flags) {
      lit.flags = flags[i];
      auto instance = lights.getInstance(lit.entity);
      if (instance) lights.setShadowCaster(instance, (flags[i] & 1) != 0);
    }
  }

  if (rectanglesAsked > kAreaLightBudget) {
    notes["area"] = orbis::format("%u rectangular lights is past the %u this view "
                         "shades. The ones past it light nothing.",
                         rectanglesAsked, kAreaLightBudget);
  }
  uploadRectangles(rectangles, rectangleCount);

  if (punctual > kPunctualLightBudget) {
    notes["punctual"] = orbis::format("%u point and spot lights is past the %u this view "
                         "shades. The ones furthest from the camera stop "
                         "lighting anything.",
                         punctual, kPunctualLightBudget);
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

// ---- Decals ----
//
// The arithmetic — sorting, the budget, the matrix into each box — is in
// OrbisDecals.cpp. What is here is handing textures to Filament; turning an
// image file into pixels is the platform layer's orbis::readPicture, which is
// ImageIO on Apple and stb_image everywhere else.

/// The rows the decals live in, built empty.
void Renderer::buildDecalData() {
  if (_decalData != nullptr) return;
  _decalData = Texture::Builder()
                   .width(orbis::kDecalTexels)
                   .height(orbis::kDecalBudget)
                   .levels(1)
                   .format(Texture::InternalFormat::RGBA32F)
                   .sampler(Texture::Sampler::SAMPLER_2D)
                   .usage(Texture::Usage::SAMPLEABLE |
                          Texture::Usage::UPLOADABLE)
                   .build(*_engine);
  // Zeros, so a surface drawn before the first scene reads a count of nought
  // rather than whatever the driver had there.
  const size_t floats =
      size_t(orbis::kDecalTexels) * orbis::kDecalBudget * 4;
  float *blank = static_cast<float *>(calloc(floats, sizeof(float)));
  _decalData->setImage(
      *_engine, 0,
      Texture::PixelBufferDescriptor(
          blank, floats * sizeof(float),
          Texture::PixelBufferDescriptor::PixelDataFormat::RGBA,
          Texture::PixelBufferDescriptor::PixelDataType::FLOAT,
          [](void *buffer, size_t, void *) { free(buffer); }));
  _decalsOnGpu.assign(floats, 0.0f);

  // One white texel in an array of one, for surfaces to bind until a scene
  // names a picture. An array, not the blank 2D texture: the sampler's type
  // is part of the material, and a 2D texture in an array's slot is refused.
  _decalBlankPictures = Texture::Builder()
                            .width(1)
                            .height(1)
                            .depth(1)
                            .levels(1)
                            .sampler(Texture::Sampler::SAMPLER_2D_ARRAY)
                            .format(Texture::InternalFormat::RGBA8)
                            .build(*_engine);
  uint8_t *white = new uint8_t[4]{255, 255, 255, 255};
  _decalBlankPictures->setImage(
      *_engine, 0, 0, 0, 0, 1, 1, 1,
      Texture::PixelBufferDescriptor(
          white, 4, Texture::Format::RGBA, Texture::Type::UBYTE,
          [](void *buffer, size_t, void *) {
            delete[] static_cast<uint8_t *>(buffer);
          }));
}

/// Gives one lit surface the decals to read.
void Renderer::bindDecalsTo(MaterialInstance *instance) {
  buildDecalData();
  // Read with texelFetch, which ignores filtering; nearest says so anyway.
  const TextureSampler exact(TextureSampler::MinFilter::NEAREST,
                             TextureSampler::MagFilter::NEAREST,
                             TextureSampler::WrapMode::CLAMP_TO_EDGE);
  instance->setParameter("decalData", _decalData, exact);

  // Clamped, so the picture's edge texels are not wrapped round to meet the
  // opposite edge where the box ends. Anisotropic, because a floor decal is
  // nearly always seen at a grazing angle.
  TextureSampler smooth(TextureSampler::MinFilter::LINEAR_MIPMAP_LINEAR,
                        TextureSampler::MagFilter::LINEAR,
                        TextureSampler::WrapMode::CLAMP_TO_EDGE);
  smooth.setAnisotropy(8.0f);
  instance->setParameter(
      "decalImages",
      _decalPictures != nullptr ? _decalPictures : _decalBlankPictures,
      smooth);
}

/// Points every lit surface at the decal textures again — once, when the
/// pictures' array replaces the stand-in.
void Renderer::bindDecalsEverywhere() {
  for (auto &entry : _drawn) {
    if (entry.second.material != nullptr) {
      bindDecalsTo(entry.second.material);
    }
  }
  for (auto &entry : _materials) {
    if (entry.second.instance == nullptr) continue;
    if ((entry.second.flags & 3) != 0) continue;
    bindDecalsTo(entry.second.instance);
  }
}

/// The array layer a picture is in, reading it into the next free one the
/// first time it is named. Negative when it could not be read or there was
/// no room, and the reason goes in `notes`.
int32_t Renderer::decalLayerFor(const std::string &path, Notes &notes,
                                bool *uploaded) {
  const std::string &identity = path;
  auto found = _decalPictureLayer.find(identity);
  int32_t layer = found != _decalPictureLayer.end() ? found->second : -3;

  if (layer == -3) {
    if (_decalPictureCount >= kDecalPictureLayers) {
      layer = -2;
    } else {
      std::vector<uint8_t> pixels =
          orbis::readPicture(path, kDecalPictureSide);
      if (pixels.empty()) {
        layer = -1;
      } else {
        if (_decalPictures == nullptr) {
          _decalPictures =
              Texture::Builder()
                  .width(kDecalPictureSide)
                  .height(kDecalPictureSide)
                  .depth(kDecalPictureLayers)
                  .levels(kDecalPictureLevels)
                  .sampler(Texture::Sampler::SAMPLER_2D_ARRAY)
                  // sRGB, so the hardware decodes to linear before it
                  // filters. The pictures are premultiplied in sRGB, which is
                  // exact wherever they are opaque and slightly dark in a
                  // soft edge; drawing them into a linear 8-bit bitmap
                  // instead would band every dark picture.
                  .format(Texture::InternalFormat::SRGB8_A8)
                  .usage(Texture::Usage::SAMPLEABLE |
                         Texture::Usage::UPLOADABLE |
                         Texture::Usage::GEN_MIPMAPPABLE)
                  .build(*_engine);
          bindDecalsEverywhere();
        }
        layer = int32_t(_decalPictureCount++);
        const size_t bytes = pixels.size();
        uint8_t *copy = static_cast<uint8_t *>(malloc(bytes));
        memcpy(copy, pixels.data(), bytes);
        _decalPictures->setImage(
            *_engine, 0, 0, 0, uint32_t(layer), kDecalPictureSide,
            kDecalPictureSide, 1,
            Texture::PixelBufferDescriptor(
                copy, bytes, Texture::Format::RGBA, Texture::Type::UBYTE,
                [](void *buffer, size_t, void *) { free(buffer); }));
        *uploaded = true;
      }
    }
    _decalPictureLayer[identity] = layer;
  }

  if (layer == -1) {
    notes[path] = "This decal's picture could not be read. It is painted "
                  "as its tint alone.";
  } else if (layer == -2) {
    notes["decalPictures"] = orbis::format(
        "More than %u different decal pictures. The ones "
        "past it are painted as their tint alone.",
        kDecalPictureLayers);
  }
  return layer;
}

void Renderer::applyDecals(const float *params, const int32_t *images, const std::vector<std::string> &paths, uint32_t count) {
  if (_disposed) return;
  buildDecalData();

  Notes notes;

  // Pictures first, only for the decals that will be painted: reading a file
  // for one past the budget would spend a layer on something never shown.
  std::vector<int32_t> layers(std::max(count, 1u), -1);
  bool uploaded = false;
  const uint32_t painted = std::min(count, orbis::kDecalBudget);
  for (uint32_t i = 0; i < painted; i++) {
    const int32_t index = images[i];
    if (index < 0 || index >= static_cast<int32_t>(paths.size())) continue;
    layers[i] = decalLayerFor(paths[index], notes, &uploaded);
    if (layers[i] < 0) layers[i] = -1;
  }
  // Once for however many arrived, rather than once each: it rebuilds every
  // layer's chain, and a scene's first frame usually names several at once.
  if (uploaded) _decalPictures->generateMipmaps(*_engine);

  const size_t floats =
      size_t(orbis::kDecalTexels) * orbis::kDecalBudget * 4;
  std::vector<float> wanted(floats);
  const orbis::DecalPacking packing =
      orbis::packDecals(params, layers.data(), count, wanted.data());
  if (packing.asked > packing.packed) {
    notes["decals"] = orbis::format("%u decals is past the %u this view paints. The "
                         "ones listed after that are not painted.",
                         packing.asked, packing.packed);
  }
  _decalNotes = notes;

  // A scene standing still uploads nothing.
  if (wanted == _decalsOnGpu) return;
  _decalsOnGpu = wanted;
  float *copy = static_cast<float *>(malloc(floats * sizeof(float)));
  memcpy(copy, wanted.data(), floats * sizeof(float));
  _decalData->setImage(
      *_engine, 0,
      Texture::PixelBufferDescriptor(
          copy, floats * sizeof(float),
          Texture::PixelBufferDescriptor::PixelDataFormat::RGBA,
          Texture::PixelBufferDescriptor::PixelDataType::FLOAT,
          [](void *buffer, size_t, void *) { free(buffer); }));
}

/// Takes one probe's photograph of the scene and filters it into reflections.
///
/// Six renders through a ninety-degree camera, one per face of a cube, and
/// then a filter that blurs the result by roughness so that a matte surface
/// and a mirror can sample the same texture at different levels. Expensive,
/// and deliberately not on the frame path: this runs when a probe is first
/// seen and when its version changes, and at no other time.
void Renderer::capture(Probe &probe, uint8_t layers) {
  using namespace filament;

  const uint32_t side = std::clamp(probe.resolution, 16u, 1024u);
  // A full chain, because the filter writes every level of it and the
  // roughest levels are what a matte surface reads.
  const uint8_t levels = uint8_t(std::floor(std::log2(float(side)))) + 1;

  if (probe.captured != nullptr) {
    _engine->destroy(probe.captured);
    probe.captured = nullptr;
  }
  probe.captured = Texture::Builder()
                       .width(side)
                       .height(side)
                       .levels(levels)
                       .format(Texture::InternalFormat::RGBA16F)
                       .sampler(Texture::Sampler::SAMPLER_CUBEMAP)
                       // Mipmappable as well: the filter builds the chain
                       // down from the captured faces before it convolves
                       // them, and refuses a texture it cannot do that to.
                       .usage(Texture::Usage::COLOR_ATTACHMENT |
                              Texture::Usage::SAMPLEABLE |
                              Texture::Usage::GEN_MIPMAPPABLE)
                       .build(*_engine);
  if (probe.captured == nullptr) return;

  // Its own view and camera, kept off the scene's: pointing the scene's
  // camera six ways and putting it back is the kind of thing that works until
  // something reads it in between. Built once and reused.
  if (_captureView == nullptr) {
    _captureView = _engine->createView();
    _captureCamera =
        _engine->createCamera(utils::EntityManager::get().create());
  }
  View *view = _captureView;
  Camera *camera = _captureCamera;
  view->setScene(_scene);
  view->setCamera(camera);
  view->setViewport({0, 0, side, side});
  view->setVisibleLayers(0xFF, layers);
  // No post-processing on a capture. Tone mapping turns light into pixels,
  // and what a reflection has to hold is light — mapped once here and again
  // when the frame it ends up in is drawn would darken every reflection in
  // the scene.
  view->setPostProcessingEnabled(false);
  camera->setProjection(90.0, 1.0, 0.05, 1000.0, Camera::Fov::VERTICAL);
  camera->setExposure(1.0f);

  // The six directions, in the order Filament's cubemap faces run, with the
  // up vector each one needs to sit the right way round against its
  // neighbours.
  const struct {
    Texture::CubemapFace face;
    math::float3 forward;
    math::float3 up;
  } faces[6] = {
      {Texture::CubemapFace::POSITIVE_X, {1, 0, 0}, {0, -1, 0}},
      {Texture::CubemapFace::NEGATIVE_X, {-1, 0, 0}, {0, -1, 0}},
      {Texture::CubemapFace::POSITIVE_Y, {0, 1, 0}, {0, 0, 1}},
      {Texture::CubemapFace::NEGATIVE_Y, {0, -1, 0}, {0, 0, -1}},
      {Texture::CubemapFace::POSITIVE_Z, {0, 0, 1}, {0, -1, 0}},
      {Texture::CubemapFace::NEGATIVE_Z, {0, 0, -1}, {0, -1, 0}},
  };

  if (probe.depth != nullptr) {
    _engine->destroy(probe.depth);
    probe.depth = nullptr;
  }
  probe.depth = Texture::Builder()
                    .width(side)
                    .height(side)
                    .levels(1)
                    .format(Texture::InternalFormat::DEPTH32F)
                    .usage(Texture::Usage::DEPTH_ATTACHMENT)
                    .build(*_engine);

  // The textures have to exist on the driver before anything is drawn into
  // them: Filament records rather than performs, and a target built in the
  // same frame as the render is built after it.
  _engine->flushAndWait();

  for (int i = 0; i < 6; i++) {
    if (probe.faces[i] != nullptr) _engine->destroy(probe.faces[i]);
    probe.faces[i] = RenderTarget::Builder()
                         .texture(RenderTarget::AttachmentPoint::COLOR,
                                  probe.captured)
                         .face(RenderTarget::AttachmentPoint::COLOR,
                               faces[i].face)
                         .texture(RenderTarget::AttachmentPoint::DEPTH,
                                  probe.depth)
                         .build(*_engine);
    if (probe.faces[i] == nullptr) continue;
    camera->lookAt(probe.position, probe.position + faces[i].forward,
                   faces[i].up);
    view->setRenderTarget(probe.faces[i]);
    _engine->flushAndWait();
    _renderer->render(view);
  }

  // The filter reads the cube, so the faces have to be on it before it runs.
  // Filament records rather than performs, and the recorded draws above have
  // not happened yet.
  _engine->flushAndWait();

  // Built once and kept: the filter compiles its own materials and holds a
  // kernel texture, so one per renderer rather than one per capture.
  if (_prefilter == nullptr) {
    _prefilter = new IBLPrefilterContext(*_engine);
    _specularFilter = new IBLPrefilterContext::SpecularFilter(*_prefilter);
  }
  if (probe.filtered != nullptr) {
    _engine->destroy(probe.filtered);
    probe.filtered = nullptr;
  }
  // The blurred chain a rough surface samples, convolved from the sharp
  // capture. This is the whole reason a probe can be taken while the scene
  // runs rather than baked by a tool beforehand.
  probe.filtered = (*_specularFilter)(probe.captured);

  if (probe.light != nullptr) {
    _engine->destroy(probe.light);
    probe.light = nullptr;
  }
  if (probe.filtered != nullptr) {
    // Reflections only. Filament works the diffuse out of the roughest level
    // of the same chain, so a captured probe lights matte surfaces without
    // anybody baking harmonics for it — which is the difference between a
    // probe a scene can take of itself and one a tool has to prepare.
    // Intensity one, and that is not an oversight. A baked environment is
    // stored relative to some reference and `intensity` is what turns it into
    // lux — thirty thousand for a sunny day. A probe is not stored relative
    // to anything: it is the scene's own light, rendered with the exposure
    // held at one, so it arrives already in the units the rest of the frame
    // is in. Scaling it again is the same light counted twice.
    probe.light = IndirectLight::Builder()
                      .reflections(probe.filtered)
                      .intensity(probe.intensity)
                      .build(*_engine);
  }
}

void Renderer::applyProbes(const int64_t *keys, const float *params, uint32_t count) {
  if (_disposed) return;

  const uint64_t generation = ++_lightGeneration;
  for (uint32_t i = 0; i < count; i++) {
    const float *p = params + i * kProbeStride;
    Probe &probe = _probes[keys[i]];
    probe.seen = generation;
    probe.position = {p[0], p[1], p[2]};
    probe.radius = p[3];

    const uint32_t resolution = uint32_t(std::max(p[4], 16.0f));
    const int32_t version = int32_t(p[5]);
    const uint8_t layers = uint8_t(int32_t(p[6]) & 0xFF);
    probe.intensity = p[7];
    if (probe.captured_at != version || probe.resolution != resolution) {
      probe.resolution = resolution;
      probe.capture_layers = layers;
      probe.wants_capture = true;
      probe.captured_at = version;
    }
  }

  for (auto it = _probes.begin(); it != _probes.end();) {
    if (it->second.seen == generation) {
      ++it;
      continue;
    }
    releaseProbe(it->second);
    it = _probes.erase(it);
  }
}

void Renderer::releaseProbe(Probe &probe) {
  for (int i = 0; i < 6; i++) {
    if (probe.faces[i] != nullptr) _engine->destroy(probe.faces[i]);
  }
  if (probe.depth != nullptr) _engine->destroy(probe.depth);
  if (probe.light != nullptr) _engine->destroy(probe.light);
  if (probe.filtered != nullptr) _engine->destroy(probe.filtered);
  if (probe.captured != nullptr) _engine->destroy(probe.captured);
  probe = Probe{};
}

/// Takes the photographs any probe is still owed.
///
/// The scene's own indirect light is put back to what it would be without any
/// probe for the duration, so that what a probe captures does not depend on
/// which probe happened to be lighting the room when it was taken. Without
/// that a re-capture photographs the room lit by the previous capture, and
/// each one is a little brighter than the last.
void Renderer::captureOwedProbes() {
  bool any = false;

  for (auto &entry : _probes) any = any || entry.second.wants_capture;
  if (!any) return;

  IndirectLight *restore = _activeProbe != 0 && _probes.count(_activeProbe)
                               ? _probes[_activeProbe].light
                               : nullptr;
  IndirectLight *base =
      _environmentLight != nullptr ? _environmentLight : _ambient;
  if (restore != nullptr) _scene->setIndirectLight(base);

  for (auto &entry : _probes) {
    if (!entry.second.wants_capture) continue;
    capture(entry.second, entry.second.capture_layers);
    entry.second.wants_capture = false;
  }

  if (restore != nullptr) _scene->setIndirectLight(restore);
}

/// Puts the probe the camera is standing in charge of lighting the scene.
///
/// Called every frame because the camera moves every frame; it costs a walk
/// over a handful of probes and sets nothing unless the answer changed.
void Renderer::chooseProbe() {
  if (_probes.empty()) {
    if (_activeProbe != 0) {
      _activeProbe = 0;
      // Back to whatever the scene had before a probe took over.
      _scene->setIndirectLight(_environmentLight != nullptr ? _environmentLight
                                                            : _ambient);
    }
    return;
  }

  const filament::math::float3 eye =
      filament::math::float3(_view->getCamera().getPosition());
  int64_t wanted = 0;
  float best = 0.0f;
  for (const auto &entry : _probes) {
    const Probe &probe = entry.second;
    if (probe.light == nullptr || probe.radius <= 0.0f) continue;
    const filament::math::float3 away = probe.position - eye;
    const float distance = std::sqrt(dot(away, away));
    if (distance > probe.radius) continue;
    // Nearest middle wins where two overlap, so a doorway joins wherever
    // their centres say rather than wherever the loop happened to look first.
    const float closeness = 1.0f - distance / probe.radius;
    if (wanted == 0 || closeness > best) {
      wanted = entry.first;
      best = closeness;
    }
  }

  if (wanted == _activeProbe) return;
  _activeProbe = wanted;
  if (wanted == 0) {
    _scene->setIndirectLight(_environmentLight != nullptr ? _environmentLight
                                                          : _ambient);
    return;
  }
  _scene->setIndirectLight(_probes[wanted].light);
}

/// Takes the field's numbers, and builds its atlases when their size changes.
void Renderer::applyField(const float *params, const std::string &from) {
  if (_disposed || params == nullptr) return;
  memcpy(_fieldParams, params, sizeof(_fieldParams));
  _fieldFrom = from;

  const uint32_t wanted = std::min(
      uint32_t(std::max(0.0f, params[7])) * uint32_t(std::max(0.0f, params[8])) *
          uint32_t(std::max(0.0f, params[9])),
      kFieldMaxProbes);
  if (wanted == _fieldProbes) return;

  releaseField();
  _fieldProbes = wanted;
  if (wanted == 0) return;

  const uint32_t rows = (wanted + kFieldTilesPerRow - 1) / kFieldTilesPerRow;
  const uint32_t wide = kFieldTilesPerRow * kFieldTile;
  const uint32_t tall = rows * kFieldTile;

  for (int i = 0; i < 2; i++) {
    _fieldAtlas[i] = Texture::Builder()
                         .width(wide)
                         .height(tall)
                         .levels(1)
                         .format(Texture::InternalFormat::RGBA16F)
                         // Uploadable as well, only so it can be cleared
                         // once at the start. Filament refuses setImage on a
                         // texture without it.
                         .usage(Texture::Usage::COLOR_ATTACHMENT |
                                Texture::Usage::SAMPLEABLE |
                                Texture::Usage::UPLOADABLE)
                         .build(*_engine);
    _fieldTargets[i] = RenderTarget::Builder()
                           .texture(RenderTarget::AttachmentPoint::COLOR,
                                    _fieldAtlas[i])
                           .build(*_engine);
    // Cleared, because a texture Filament allocates holds whatever the
    // driver last had there. A surface reads this before the first pass has
    // written it, and what it found was a constant that looked like light —
    // this room came back green, a colour nowhere in it.
    const size_t floats = size_t(wide) * tall * 4;
    float *blank = static_cast<float *>(calloc(floats, sizeof(float)));
    _fieldAtlas[i]->setImage(
        *_engine, 0, 0, 0, wide, tall,
        Texture::PixelBufferDescriptor(
            blank, floats * sizeof(float),
            Texture::PixelBufferDescriptor::PixelDataFormat::RGBA,
            Texture::PixelBufferDescriptor::PixelDataType::FLOAT,
            [](void *buffer, size_t, void *) { free(buffer); }));
  }
  _fieldFront = 0;
  // Nothing to blend against on the first frame, so the first pass takes
  // what it finds rather than mixing it with an atlas that has never been
  // written. Otherwise a field fades in from whatever the allocation held.
  _fieldHasHistory = false;
}

/// Builds the triangle the field is drawn with, once.
bool Renderer::buildField() {
  if (_fieldScene != nullptr) return true;

  _fieldMaterial = Material::Builder()
                       .package(kirradianceMaterial, kirradianceMaterial_len)
                       .build(*_engine);
  if (_fieldMaterial == nullptr) return false;

  static const float kCorners[] = {
      -1.0f, -1.0f, 0.0f, 0.0f,  //
       3.0f, -1.0f, 2.0f, 0.0f,  //
      -1.0f,  3.0f, 0.0f, 2.0f,  //
  };
  static const uint16_t kOrder[] = {0, 1, 2};

  auto *vertices = VertexBuffer::Builder()
                       .vertexCount(3)
                       .bufferCount(1)
                       .attribute(VertexAttribute::POSITION, 0,
                                  VertexBuffer::AttributeType::FLOAT2, 0,
                                  sizeof(float) * 4)
                       .attribute(VertexAttribute::UV0, 0,
                                  VertexBuffer::AttributeType::FLOAT2,
                                  sizeof(float) * 2, sizeof(float) * 4)
                       .build(*_engine);
  vertices->setBufferAt(*_engine, 0,
                        VertexBuffer::BufferDescriptor(
                            kCorners, sizeof(kCorners), nullptr));
  auto *indices = IndexBuffer::Builder()
                      .indexCount(3)
                      .bufferType(IndexBuffer::IndexType::USHORT)
                      .build(*_engine);
  indices->setBuffer(*_engine, IndexBuffer::BufferDescriptor(
                                   kOrder, sizeof(kOrder), nullptr));

  _fieldInstance = _fieldMaterial->createInstance();
  _fieldEntity = utils::EntityManager::get().create();
  RenderableManager::Builder(1)
      .boundingBox({{-1, -1, -1}, {1, 1, 1}})
      .culling(false)
      .material(0, _fieldInstance)
      .geometry(0, RenderableManager::PrimitiveType::TRIANGLES, vertices,
                indices, 0, 3)
      .castShadows(false)
      .receiveShadows(false)
      .build(*_engine, _fieldEntity);

  _fieldScene = _engine->createScene();
  _fieldScene->addEntity(_fieldEntity);
  _fieldView = _engine->createView();
  _fieldView->setScene(_fieldScene);
  _fieldCamera = _engine->createCamera(utils::EntityManager::get().create());
  _fieldView->setCamera(_fieldCamera);
  _fieldView->setPostProcessingEnabled(false);
  return true;
}

/// Adds this frame's light to the field.
///
/// Runs after the scene has been drawn, because what it reads is the picture
/// the scene just made. The atlas it writes is therefore one frame behind the
/// surfaces that sample it, which is what every temporal method trades and is
/// invisible at anything above a few frames a second.
void Renderer::runField() {
  if (_fieldProbes == 0 || _fieldParams[0] <= 0.0f) return;
  if (!buildField()) return;

  // The picture to read. A field that names a target which does not exist
  // stays dark rather than sampling whatever was bound last.
  GraphTarget *source = nullptr;
  for (auto &target : _targets) {
    if (target.name == _fieldFrom && target.colour != nullptr &&
        target.depth != nullptr) {
      source = &target;
      break;
    }
  }
  if (source == nullptr) {
    // Said rather than left dark. A field whose target does not exist looks
    // exactly like a field that is not working, and the difference is a name
    // in a graph.
    _assetNotes["field"] = orbis::format("The irradiance field fills itself from a target "
                         "called \"%s\", which this graph has no colour and "
                         "depth for. No light is reaching it.",
                         _fieldFrom.c_str());
    return;
  }
  _assetNotes.erase("field");

  const int back = 1 - _fieldFront;
  const TextureSampler smooth(TextureSampler::MinFilter::LINEAR,
                              TextureSampler::MagFilter::LINEAR,
                              TextureSampler::WrapMode::CLAMP_TO_EDGE);
  const TextureSampler exact(TextureSampler::MinFilter::NEAREST,
                             TextureSampler::MagFilter::NEAREST,
                             TextureSampler::WrapMode::CLAMP_TO_EDGE);

  _fieldInstance->setParameter("source", source->colour, smooth);
  _fieldInstance->setParameter("depth", source->depth, exact);
  _fieldInstance->setParameter("history", _fieldAtlas[_fieldFront], exact);
  _fieldInstance->setParameter(
      "origin", float3{_fieldParams[1], _fieldParams[2], _fieldParams[3]});
  _fieldInstance->setParameter(
      "spacing", float3{_fieldParams[4], _fieldParams[5], _fieldParams[6]});
  _fieldInstance->setParameter(
      "counts", float3{_fieldParams[7], _fieldParams[8], _fieldParams[9]});
  _fieldInstance->setParameter("tilesPerRow", float(kFieldTilesPerRow));

  const uint32_t rows =
      (_fieldProbes + kFieldTilesPerRow - 1) / kFieldTilesPerRow;
  const float wide = float(kFieldTilesPerRow * kFieldTile);
  const float tall = float(rows * kFieldTile);
  _fieldInstance->setParameter("atlasSize", float2{wide, tall});

  const Camera &scene = _view->getCamera();
  _fieldInstance->setParameter(
      "clipFromWorld",
      mat4f(scene.getProjectionMatrix() * scene.getViewMatrix()));
  _fieldInstance->setParameter("near", float(scene.getNear()));
  const math::mat4 projection = scene.getProjectionMatrix();
  _fieldInstance->setParameter("tangents",
                               float2{float(1.0 / projection[0][0]),
                                      float(1.0 / projection[1][1])});
  _fieldInstance->setParameter("eye", float3(scene.getPosition()));
  _fieldInstance->setParameter("retention", _fieldParams[11]);
  _fieldInstance->setParameter("damping", kFieldDamping);
  _fieldInstance->setParameter("hasHistory", _fieldHasHistory ? 1.0f : 0.0f);

  _fieldCamera->setExposure(1.0f);
  _fieldView->setRenderTarget(_fieldTargets[back]);
  _fieldView->setViewport({0, 0, uint32_t(wide), uint32_t(tall)});
  _renderer->render(_fieldView);

  _fieldFront = back;
  _fieldHasHistory = true;
}

void Renderer::releaseField() {
  for (int i = 0; i < 2; i++) {
    if (_fieldTargets[i] != nullptr) {
      _engine->destroy(_fieldTargets[i]);
      _fieldTargets[i] = nullptr;
    }
    if (_fieldAtlas[i] != nullptr) {
      _engine->destroy(_fieldAtlas[i]);
      _fieldAtlas[i] = nullptr;
    }
  }
  _fieldProbes = 0;
  _fieldHasHistory = false;
}

void Renderer::setPostProcess(const float *params, size_t count) {
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

  size_t at = 0;
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
  const size_t gradingFrom = at - 8 - 9;
  const bool gradingMoved =
      _colorGrading == nullptr ||
      memcmp(params + gradingFrom, _gradingParams,
             (8 + 9) * sizeof(float)) != 0;
  if (gradingMoved) {
    memcpy(_gradingParams, params + gradingFrom, (8 + 9) * sizeof(float));
  }

  if (gradingMoved)
    applyGrading(grading, toneMapping, exposure, contrast, saturation, vibrance, temperature, tint, shadows, midtones, highlights);

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
void Renderer::applyGrading(bool enabled, int toneMapper, float exposure, float contrast, float saturation, float vibrance, float temperature, float tint, const float *shadows, const float *midtones, const float *highlights) {
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

void Renderer::setFogEnabled(bool enabled, const float *params) {
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
    buildMist();

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

void Renderer::setSkyColour(const float *colour, float ambient, bool showBody) {
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
    setAmbientColour(sky, ambient);
  } else if (ambient != _skyAmbient && _ambient) {
    _ambient->setIntensity(ambient);
  }

  _skyColour = sky;
  _skyAmbient = ambient;
  _skyBuilt = true;
}

void Renderer::setCameraPosition(const float *position, const float *target, float fieldOfView, bool orthographic, float viewHeight, double at) {
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
  aimed.arrived = orbis::now();
  aimed.valid = true;

  _aimLock.lock();
  _aimedWas = _aimedNow;
  _aimedNow = aimed;
  _aimLock.unlock();

  // Motion blur hook: the moment this publish describes, on the host's own
  // clock. It commits the objects the publish placed, and is what turns
  // their two positions into a speed.
  if (_motionBlur) _motionBlur->stamp(at);

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
void Renderer::placeCamera() {
  _aimLock.lock();
  const Aimed now = _aimedNow;
  const Aimed was = _aimedWas;
  _aimLock.unlock();

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
    projectWith(now.fieldOfView, now.orthographic, now.viewHeight);
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

  const double appNow = orbis::now() + _clockOffset;

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
  const double drawnAt = orbis::now();
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
  projectWith(fieldOfView, now.orthographic, now.viewHeight);
}

/// Sets how the camera turns the world into a picture.
///
/// The two kinds do not blend into one another — halfway between a flat view
/// and one with perspective is not a view of anything — so a camera that
/// changes kind changes it outright, and only the numbers move.
void Renderer::projectWith(float fieldOfView, bool orthographic, float tall) {
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

void Renderer::setExposure(float aperture, float shutter, float sensitivity) {
  if (_disposed) return;
  // Filament asks for these in the units a photographer would state them in,
  // which is also how they arrive, so there is nothing to convert.
  _camera->setExposure(aperture, shutter, sensitivity);
}

void Renderer::allocateBuffers() {
  _surface->allocate(_engine, _width, _height, _swapChains, kOrbisBufferCount);
  _backIndex = 0;
  _presentedIndex = -1;
}

void Renderer::releaseBuffers() {
  _surface->release(_engine, _swapChains, kOrbisBufferCount);
}

void Renderer::applyViewportSize() {
  _view->setViewport({0, 0, _width, _height});
  projectWith(_fieldOfView, _orthographic, _viewHeight);
}

void Renderer::resizeToWidth(uint32_t width, uint32_t height) {
  _presentLock.lock();
  _pendingWidth = std::max(width, 1u);
  _pendingHeight = std::max(height, 1u);
  _presentLock.unlock();
}

void Renderer::setOutlineKeys(const int64_t *keys, uint32_t count, const float *params) {
  if (_disposed) return;
  _outlineKeys.assign(keys, keys + count);
  _outlineStyle = orbis::OutlineStyle::from(params);
  const float primary = std::isfinite(params[12]) ? params[12] : 0.0f;
  _outlinePrimaryCount =
      std::min(count, static_cast<uint32_t>(std::max(0.0f, primary)));
}

/// Draws the selection outline over the finished frame.
///
/// After every pass, whatever the graph was, because the outline belongs on
/// the picture as it will be seen: after tone mapping, so its colour is the
/// colour asked for, and after anti-aliasing, so it never enters a history
/// and never crawls. Nothing at all happens while nothing is highlighted.
void Renderer::drawOutline() {
  if (_outlineKeys.empty()) {
    if (_outline) _outline->setEntities({}, {});
    return;
  }

  std::vector<utils::Entity> primary;
  std::vector<utils::Entity> others;
  for (size_t i = 0; i < _outlineKeys.size(); i++) {
    auto found = _drawn.find(_outlineKeys[i]);
    if (found == _drawn.end()) continue;
    const Drawn &drawn = found->second;
    std::vector<utils::Entity> &into = i < _outlinePrimaryCount ? primary : others;
    // Every entity of a model, not only its root: the root of a glTF is a
    // transform and the geometry hangs below it.
    if (drawn.instance != nullptr) {
      const utils::Entity *entities = drawn.instance->getEntities();
      into.insert(into.end(), entities,
                  entities + drawn.instance->getEntityCount());
    } else if (drawn.entity) {
      into.push_back(drawn.entity);
    }
  }

  if (!_outline) _outline = std::make_unique<orbis::Outline>(*_engine);
  _outline->setStyle(_outlineStyle);
  _outline->setEntities(primary, others);
  _outline->render(*_renderer, *_scene, *_camera, _width, _height,
                   kAllLayers);
}

/// Draws every pass of the frame, in the order the graph put them in.
///
/// A graph nobody set is one pass, every layer, into the picture — which is
/// the frame this drew before there were passes at all, and is why a host
/// that has never heard of a graph pays nothing for one.
void Renderer::renderPasses() {
  if (_passes.empty()) {
    _view->setVisibleLayers(0xFF, kAllLayers);
    _renderer->render(_view);
    return;
  }

  prepareTargets();

  for (GraphPass &pass : _passes) {
    const double began = orbis::now();

    if (pass.kind == kPassEffect) {
      runEffect(pass, pass.into < 0 ? nullptr : &_targets[pass.into]);
    } else if (pass.into < 0) {
      _view->setVisibleLayers(0xFF, pass.layers);
      _renderer->render(_view);
    } else {
      GraphTarget &into = _targets[pass.into];
      // A target that could not be built is a pass that does not run. The
      // frame still draws, which is the difference between one broken
      // reflection and a black window.
      if (into.target != nullptr) {
        View *view = viewForPass(pass);
        view->setScene(_scene);
        view->setRenderTarget(into.target);
        view->setViewport({0, 0, into.builtWidth, into.builtHeight});
        view->setVisibleLayers(0xFF, pass.layers);
        aimPass(pass, into.builtWidth, into.builtHeight);
        _renderer->render(view);
      }
    }

    pass.milliseconds = (orbis::now() - began) * 1000.0;
  }
}

/// What each pass of the last frame cost, and how much it drew.
///
/// Read off the frame that has already happened rather than measured on
/// demand: asking a renderer to time itself when somebody looks changes what
/// is being timed.
std::vector<PassTiming> Renderer::passTimings() {
  std::vector<PassTiming> out;
  out.reserve(_passes.size());
  for (const GraphPass &pass : _passes) {
    out.push_back({pass.milliseconds, pass.drawn});
  }
  return out;
}

void Renderer::renderAtTime(double time) {
  if (_disposed) return;

  // Textures still arriving. Filament decodes them off this thread and hands
  // them over here, so this has to be called until it says it is done —
  // stopping early leaves an asset permanently half-textured.
  if (_loadingResources) {
    _resourceLoader->asyncUpdateLoad();
    if (_resourceLoader->asyncGetLoadProgress() >= 1.0f) {
      _loadingResources = false;
      if (_loadingFrom > 0) {
        orbis::log("[orbis] %s: %zu files decoded in %.0f ms",
              orbis::lastPathComponent(_loadingName).c_str(), _loadingResourceCount,
              (orbis::now() - _loadingFrom) * 1000);
        _loadingFrom = 0;
      }
    }
  }

  try {
    drawAtTime(time);
  } catch (const std::exception &error) {
    orbis::log("[orbis] render failed, stopping this viewport: %s", error.what());
    _disposed = true;
  } catch (...) {
    orbis::log("[orbis] render failed for an unknown reason.");
    _disposed = true;
  }
}

void Renderer::drawAtTime(double time) {


  // Resizing reallocates swap chains, which only the engine's own thread may
  // do, so a request from the UI thread is applied here instead of there.
  _presentLock.lock();
  bool needsResize = (_pendingWidth != _width || _pendingHeight != _height);
  uint32_t newWidth = _pendingWidth;
  uint32_t newHeight = _pendingHeight;
  _presentLock.unlock();

  if (needsResize) {
    _presentLock.lock();
    _presentedIndex = -1;  // nothing valid at the new size yet
    _presentLock.unlock();
    releaseBuffers();
    _width = newWidth;
    _height = newHeight;
    allocateBuffers();
    applyViewportSize();
  }

  placeCamera();
  // Motion blur hook: the camera this frame is drawn from, remembered
  // against the last frame's.
  if (_motionBlur) _motionBlur->frameBegan(*_camera);
  rangePopulations();
  // After the camera is placed, because the order depends on which way it
  // faces. The sort itself is on the sorter's own thread; this only asks for
  // one and uploads whichever has finished.
  if (_splats != nullptr) {
    const auto forward = _camera->getForwardVector();
    _splats->update(float3{float(forward.x), float(forward.y), float(forward.z)});
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

  updateCloudsAtTime(time);
  updateMistAtTime(time);
  updateRainAtTime(time);
  pollTextures();
  pumpVideos();

  if (!_renderer->beginFrame(target)) return;
  // Inside the frame, and it has to be: a render outside begin/endFrame is
  // dropped without a word, which looks exactly like a capture that came back
  // black. Owed photographs first, then which probe the camera is standing
  // in, then the frame itself.
  captureOwedProbes();
  chooseProbe();
  // The surfaces read the atlas built up to last frame, so they are pointed
  // at it before anything is drawn.
  bindFieldEverywhere();
  // Before the scene, because the surfaces the scene draws read this. A map
  // rendered afterwards would be a frame behind, which for a light that moves
  // is a shadow that lags the thing casting it.
  renderAreaShadow();
  renderPasses();
  // After the scene, because what the field reads is the picture the scene
  // just made. The atlas it writes is therefore what next frame's surfaces
  // sample — one frame behind, which is what every temporal method trades.
  runField();
  // Last of all, over whatever the graph put on the screen.
  drawOutline();
  // Read back for a host that asked to see the frame. Inside the frame, and
  // it has to be: Filament reads a swap chain between the passes and
  // endFrame, and nowhere else.
  readBackIfAsked();
  _renderer->endFrame();

  // Flutter may sample the moment this returns, so the frame has to be on the
  // surface before it is advertised as presented.
  _engine->flushAndWait();

  // A frame read back arrives through Filament's callback queue, which is
  // only drained when somebody asks. Asking here makes it ready with the
  // frame rather than a frame later.
  bool pumping = false;
  {
    std::lock_guard<std::mutex> lock(_captureLock);
    pumping = _captureInFlight;
  }
  if (pumping) _engine->pumpMessageQueues();

  _presentLock.lock();
  _presentedIndex = _backIndex;
  _backIndex = (_backIndex + 1) % kOrbisBufferCount;
  _presentLock.unlock();

  // Debug aid: dumps exactly the buffer Flutter samples, which separates a
  // rendering fault from a handoff fault. Enabled by an environment variable
  // so it costs nothing when unset.
  if (_frameCount == 0) _startedAt = orbis::now();

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

    const double now = orbis::now();
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
      orbis::log("[orbis] gpu %.2f ms (%.0f/s if unbound); %.1f drawn/s, "
            "%.1f camera/s; drawn unevenness %.0f%%, "
            "told unevenness %.0f%%, prediction saturated %.0f%% of frames",
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
    // The steady-state cost of a frame, not the average since launch.
    //
    // This line used to divide the whole elapsed time by a hard-coded sixty,
    // which was wrong twice: it reported half the true cost whenever the dump
    // was asked for at frame thirty — which is what CI asks for — and even
    // with the right divisor it averaged in engine startup, the first frame's
    // shader compilation and the buffer allocation. An average polluted by
    // one-off costs cannot show a small regression, which is the only thing
    // anybody would use it for.
    //
    // What batching did rides on the same line rather than on one of its own,
    // because CI reads the first two "[orbis] frame" lines — this one and the
    // surface's "-> path" — and a third line in between would push the path
    // out of the log it prints. Renderables are what Filament culls and sorts
    // one at a time; the groups are what the batched objects are left costing
    // per pass if every group merges whole. Filament merges only draws that
    // land next to each other once it has sorted them, so the true count sits
    // between the groups and the objects: this is the ceiling on the saving,
    // not a measurement of it.
    orbis::log("[orbis] frame %d: cpu %.2f ms, gpu %.2f ms (median of recent), "
          "batching %s, %zu renderables, %u objects in %u groups",
          _frameCount, cpuMilliseconds(), gpuMilliseconds(),
          _batching ? "on" : "off", _scene->getRenderableCount(),
          _batchedObjects, _batchGroups);
    _surface->writeFrame(_presentedIndex);
  }
}

void *Renderer::copyPresentedBuffer() {
  std::lock_guard<std::mutex> lock(_presentLock);
  // Opaque on the way out of the surface, and concrete only in the host that
  // asked for it: on Apple the plugin hands it straight to Flutter's texture
  // registry, and the registry wants a CVPixelBuffer.
  if (_surface == nullptr) return nullptr;
  return _surface->retainPresented(_presentedIndex);
}

void Renderer::dispose() {
  if (_disposed) return;
  _disposed = true;
  // A renderer whose engine never started has nothing of Filament's to give
  // back, and the teardown below would reach for what was never made.
  if (_engine == nullptr) return;

  // Filament asserts on anything still alive when the engine goes down, so the
  // teardown mirrors construction in reverse.
  removeEverything();
  // Its renderables, instances, textures and material, and its sorting
  // threads joined, while the engine they belong to is still there.
  _splats.reset();

  // The graph's own views, cameras and targets, before the scene they point
  // at goes. _disposed is already set, so releaseGraph has to be able to run
  // afterwards — it checks the engine rather than that flag for exactly this.
  releaseGraph();

  // Its views and scenes point at the camera and share the scene's entities,
  // so it goes before either of them.
  _outline.reset();
  _outlineKeys.clear();
  // Motion blur hook: its passes, targets and materials, before the engine.
  if (_motionBlur) {
    _motionBlur->release();
    _motionBlur.reset();
  }

  for (auto &pair : _meshes) {
    if (pair.second.asset) _assetLoader->destroyAsset(pair.second.asset);
  }
  _meshes.clear();

  if (_identityInstances != nullptr) {
    _engine->destroy(_identityInstances);
    _identityInstances = nullptr;
  }

  for (auto &pair : _effectMaterials) {
    if (pair.second != nullptr) _engine->destroy(pair.second);
  }
  _effectMaterials.clear();

  releaseField();
  if (_fieldScene != nullptr) {
    _engine->destroy(_fieldScene);
    _fieldScene = nullptr;
  }
  if (_fieldView != nullptr) {
    _engine->destroy(_fieldView);
    _fieldView = nullptr;
  }
  if (_fieldCamera != nullptr) {
    utils::Entity entity = _fieldCamera->getEntity();
    _engine->destroyCameraComponent(entity);
    utils::EntityManager::get().destroy(entity);
    _fieldCamera = nullptr;
  }
  if (_fieldMaterial != nullptr) {
    _engine->destroy(_fieldMaterial);
    _fieldMaterial = nullptr;
  }

  if (_smaaArea != nullptr) {
    _engine->destroy(_smaaArea);
    _smaaArea = nullptr;
  }
  if (_smaaSearch != nullptr) {
    _engine->destroy(_smaaSearch);
    _smaaSearch = nullptr;
  }
  if (_lightData != nullptr) {
    _engine->destroy(_lightData);
    _lightData = nullptr;
  }

  for (auto &entry : _probes) releaseProbe(entry.second);
  _probes.clear();
  if (_captureCamera != nullptr) {
    utils::Entity cameraEntity = _captureCamera->getEntity();
    _engine->destroyCameraComponent(cameraEntity);
    utils::EntityManager::get().destroy(cameraEntity);
    _captureCamera = nullptr;
  }
  if (_captureView != nullptr) {
    _engine->destroy(_captureView);
    _captureView = nullptr;
  }
  delete _specularFilter;
  _specularFilter = nullptr;
  delete _prefilter;
  _prefilter = nullptr;

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
  for (auto &entry : _movies) close(entry.second);
  _movies.clear();
  _movieOrder.clear();
  if (_blankTexture != nullptr) _engine->destroy(_blankTexture);
  if (_decalData != nullptr) _engine->destroy(_decalData);
  if (_decalPictures != nullptr) _engine->destroy(_decalPictures);
  if (_decalBlankPictures != nullptr) _engine->destroy(_decalBlankPictures);
  _decalData = _decalPictures = _decalBlankPictures = nullptr;
  if (_blankExternal != nullptr) _engine->destroy(_blankExternal);
  for (Material *surface : _surfaces) {
    if (surface != nullptr) _engine->destroy(surface);
  }

  auto &entities = utils::EntityManager::get();
  _engine->destroyCameraComponent(_cameraEntity);
  entities.destroy(_cameraEntity);
  for (auto &entry : _populations) clearPopulation(entry.second);
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
  releaseBuffers();
  _engine->destroy(_view);
  _engine->destroy(_scene);
  _engine->destroy(_renderer);
  Engine::destroy(&_engine);
  _engine = nullptr;

  // After the engine, because releasing the buffers needs it — the surface
  // owns the images and the engine owns the chains onto them.
  {
    // Under the lock, because the thread that samples frames asks the
    // surface for one without going through the engine's queue.
    std::lock_guard<std::mutex> lock(_presentLock);
    delete _surface;
    _surface = nullptr;
  }
}

Notes Renderer::notes() {
  // What is wrong with *this* scene.
  //
  // A file that could not be read is remembered for as long as the renderer
  // lives, because it is only read once and re-reading it every frame to
  // find out it is still missing would be four hundred failed opens a
  // second. But remembering it is not the same as reporting it: a scene that
  // does not name that file has nothing wrong with it, and saying otherwise
  // put "the file could not be read" over a street that had loaded perfectly,
  // because a different example had failed a minute earlier.
  //
  // So the memory is kept and the answer is filtered to the files the scene
  // in front of us actually asks for.
  std::set<std::string> asked;
  for (const auto &pair : _drawn) {
    if (!pair.second.path.empty()) asked.insert(pair.second.path);
  }

  Notes all;
  for (const auto &entry : _assetNotes) {
    if (asked.count(entry.first) != 0) all[entry.first] = entry.second;
  }

  // These are already about the scene as it stands rather than about a
  // file, so they are reported as they are. Later ones win a shared key, as
  // addEntriesFromDictionary: had it.
  for (const auto &entry : _objectNotes) all[entry.first] = entry.second;
  for (const auto &entry : _lightNotes) all[entry.first] = entry.second;
  for (const auto &entry : _decalNotes) all[entry.first] = entry.second;
  for (const auto &entry : _splatNotes) all[entry.first] = entry.second;
  for (const auto &entry : _videoNotes) all[entry.first] = entry.second;
  return all;
}


void Renderer::requestCapture() {
  std::lock_guard<std::mutex> lock(_captureLock);
  _captureWanted = true;
}

bool Renderer::capturedFrame(std::vector<uint8_t> &rgba, uint32_t &width,
                             uint32_t &height) {
  std::lock_guard<std::mutex> lock(_captureLock);
  if (!_captureReady) return false;
  rgba = _captured;
  width = _capturedWidth;
  height = _capturedHeight;
  return true;
}

void Renderer::readBackIfAsked() {
  {
    std::lock_guard<std::mutex> lock(_captureLock);
    if (!_captureWanted || _captureInFlight) return;
    _captureWanted = false;
    _captureInFlight = true;
  }

  // What arrives, and where it is going. Filament calls back with the
  // buffer and one pointer, so the size travels with the renderer.
  struct Arrival {
    Renderer *renderer;
    uint32_t width;
    uint32_t height;
  };
  const size_t bytes = size_t(_width) * _height * 4;
  auto *pixels = static_cast<uint8_t *>(malloc(bytes));
  auto *arrival = new Arrival{this, _width, _height};
  _renderer->readPixels(
      0, 0, _width, _height,
      backend::PixelBufferDescriptor(
          pixels, bytes, backend::PixelDataFormat::RGBA,
          backend::PixelDataType::UBYTE,
          [](void *buffer, size_t, void *user) {
            auto *arrival = static_cast<Arrival *>(user);
            Renderer *self = arrival->renderer;
            const size_t stride = size_t(arrival->width) * 4;
            std::lock_guard<std::mutex> lock(self->_captureLock);
            self->_captured.resize(stride * arrival->height);
            // Filament reads a swap chain bottom row first, as OpenGL does
            // on every backend; a picture is stored top row first.
            const auto *from = static_cast<const uint8_t *>(buffer);
            for (uint32_t row = 0; row < arrival->height; row++) {
              memcpy(self->_captured.data() + size_t(row) * stride,
                     from + size_t(arrival->height - 1 - row) * stride,
                     stride);
            }
            self->_capturedWidth = arrival->width;
            self->_capturedHeight = arrival->height;
            self->_captureReady = true;
            self->_captureInFlight = false;
            free(buffer);
            delete arrival;
          },
          arrival));
}

}  // namespace orbis
