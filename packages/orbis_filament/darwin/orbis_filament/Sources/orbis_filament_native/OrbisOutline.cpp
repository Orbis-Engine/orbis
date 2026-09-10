#include "OrbisOutline.h"

#include <filament/Camera.h>
#include <filament/Engine.h>
#include <filament/IndexBuffer.h>
#include <filament/Material.h>
#include <filament/MaterialInstance.h>
#include <filament/RenderTarget.h>
#include <filament/RenderableManager.h>
#include <filament/Renderer.h>
#include <filament/Scene.h>
#include <filament/Texture.h>
#include <filament/TextureSampler.h>
#include <filament/VertexBuffer.h>
#include <filament/View.h>
#include <filament/Viewport.h>
#include <math/vec3.h>
#include <math/vec4.h>
#include <utils/EntityManager.h>

#include <algorithm>
#include <cmath>

// The compiled materials, as C arrays. Included here and only here: each
// header defines its array rather than declaring it.
#include "generated/outline_material.h"
#include "generated/outline_rows_material.h"

namespace orbis {

using namespace filament;

namespace {

/// One triangle bigger than the screen, in clip space, with the UVs that put
/// the texture's corners on the screen's. A quad would shade the pixels along
/// its diagonal twice; this has no diagonal.
const float kCorners[] = {
    -1.0f, -1.0f, 0.0f, 0.0f,  //
    3.0f,  -1.0f, 2.0f, 0.0f,  //
    -1.0f, 3.0f,  0.0f, 2.0f,  //
};
const uint16_t kOrder[] = {0, 1, 2};

/// Nought where nothing is to be drawn, the value otherwise — for a float that
/// arrived over a channel and may be anything at all.
float finiteOr(float value, float otherwise) {
  return std::isfinite(value) ? value : otherwise;
}

float unit(float value) { return std::clamp(finiteOr(value, 0.0f), 0.0f, 1.0f); }

/// How far either pass has to look for an outline this wide: its width, and
/// one more for the soft pixel beyond it.
int reachFor(float width) { return int(std::ceil(width)) + 1; }

}  // namespace

OutlineStyle OutlineStyle::from(const float *p) {
  OutlineStyle style;
  for (int i = 0; i < 4; i++) {
    style.colour[i] = unit(p[i]);
    style.primaryColour[i] = unit(p[4 + i]);
  }
  style.width = std::clamp(finiteOr(p[8], 2.0f), 0.0f, kMostOutlineWidth);
  const int occluded = int(finiteOr(p[9], 2.0f));
  style.occluded = static_cast<Occluded>(std::clamp(occluded, 0, 3));
  style.occludedOpacity = unit(p[10]);
  style.dash = std::max(0.0f, finiteOr(p[11], 0.0f));
  return style;
}

bool OutlineStyle::operator==(const OutlineStyle &other) const {
  return std::equal(colour, colour + 4, other.colour) &&
         std::equal(primaryColour, primaryColour + 4, other.primaryColour) &&
         width == other.width && occluded == other.occluded &&
         occludedOpacity == other.occludedOpacity && dash == other.dash;
}

Outline::Outline(Engine &engine) : mEngine(engine) {}

Outline::~Outline() {
  releaseScreen(mRowsPass);
  releaseScreen(mComposite);
  releaseTargets();
  for (Mask &mask : mMasks) {
    if (mask.view != nullptr) mEngine.destroy(mask.view);
    mask.view = nullptr;
  }
  if (mPrimaryScene != nullptr) mEngine.destroy(mPrimaryScene);
  if (mOthersScene != nullptr) mEngine.destroy(mOthersScene);
  if (!mScreenCameraEntity.isNull()) {
    mEngine.destroyCameraComponent(mScreenCameraEntity);
    utils::EntityManager::get().destroy(mScreenCameraEntity);
  }
  if (mTriangle != nullptr) mEngine.destroy(mTriangle);
  if (mTriangleOrder != nullptr) mEngine.destroy(mTriangleOrder);
  if (mRowsMaterial != nullptr) mEngine.destroy(mRowsMaterial);
  if (mCompositeMaterial != nullptr) mEngine.destroy(mCompositeMaterial);
}

void Outline::setEntities(const std::vector<utils::Entity> &primary,
                          const std::vector<utils::Entity> &others) {
  // Rebuilt only when the lists move. A selection is republished on every
  // frame of a drag, and it is almost always the same selection.
  const bool samePrimary = primary == mPrimary;
  const bool sameOthers = others == mOthers;
  if (samePrimary && sameOthers) return;
  mPrimary = primary;
  mOthers = others;
  if (!mBuilt) return;
  if (!samePrimary) fill(mPrimaryScene, mPrimary);
  if (!sameOthers) fill(mOthersScene, mOthers);
}

void Outline::fill(Scene *scene, const std::vector<utils::Entity> &entities) {
  if (scene == nullptr) return;
  // Emptied whole rather than by the old list: an entity in it may have been
  // destroyed since, and removing by the list would be naming something that
  // is no longer there.
  scene->removeAllEntities();
  if (!entities.empty()) scene->addEntities(entities.data(), entities.size());
}

bool Outline::build() {
  if (mBuilt) return mRowsMaterial != nullptr;
  mBuilt = true;

  mRowsMaterial = Material::Builder()
                      .package(koutline_rowsMaterial, koutline_rowsMaterial_len)
                      .build(mEngine);
  mCompositeMaterial = Material::Builder()
                           .package(koutlineMaterial, koutlineMaterial_len)
                           .build(mEngine);
  if (mRowsMaterial == nullptr || mCompositeMaterial == nullptr) return false;

  mTriangle = VertexBuffer::Builder()
                  .vertexCount(3)
                  .bufferCount(1)
                  .attribute(VertexAttribute::POSITION, 0,
                             VertexBuffer::AttributeType::FLOAT2, 0,
                             sizeof(float) * 4)
                  .attribute(VertexAttribute::UV0, 0,
                             VertexBuffer::AttributeType::FLOAT2,
                             sizeof(float) * 2, sizeof(float) * 4)
                  .build(mEngine);
  // File-scope constants outlive the upload, so no release callback.
  mTriangle->setBufferAt(
      mEngine, 0, VertexBuffer::BufferDescriptor(kCorners, sizeof(kCorners)));
  mTriangleOrder = IndexBuffer::Builder()
                       .indexCount(3)
                       .bufferType(IndexBuffer::IndexType::USHORT)
                       .build(mEngine);
  mTriangleOrder->setBuffer(
      mEngine, IndexBuffer::BufferDescriptor(kOrder, sizeof(kOrder)));

  // Exposure one, and it is not cosmetic: Filament scales what an unlit
  // material writes by the camera's exposure. The rows pass writes distances
  // and the composite writes a display colour, and neither is light.
  mScreenCameraEntity = utils::EntityManager::get().create();
  mScreenCamera = mEngine.createCamera(mScreenCameraEntity);
  mScreenCamera->setProjection(Camera::Projection::ORTHO, -1, 1, -1, 1, 0, 1);
  mScreenCamera->setExposure(1.0f);

  buildScreen(mRowsPass, mRowsMaterial);
  buildScreen(mComposite, mCompositeMaterial);

  // Over the frame rather than instead of it. With post-processing off the
  // triangle is drawn straight into the swap chain, its blending does the
  // compositing, and nothing is tone-mapped twice.
  mComposite.view->setBlendMode(View::BlendMode::TRANSLUCENT);

  mPrimaryScene = mEngine.createScene();
  mOthersScene = mEngine.createScene();
  fill(mPrimaryScene, mPrimary);
  fill(mOthersScene, mOthers);

  for (Mask &mask : mMasks) {
    mask.view = mEngine.createView();
    // Depth is all that is read, so everything that only changes colour is
    // off. Shadows especially: left on, each of these views would render
    // every shadow map in the scene again for a picture nobody looks at.
    mask.view->setPostProcessingEnabled(false);
    mask.view->setShadowingEnabled(false);
    mask.view->setAntiAliasing(View::AntiAliasing::NONE);
  }
  return true;
}

void Outline::buildScreen(Screen &screen, Material *material) {
  screen.instance = material->createInstance();
  screen.entity = utils::EntityManager::get().create();
  RenderableManager::Builder(1)
      .boundingBox({{-1, -1, -1}, {1, 1, 1}})
      // It is the screen; a culling test that decided otherwise would be
      // wrong.
      .culling(false)
      .castShadows(false)
      .receiveShadows(false)
      .material(0, screen.instance)
      .geometry(0, RenderableManager::PrimitiveType::TRIANGLES, mTriangle,
                mTriangleOrder, 0, 3)
      .build(mEngine, screen.entity);
  screen.scene = mEngine.createScene();
  screen.scene->addEntity(screen.entity);

  screen.view = mEngine.createView();
  screen.view->setScene(screen.scene);
  screen.view->setCamera(mScreenCamera);
  // Linear data in, exact colour out: no tone mapping, no dithering, no
  // anti-aliasing smearing a distance field.
  screen.view->setPostProcessingEnabled(false);
  screen.view->setShadowingEnabled(false);
  screen.view->setAntiAliasing(View::AntiAliasing::NONE);
}

void Outline::prepareTargets(uint32_t width, uint32_t height) {
  width = std::max(1u, width);
  height = std::max(1u, height);
  if (mRowsTarget != nullptr && mBuiltWidth == width &&
      mBuiltHeight == height) {
    return;
  }
  releaseTargets();

  for (Mask &mask : mMasks) {
    // Thirty-two bit float, because the comparison against the scene's depth
    // is what decides visible from hidden, and at a distance the difference
    // between an object and the wall just behind it is a few ulps.
    mask.depth = Texture::Builder()
                     .width(width)
                     .height(height)
                     .levels(1)
                     .usage(Texture::Usage::DEPTH_ATTACHMENT |
                            Texture::Usage::SAMPLEABLE)
                     .format(Texture::InternalFormat::DEPTH32F)
                     .build(mEngine);
    mask.target = RenderTarget::Builder()
                      .texture(RenderTarget::AttachmentPoint::DEPTH, mask.depth)
                      .build(mEngine);
  }

  // Four distances a pixel, one per kind of edge. Half floats: a distance is
  // at most a few dozen pixels.
  mRows = Texture::Builder()
              .width(width)
              .height(height)
              .levels(1)
              .usage(Texture::Usage::COLOR_ATTACHMENT |
                     Texture::Usage::SAMPLEABLE)
              .format(Texture::InternalFormat::RGBA16F)
              .build(mEngine);
  mRowsTarget = RenderTarget::Builder()
                    .texture(RenderTarget::AttachmentPoint::COLOR, mRows)
                    .build(mEngine);
  mBuiltWidth = width;
  mBuiltHeight = height;
}

void Outline::releaseTargets() {
  // Safe to destroy at once, unlike the render graph's targets: nothing but
  // this class samples these, and it binds them afresh before every render.
  for (Mask &mask : mMasks) {
    if (mask.target != nullptr) mEngine.destroy(mask.target);
    if (mask.depth != nullptr) mEngine.destroy(mask.depth);
    mask.target = nullptr;
    mask.depth = nullptr;
  }
  if (mRowsTarget != nullptr) mEngine.destroy(mRowsTarget);
  if (mRows != nullptr) mEngine.destroy(mRows);
  mRowsTarget = nullptr;
  mRows = nullptr;
  mBuiltWidth = 0;
  mBuiltHeight = 0;
}

void Outline::releaseScreen(Screen &screen) {
  if (screen.view != nullptr) mEngine.destroy(screen.view);
  if (screen.scene != nullptr) mEngine.destroy(screen.scene);
  if (!screen.entity.isNull()) {
    mEngine.destroy(screen.entity);
    utils::EntityManager::get().destroy(screen.entity);
  }
  if (screen.instance != nullptr) mEngine.destroy(screen.instance);
  screen = Screen();
}

void Outline::render(Renderer &renderer, Scene &world, Camera &camera,
                     uint32_t width, uint32_t height, uint8_t layers) {
  mLastRenders = 0;
  if (!active()) return;
  if (!build()) return;
  prepareTargets(width, height);

  const Viewport whole{0, 0, width, height};
  auto draw = [&](Mask &mask, Scene *scene) {
    mask.view->setScene(scene);
    mask.view->setCamera(&camera);
    mask.view->setRenderTarget(mask.target);
    mask.view->setViewport(whole);
    mask.view->setVisibleLayers(0xFF, layers);
    renderer.render(mask.view);
    mLastRenders++;
  };

  const bool drawPrimary = !mPrimary.empty();
  const bool drawOthers = !mOthers.empty();
  // Only worth knowing what hides what if hidden parts look different.
  const bool drawWorld = mStyle.occluded != Occluded::shown;
  if (drawPrimary) draw(mMasks[0], mPrimaryScene);
  if (drawOthers) draw(mMasks[1], mOthersScene);
  if (drawWorld) draw(mMasks[2], &world);

  // Nearest, always: a filtered depth is a distance at which nothing stands,
  // and a filtered distance is an edge in the wrong place.
  const TextureSampler exact(TextureSampler::MinFilter::NEAREST,
                             TextureSampler::MagFilter::NEAREST,
                             TextureSampler::WrapMode::CLAMP_TO_EDGE);
  const int reach = reachFor(mStyle.width);

  MaterialInstance *rows = mRowsPass.instance;
  rows->setParameter("primary", mMasks[0].depth, exact);
  rows->setParameter("others", mMasks[1].depth, exact);
  rows->setParameter("world", mMasks[2].depth, exact);
  rows->setParameter("drawn", math::float3{drawPrimary ? 1.0f : 0.0f,
                                           drawOthers ? 1.0f : 0.0f,
                                           drawWorld ? 1.0f : 0.0f});
  rows->setParameter("reach", int32_t(reach));
  mRowsPass.view->setRenderTarget(mRowsTarget);
  mRowsPass.view->setViewport(whole);
  renderer.render(mRowsPass.view);
  mLastRenders++;

  // Hidden parts: the style decides how much of them is left.
  float hidden = 1.0f;
  float dash = 0.0f;
  switch (mStyle.occluded) {
    case Occluded::shown:
      break;
    case Occluded::faint:
      hidden = mStyle.occludedOpacity;
      break;
    case Occluded::dashed:
      hidden = mStyle.occludedOpacity;
      dash = mStyle.dash > 0.0f ? mStyle.dash : 6.0f;
      break;
    case Occluded::hidden:
      hidden = 0.0f;
      break;
  }

  MaterialInstance *composite = mComposite.instance;
  composite->setParameter("rows", mRows, exact);
  composite->setParameter("reach", int32_t(reach));
  composite->setParameter("width", mStyle.width);
  composite->setParameter(
      "primaryColour",
      math::float4{mStyle.primaryColour[0], mStyle.primaryColour[1],
                   mStyle.primaryColour[2], mStyle.primaryColour[3]});
  composite->setParameter("otherColour",
                          math::float4{mStyle.colour[0], mStyle.colour[1],
                                       mStyle.colour[2], mStyle.colour[3]});
  composite->setParameter("hiddenOpacity", hidden);
  composite->setParameter("dash", dash);
  // The swap chain, which already holds the finished frame.
  mComposite.view->setRenderTarget(nullptr);
  mComposite.view->setViewport(whole);
  renderer.render(mComposite.view);
  mLastRenders++;
}

}  // namespace orbis
