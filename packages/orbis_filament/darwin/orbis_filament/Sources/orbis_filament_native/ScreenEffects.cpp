#include "ScreenEffects.h"

#include <filament/TextureSampler.h>

#include <algorithm>
#include <cmath>
#include <cstring>

// The two materials, compiled by setup.sh. Included here and nowhere else —
// see screenEffectPackage.
#include "generated/distortion_material.h"
#include "generated/godrays_material.h"

namespace orbis {

using filament::Camera;
using filament::MaterialInstance;
using filament::Texture;
using filament::TextureSampler;
using filament::math::double4;
using filament::math::float2;
using filament::math::float3;
using filament::math::float4;
using filament::math::mat4;

namespace {

float smoothstep(float from, float to, float x) {
  const float t = std::clamp((x - from) / (to - from), 0.0f, 1.0f);
  return t * t * (3.0f - 2.0f * t);
}

// Filament's view space looks down -z; the effect passes reconstruct
// positions with the eye looking down +z, because that is what a depth read
// back as a distance gives. One sign apart, and the sign has to be the same
// in both places.
float3 toEffectSpace(const mat4 &viewFromWorld, float3 world) {
  const double4 v = viewFromWorld * double4(world.x, world.y, world.z, 1.0);
  return float3{float(v.x), float(v.y), float(-v.z)};
}

// How far along its ray a surface must be to count as sky, in metres.
//
// The sky dome writes no depth and a skybox is behind everything, so almost
// all sky arrives as a cleared depth of nought and never reaches this test.
// It is here for geometry near the camera's far plane of a thousand metres,
// which is scenery rather than something to cast a shadow into the air.
constexpr float kSkyDistance = 800.0f;

// How far from the sun the sky still sends light, as a fraction of the
// frame's height. Wide enough that a sun just behind a pillar still fills the
// gaps either side; narrow enough that the open sky across the frame does not
// glow as though the sun were everywhere.
constexpr float kGlow = 0.35f;

// Where the effect materials read depth. Nearest, as the bounce pass does
// it: a linear tap between two depths is a distance at which nothing stands.
const TextureSampler kExact(TextureSampler::MinFilter::NEAREST,
                            TextureSampler::MagFilter::NEAREST,
                            TextureSampler::WrapMode::CLAMP_TO_EDGE);

// The numbers both materials share for turning depth back into position.
void applyDepth(MaterialInstance &material, const Camera &camera,
                uint32_t width, uint32_t height, Texture *depth) {
  material.setParameter("depth", depth, kExact);
  material.setParameter("near", float(camera.getNear()));
  // The half field of view as tangents, read off the projection so an
  // off-centre camera cannot disagree with it.
  const mat4 clipFromView = camera.getProjectionMatrix();
  material.setParameter("tangents",
                        float2{float(1.0 / clipFromView[0][0]),
                               float(1.0 / clipFromView[1][1])});
  material.setParameter("aspect",
                        float(width) / float(std::max(height, 1u)));
}

}  // namespace

SunOnScreen projectSun(const mat4 &clipFromView, const mat4 &viewFromWorld,
                       float3 towardLight) {
  SunOnScreen out;
  const float length = std::sqrt(dot(towardLight, towardLight));
  if (!(length > 0.0f)) return out;
  const float3 toward = towardLight / length;

  // w = 0: a direction, so the camera's position drops out and only its turn
  // is left.
  const double4 view = viewFromWorld * double4(toward.x, toward.y, toward.z, 0.0);
  const double4 clip = clipFromView * view;

  // An orthographic camera maps a point at infinity to nowhere in particular,
  // and a light behind the eye projects through it and lands mirrored on the
  // screen. The second is the one that matters: without this the shafts would
  // stream towards a sun that is over the viewer's shoulder.
  if (!(clip.w > 1e-6)) return out;

  const float2 ndc{float(clip.x / clip.w), float(clip.y / clip.w)};
  out.uv = float2{ndc.x * 0.5f + 0.5f, 0.5f - ndc.y * 0.5f};

  // How far outside the frame, in frames. A light just past the edge still
  // throws shafts into it — the sun just out of shot is the classic case —
  // but one far outside would have every march sample the same corner.
  const float outside =
      std::max({-out.uv.x, out.uv.x - 1.0f, -out.uv.y, out.uv.y - 1.0f, 0.0f});
  const float onScreen = 1.0f - smoothstep(0.0f, 0.5f, outside);

  // Mitchell's advice: as the view turns perpendicular to the light, its
  // screen position runs off towards infinity and the samples spread
  // uselessly far apart, so fade towards perpendicular. Cosine of the angle
  // between the view's forward (-z) and the light.
  const float facing = float(-view.z);
  const float square = smoothstep(0.0f, 0.35f, facing);

  out.fade = onScreen * square;
  return out;
}

float cloudFactor(float cover) {
  const float c = std::clamp(cover, 0.0f, 1.0f);
  return 1.0f - 0.85f * c * c;
}

int packDistortions(const float *entries, size_t count,
                    const mat4 &viewFromWorld, float4 *out) {
  int packed = 0;
  for (size_t i = 0; i < count && packed < int(kDistortionCapacity); i++) {
    const float *e = entries + i * kDistortionStride;
    const int kind = int(std::lround(e[0]));
    const float strength = e[1];
    const float chromatic = std::isfinite(e[2]) ? e[2] : 0.0f;
    if (strength == 0.0f || !std::isfinite(strength)) continue;

    float4 *row = out + packed * kDistortionRows;
    row[0] = float4{float(kind), strength, chromatic, 0.0f};
    row[1] = float4{0.0f};
    row[2] = float4{0.0f};

    switch (kind) {
      case kDistortionShockwave: {
        const float3 centre = toEffectSpace(viewFromWorld, {e[3], e[4], e[5]});
        const float radius = std::max(e[6], 0.0f);
        const float thickness = std::max(e[7], 1e-3f);
        row[1] = float4{centre, radius};
        row[2] = float4{thickness, 0.0f, 0.0f, 0.0f};
        break;
      }
      case kDistortionHaze: {
        const float3 centre = toEffectSpace(viewFromWorld, {e[3], e[4], e[5]});
        const float3 half{std::max(e[6], 1e-3f), std::max(e[7], 1e-3f),
                          std::max(e[8], 1e-3f)};
        const float scale = std::max(e[9], 1e-3f);
        // How far the pattern has risen: the host's own clock times the
        // speed, so a frame drawn at a given time is always the same frame.
        row[0].w = e[10];
        row[1] = float4{centre, scale};
        row[2] = float4{half, 0.0f};
        break;
      }
      case kDistortionLens:
        break;
      default:
        continue;
    }
    packed++;
  }
  return packed;
}

bool screenEffectPackage(int effect, const uint8_t **package, size_t *length) {
  switch (effect) {
    case kEffectGodRays:
      *package = kgodraysMaterial;
      *length = kgodraysMaterial_len;
      return true;
    case kEffectDistortion:
      *package = kdistortionMaterial;
      *length = kdistortionMaterial_len;
      return true;
    default:
      return false;
  }
}

void ScreenEffects::setGodRays(const float *params, size_t count) {
  _godRays.fill(0.0f);
  // Anything but a whole row is off. A short one would otherwise light the
  // shafts with whatever the missing numbers happened to be left as.
  if (params == nullptr || count != kGodRayStride) return;
  std::copy(params, params + kGodRayStride, _godRays.begin());
}

void ScreenEffects::setDistortions(const float *params, size_t count) {
  _distortions.clear();
  if (params == nullptr) return;
  const size_t whole = count - count % kDistortionStride;
  _distortions.assign(params, params + whole);
}

void ScreenEffects::applyGodRays(MaterialInstance &material,
                                 const Camera &camera, uint32_t width,
                                 uint32_t height, Texture *depth) const {
  const float *g = _godRays.data();
  applyDepth(material, camera, width, height, depth);

  // The light's place on the screen comes from the camera the frame is drawn
  // with, and so does how much of the effect survives it being there.
  SunOnScreen sun;
  if (g[11] > 0.5f) {
    sun = projectSun(camera.getProjectionMatrix(), camera.getViewMatrix(),
                     float3{g[7], g[8], g[9]});
  }
  const float strength =
      std::isfinite(g[0]) ? std::max(g[0], 0.0f) * sun.fade * cloudFactor(g[10])
                          : 0.0f;
  const float3 tint = float3{std::max(g[4], 0.0f), std::max(g[5], 0.0f),
                             std::max(g[6], 0.0f)} *
                      strength;

  material.setParameter("light", sun.uv);
  material.setParameter("tint", tint);
  material.setParameter("decay", std::clamp(g[1], 0.5f, 1.0f));
  material.setParameter("density", std::clamp(g[2], 0.05f, 1.5f));
  material.setParameter("samples",
                        int32_t(std::clamp(std::lround(g[3]), 1L, 128L)));
  material.setParameter("skyDistance", kSkyDistance);
  material.setParameter("glow", kGlow);
}

void ScreenEffects::applyDistortion(MaterialInstance &material,
                                    const Camera &camera, uint32_t width,
                                    uint32_t height, Texture *depth) const {
  applyDepth(material, camera, width, height, depth);

  float4 rows[kDistortionCapacity * kDistortionRows] = {};
  const int count = packDistortions(
      _distortions.data(), _distortions.size() / kDistortionStride,
      camera.getViewMatrix(), rows);
  material.setParameter("rows", rows, kDistortionCapacity * kDistortionRows);
  material.setParameter("count", int32_t(count));
}

}  // namespace orbis
