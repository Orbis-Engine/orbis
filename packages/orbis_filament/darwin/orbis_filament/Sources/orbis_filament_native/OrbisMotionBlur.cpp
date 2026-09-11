#include "OrbisMotionBlur.h"

#include <filament/IndexBuffer.h>
#include <filament/Material.h>
#include <filament/RenderTarget.h>
#include <filament/RenderableManager.h>
#include <filament/Scene.h>
#include <filament/TextureSampler.h>
#include <filament/TransformManager.h>
#include <filament/VertexBuffer.h>
#include <filament/View.h>
#include <filament/Viewport.h>
#include <utils/EntityManager.h>

#include <algorithm>
#include <cmath>
#include <cstring>

// Each compiled material defines a symbol, so each is included by exactly one
// file. These five are this file's; the renderer builds the gather's instance
// through gatherPackage() rather than including it a second time.
#include "generated/motion_blank_material.h"
#include "generated/motion_gather_material.h"
#include "generated/motion_resolve_material.h"
#include "generated/motion_tiles_material.h"
#include "generated/velocity_material.h"

using namespace filament;
using namespace filament::math;

namespace orbis {
namespace {

/// One triangle bigger than the screen, positions already in clip space and
/// the UVs the fragment reads by. The same shape every effect pass draws, for
/// the same reason: two triangles shade the seam between them twice.
const float kCorners[] = {
    -1.0f, -1.0f, 0.0f, 0.0f,  //
    3.0f,  -1.0f, 2.0f, 0.0f,  //
    -1.0f, 3.0f,  0.0f, 2.0f,  //
};
const uint16_t kOrder[] = {0, 1, 2};

/// The longest gap between two frames, or two publishes, that is still read
/// as motion. Anything longer is a pause — the application was busy or has
/// only just started — and dividing by it would read a jump as a speed.
constexpr double kPause = 0.25;

/// How long an object's last measured motion is believed with no newer
/// publish behind it. A host that stops publishing has stopped moving things,
/// and an object left streaking after it came to rest looks like a fault.
constexpr double kStale = 0.2;

/// The shortest gap between two frames the camera's motion is divided by.
/// Two frames a millisecond apart moved the camera by almost nothing, and
/// what little there is is mostly the prediction's own correction, which a
/// division by a millisecond turns into a violent speed.
constexpr double kShortestFrame = 0.004;

/// The layers a moving object may be drawn on: everything but the hidden bit,
/// the same mask the renderer's own passes stop at.
constexpr uint8_t kShownLayers = 0x7F;

double since(std::chrono::steady_clock::time_point when) {
  return std::chrono::duration<double>(std::chrono::steady_clock::now() - when)
      .count();
}

bool same(const mat4f &a, const mat4f &b) {
  return std::memcmp(&a, &b, sizeof(mat4f)) == 0;
}

bool same(const mat4 &a, const mat4 &b) {
  return std::memcmp(&a, &b, sizeof(mat4)) == 0;
}

}  // namespace

MotionBlur::MotionBlur(Engine &engine) : engine_(engine) {}

MotionBlur::~MotionBlur() { release(); }

const uint8_t *MotionBlur::gatherPackage() { return kmotion_gatherMaterial; }

size_t MotionBlur::gatherPackageSize() { return kmotion_gatherMaterial_len; }

void MotionBlur::setWanted(bool wanted, bool objects) {
  wanted_ = wanted;
  objects_ = wanted && objects;
  if (!objects_) {
    records_.clear();
    committed_ = true;
    haveAt_ = false;
  }
  if (!wanted_) {
    frames_ = 0;
    // Given back rather than kept: a graph that no longer blurs should cost
    // what it cost before it ever did.
    release();
  }
}

void MotionBlur::beginPublish() {
  if (!objects_) return;
  // A publish that never said when it was is taken as a restatement of the
  // last moment: without a time there is no speed to measure.
  if (!committed_) commit(at_, false);
  ++publish_;
  committed_ = false;
}

void MotionBlur::place(int64_t key, const mat4f &transform, utils::Entity root,
                       const utils::Entity *entities, size_t count) {
  if (!objects_ || committed_) return;
  Record &record = records_[key];
  // A different root is a different object under the same key — rebuilt from
  // another mesh — and its last position is no guide to this one's.
  if (record.seen == 0 || record.root != root) {
    record.root = root;
    record.entities.assign(entities, entities + count);
    record.fresh = true;
  }
  record.pending = transform;
  record.seen = publish_;
}

void MotionBlur::stamp(double at) {
  if (!objects_ || committed_) return;
  // The same moment published twice — a widget rebuilt within one frame — is
  // a restatement rather than a step. Taking it as a step would compare the
  // scene with itself and stop everything blurring for a frame.
  commit(at, !haveAt_ || at > at_ + 1e-6);
}

void MotionBlur::commit(double at, bool newMoment) {
  for (auto it = records_.begin(); it != records_.end();) {
    Record &record = it->second;
    // Whatever this publish did not mention has left the scene.
    if (record.seen != publish_) {
      it = records_.erase(it);
      continue;
    }
    if (record.fresh) {
      record.now = record.pending;
      record.was = record.pending;
      record.fresh = false;
    } else if (newMoment) {
      record.was = record.now;
      record.now = record.pending;
    } else {
      record.now = record.pending;
    }
    ++it;
  }
  if (newMoment) {
    atWas_ = haveAt_ ? at_ : at;
    at_ = at;
    haveAt_ = true;
  }
  arrived_ = std::chrono::steady_clock::now();
  committed_ = true;
}

void MotionBlur::frameBegan(const Camera &camera) {
  if (!wanted_) return;
  const auto now = std::chrono::steady_clock::now();
  const mat4 viewProjection =
      camera.getProjectionMatrix() * camera.getViewMatrix();
  if (frames_ == 0) {
    viewProjectionWas_ = viewProjection;
    frameGap_ = 0;
  } else {
    viewProjectionWas_ = viewProjection_;
    frameGap_ = std::chrono::duration<double>(now - frameAt_).count();
  }
  viewProjection_ = viewProjection;
  frameAt_ = now;
  frames_++;
}

bool MotionBlur::build() {
  if (built_) return true;

  velocity_ = Material::Builder()
                  .package(kvelocityMaterial, kvelocityMaterial_len)
                  .build(engine_);
  blank_ = Material::Builder()
               .package(kmotion_blankMaterial, kmotion_blankMaterial_len)
               .build(engine_);
  resolve_ = Material::Builder()
                 .package(kmotion_resolveMaterial, kmotion_resolveMaterial_len)
                 .build(engine_);
  tiles_ = Material::Builder()
               .package(kmotion_tilesMaterial, kmotion_tilesMaterial_len)
               .build(engine_);
  if (velocity_ == nullptr || blank_ == nullptr || resolve_ == nullptr ||
      tiles_ == nullptr) {
    return false;
  }

  corners_ = VertexBuffer::Builder()
                 .vertexCount(3)
                 .bufferCount(1)
                 .attribute(VertexAttribute::POSITION, 0,
                            VertexBuffer::AttributeType::FLOAT2, 0,
                            sizeof(float) * 4)
                 .attribute(VertexAttribute::UV0, 0,
                            VertexBuffer::AttributeType::FLOAT2,
                            sizeof(float) * 2, sizeof(float) * 4)
                 .build(engine_);
  // Namespace-scope constants outlive the upload, so no callback is needed.
  corners_->setBufferAt(
      engine_, 0,
      VertexBuffer::BufferDescriptor(kCorners, sizeof(kCorners), nullptr));
  order_ = IndexBuffer::Builder()
               .indexCount(3)
               .bufferType(IndexBuffer::IndexType::USHORT)
               .build(engine_);
  order_->setBuffer(engine_,
                    IndexBuffer::BufferDescriptor(kOrder, sizeof(kOrder), nullptr));

  // The blank goes in the first channel, so it is drawn before any object
  // whatever the sort would otherwise say. Filament's clear belongs to the
  // swap chain, not to each target a view draws into, so a target is emptied
  // by drawing nothing over all of it rather than trusted to be empty.
  buildScreen(objectScreen_, blank_, 0);
  buildScreen(resolveScreen_, resolve_, 2);
  buildScreen(tileScreen_, tiles_, 2);
  objectScreen_.view->setVisibleLayers(0xFF, kShownLayers);

  built_ = true;
  return true;
}

void MotionBlur::buildScreen(Screen &screen, Material *material,
                             uint8_t channel) {
  screen.instance = material->createInstance();
  screen.entity = utils::EntityManager::get().create();
  RenderableManager::Builder(1)
      .boundingBox({{-1, -1, -1}, {1, 1, 1}})
      .culling(false)
      .material(0, screen.instance)
      .geometry(0, RenderableManager::PrimitiveType::TRIANGLES, corners_,
                order_, 0, 3)
      .castShadows(false)
      .receiveShadows(false)
      .channel(channel)
      .priority(0)
      .build(engine_, screen.entity);

  screen.scene = engine_.createScene();
  screen.scene->addEntity(screen.entity);

  screen.cameraEntity = utils::EntityManager::get().create();
  screen.camera = engine_.createCamera(screen.cameraEntity);
  // Neutral exposure, because what these passes write is data. Filament
  // scales an unlit material's output by the camera's exposure, and a
  // velocity scaled by a photograph's exposure is a velocity of nothing.
  screen.camera->setExposure(1.0f);

  screen.view = engine_.createView();
  screen.view->setScene(screen.scene);
  screen.view->setCamera(screen.camera);
  // No post and no shadows: nothing here is looked at, and the dithering
  // post adds would be noise in a velocity.
  screen.view->setPostProcessingEnabled(false);
  screen.view->setShadowingEnabled(false);
}

void MotionBlur::releaseScreen(Screen &screen) {
  if (screen.view != nullptr) engine_.destroy(screen.view);
  if (screen.scene != nullptr) engine_.destroy(screen.scene);
  if (!screen.cameraEntity.isNull()) {
    engine_.destroyCameraComponent(screen.cameraEntity);
    utils::EntityManager::get().destroy(screen.cameraEntity);
  }
  if (!screen.entity.isNull()) {
    engine_.destroy(screen.entity);
    utils::EntityManager::get().destroy(screen.entity);
  }
  if (screen.instance != nullptr) engine_.destroy(screen.instance);
  screen = Screen{};
}

void MotionBlur::size(uint32_t width, uint32_t height, uint32_t tile) {
  if (resolved_ != nullptr && width == width_ && height == height_ &&
      tile == tile_) {
    return;
  }
  releaseTargets();

  const auto colourTexture = [&](uint32_t wide, uint32_t tall) {
    // Half floats: a velocity is signed, and a distance is metres.
    return Texture::Builder()
        .width(wide)
        .height(tall)
        .levels(1)
        .usage(Texture::Usage::COLOR_ATTACHMENT | Texture::Usage::SAMPLEABLE)
        .format(Texture::InternalFormat::RGBA16F)
        .build(engine_);
  };

  objectColour_ = colourTexture(width, height);
  // The moving objects' own depth, so the nearest of them wins where they
  // overlap. Never sampled: the scene's depth is what decides whether any of
  // them is actually what a pixel shows.
  objectDepth_ = Texture::Builder()
                     .width(width)
                     .height(height)
                     .levels(1)
                     .usage(Texture::Usage::DEPTH_ATTACHMENT)
                     .format(Texture::InternalFormat::DEPTH32F)
                     .build(engine_);
  objectTarget_ = RenderTarget::Builder()
                      .texture(RenderTarget::AttachmentPoint::COLOR, objectColour_)
                      .texture(RenderTarget::AttachmentPoint::DEPTH, objectDepth_)
                      .build(engine_);

  resolved_ = colourTexture(width, height);
  resolvedTarget_ = RenderTarget::Builder()
                        .texture(RenderTarget::AttachmentPoint::COLOR, resolved_)
                        .build(engine_);

  const uint32_t across = (width + tile - 1) / tile;
  const uint32_t down = (height + tile - 1) / tile;
  tileMax_ = colourTexture(across, down);
  tileTarget_ = RenderTarget::Builder()
                    .texture(RenderTarget::AttachmentPoint::COLOR, tileMax_)
                    .build(engine_);

  width_ = width;
  height_ = height;
  tile_ = tile;
}

void MotionBlur::releaseTargets() {
  // Render targets before the textures behind them. Nothing samples a render
  // target, and every material sampling these textures is re-bound before
  // anything is drawn with it again.
  for (RenderTarget **target : {&objectTarget_, &resolvedTarget_, &tileTarget_}) {
    if (*target != nullptr) engine_.destroy(*target);
    *target = nullptr;
  }
  for (Texture **texture : {&objectColour_, &objectDepth_, &resolved_, &tileMax_}) {
    if (*texture != nullptr) engine_.destroy(*texture);
    *texture = nullptr;
  }
  width_ = 0;
  height_ = 0;
  tile_ = 0;
}

bool MotionBlur::drawObjects(Renderer &renderer, const Camera &camera,
                             float shutter) {
  if (records_.empty() || !haveAt_) return false;
  const double span = at_ - atWas_;
  if (span <= 1e-4 || span > kPause || since(arrived_) > kStale) return false;

  // How much of one publish's travel the shutter records. A publish is not a
  // frame — the host publishes on its own clock and this draws on the
  // display's — so the speed comes from the host's own seconds, and the same
  // shutter blurs the same object the same amount at any rate.
  const double scale = double(shutter) / span;

  auto &transforms = engine_.getTransformManager();
  auto &renderables = engine_.getRenderableManager();
  const mat4 clipFromWorld = viewProjection_;

  std::vector<Lent> lent;
  size_t used = 0;
  for (const auto &pair : records_) {
    const Record &record = pair.second;
    if (same(record.now, record.was)) continue;

    // What carries a point from where the object stands now to where it
    // stood a publish ago, in the host's own world. Applied to each part's
    // world transform rather than rebuilt from the root, so a model's nodes
    // come along however deep they sit under it.
    const mat4 back = mat4(record.was) * inverse(mat4(record.now));

    for (const utils::Entity entity : record.entities) {
      const auto renderable = renderables.getInstance(entity);
      const auto placed = transforms.getInstance(entity);
      if (!renderable || !placed) continue;

      const mat4 world = mat4(transforms.getWorldTransform(placed));
      const mat4 then = back * world;
      // Back along a straight line to where it was a shutter ago: exact for
      // an object sliding, the chord of the arc for one turning — which is
      // the line the gather smears along anyway.
      mat4 opened;
      for (int column = 0; column < 4; column++) {
        opened[column] = world[column] + (then[column] - world[column]) * scale;
      }

      if (used == lent_.size()) lent_.push_back(velocity_->createInstance());
      MaterialInstance *instance = lent_[used++];
      instance->setParameter("nowFromModel", mat4f(clipFromWorld * world));
      instance->setParameter("thenFromModel", mat4f(clipFromWorld * opened));

      // Lent for the length of one draw. The frame's own passes have already
      // drawn with the object's material, and get it back before anything
      // else draws.
      const size_t primitives = renderables.getPrimitiveCount(renderable);
      for (size_t p = 0; p < primitives; p++) {
        lent.push_back({entity, p, renderables.getMaterialInstanceAt(renderable, p)});
        renderables.setMaterialInstanceAt(renderable, p, instance);
      }
      objectScreen_.scene->addEntity(entity);
      drawnObjects_.push_back(entity);
    }
  }
  if (used == 0) return false;

  // Through the scene's own camera, so every moving object lands on exactly
  // the pixels it was drawn on. The culling projection, because it is the one
  // the camera was given and can be handed straight back; the rendering one
  // has the depth convention folded into it.
  Camera &eye = *objectScreen_.camera;
  eye.setModelMatrix(camera.getModelMatrix());
  eye.setCustomProjection(camera.getCullingProjectionMatrix(), camera.getNear(),
                          camera.getCullingFar());
  View &view = *objectScreen_.view;
  view.setRenderTarget(objectTarget_);
  view.setViewport({0, 0, width_, height_});
  renderer.render(&view);

  for (const Lent &one : lent) {
    const auto renderable = renderables.getInstance(one.entity);
    if (renderable) renderables.setMaterialInstanceAt(renderable, one.primitive, one.own);
  }
  for (const utils::Entity entity : drawnObjects_) {
    objectScreen_.scene->remove(entity);
  }
  drawnObjects_.clear();
  return true;
}

void MotionBlur::prepare(Renderer &renderer, const Camera &camera,
                         Texture *colour, Texture *depth, uint32_t width,
                         uint32_t height, const float dials[4],
                         MaterialInstance &gather) {
  (void)colour;  // bound by the renderer as the gather's `source`
  if (!build()) {
    gather.setParameter("on", 0.0f);
    return;
  }

  // The four dials, each defaulting at nought.
  const float shutter =
      dials[0] > 0.0f ? dials[0] : std::max(camera.getShutterSpeed(), 0.0f);
  const float longest = dials[1] > 0.0f ? std::clamp(dials[1], 1.0f, 64.0f) : 40.0f;
  const bool objects = dials[2] >= 0.0f;
  const int samples =
      std::clamp((dials[3] > 0.0f ? int(dials[3]) : 15) | 1, 3, 31);

  // A tile is as wide as the longest half-streak, so a pixel's own tile and
  // the eight round it hold every pixel whose streak can reach it.
  const float radius = longest * 0.5f;
  const uint32_t tile = std::clamp(uint32_t(std::ceil(radius)), 1u, 32u);
  size(std::max(width, 1u), std::max(height, 1u), tile);

  const TextureSampler exact(TextureSampler::MinFilter::NEAREST,
                             TextureSampler::MagFilter::NEAREST,
                             TextureSampler::WrapMode::CLAMP_TO_EDGE);
  const float2 pixels{float(width_), float(height_)};
  const float2 grid{float((width_ + tile - 1) / tile),
                    float((height_ + tile - 1) / tile)};

  // Every sampler bound whatever happens next: Filament wants them all, and
  // a pass told to copy still has them declared.
  gather.setParameter("velocity", resolved_, exact);
  gather.setParameter("tileMax", tileMax_, exact);
  gather.setParameter("size", pixels);
  gather.setParameter("grid", grid);
  gather.setParameter("tile", int32_t(tile));
  gather.setParameter("samples", int32_t(samples));

  // The camera's part, rebuilt from depth. Only for a perspective camera:
  // the depth-to-distance step is near/depth, which is a perspective fact,
  // and an orthographic view is left to its objects' own motion.
  const mat4 projection = camera.getProjectionMatrix();
  const bool perspective = std::abs(projection[3][3]) < 0.5;
  double cameraScale = 0.0;
  if (perspective && depth != nullptr && frames_ > 1 && frameGap_ < kPause &&
      !same(viewProjection_, viewProjectionWas_)) {
    cameraScale = double(shutter) / std::max(frameGap_, kShortestFrame);
  }

  const bool drewObjects = depth != nullptr && objects && objects_ &&
                           drawObjects(renderer, camera, shutter);

  // Nothing moved: the picture already is what the shutter saw, and the
  // gather copies it rather than three passes proving as much.
  if (cameraScale <= 0.0 && !drewObjects) {
    gather.setParameter("on", 0.0f);
    return;
  }

  MaterialInstance &resolve = *resolveScreen_.instance;
  resolve.setParameter("depth", depth, exact);
  resolve.setParameter("objects", objectColour_, exact);
  resolve.setParameter("useObjects", drewObjects ? 1.0f : 0.0f);
  resolve.setParameter("near", float(camera.getNear()));
  resolve.setParameter("tangents", float2{float(1.0 / projection[0][0]),
                                          float(1.0 / projection[1][1])});
  // Last frame's clip space from this frame's view space: back into the
  // world by this frame's camera, forward by last frame's.
  resolve.setParameter("reproject",
                       mat4f(viewProjectionWas_ * camera.getModelMatrix()));
  resolve.setParameter("cameraScale", float(cameraScale));
  resolve.setParameter("size", pixels);
  resolve.setParameter("radius", radius);
  resolveScreen_.view->setRenderTarget(resolvedTarget_);
  resolveScreen_.view->setViewport({0, 0, width_, height_});
  renderer.render(resolveScreen_.view);

  MaterialInstance &tiles = *tileScreen_.instance;
  tiles.setParameter("velocity", resolved_, exact);
  tiles.setParameter("tile", int32_t(tile));
  tiles.setParameter("tiles", grid);
  tiles.setParameter("size", pixels);
  tileScreen_.view->setRenderTarget(tileTarget_);
  tileScreen_.view->setViewport(
      {0, 0, uint32_t(grid.x), uint32_t(grid.y)});
  renderer.render(tileScreen_.view);

  gather.setParameter("on", 1.0f);
}

void MotionBlur::release() {
  // Renderables before the instances they wear, instances before their
  // materials — Filament refuses the other order.
  releaseScreen(objectScreen_);
  releaseScreen(resolveScreen_);
  releaseScreen(tileScreen_);
  for (MaterialInstance *instance : lent_) engine_.destroy(instance);
  lent_.clear();
  releaseTargets();
  for (Material **material : {&velocity_, &blank_, &resolve_, &tiles_}) {
    if (*material != nullptr) engine_.destroy(*material);
    *material = nullptr;
  }
  if (corners_ != nullptr) engine_.destroy(corners_);
  if (order_ != nullptr) engine_.destroy(order_);
  corners_ = nullptr;
  order_ = nullptr;
  built_ = false;
}

}  // namespace orbis
