#include "OrbisShadows.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace orbis {

using filament::LightManager;
using filament::View;
using filament::math::float3;
using filament::math::mat4f;

namespace {

/// A number from the block if the host sent it, the fallback if it did not.
float at(const float *params, size_t count, size_t index, float fallback) {
  return index < count ? params[index] : fallback;
}

}  // namespace

bool shadowSettingsDiffer(const float *a, size_t countA, const float *b,
                          size_t countB) {
  if (countA != countB) return true;
  const size_t head = std::min<size_t>(countA, pipeline::kPenumbraScale + 1);
  if (std::memcmp(a, b, sizeof(float) * head) != 0) return true;
  if (countA > pipeline::kSplits) {
    const size_t tail = countA - pipeline::kSplits;
    if (std::memcmp(a + pipeline::kSplits, b + pipeline::kSplits,
                    sizeof(float) * tail) != 0) {
      return true;
    }
  }
  return false;
}

void applyViewShadows(View &view, const float *params, size_t count) {
  using namespace pipeline;
  view.setShadowingEnabled(at(params, count, kShadowsOn, 1.0f) != 0.0f);

  switch (static_cast<int>(at(params, count, kShadowKind, 0.0f))) {
    case 1:
      // Asked for by name even though Filament 1.76 marks DPCF deprecated and
      // serves it with PCSS — measured byte-identical to case 2 across a
      // whole frame. Still worth asking for what is meant: the host's "Soft"
      // is a statement about the edge, not about the technique, and the day
      // Filament brings the cheaper path back this is where it arrives.
      view.setShadowType(filament::ShadowType::DPCF);
      break;
    case 2:
      view.setShadowType(filament::ShadowType::PCSS);
      break;
    case 3:
      view.setShadowType(filament::ShadowType::VSM);
      break;
    default:
      view.setShadowType(filament::ShadowType::PCF);
      break;
  }

  // Read by the two kinds whose penumbra is worked out rather than fixed.
  // The scale widens every penumbra; the ratio scale widens the ones far from
  // what casts them more than the ones near it, which is the dial for how
  // "contact-hardening" the shadow looks.
  filament::SoftShadowOptions soft;
  soft.penumbraScale = at(params, count, kPenumbraScale, 1.0f);
  soft.penumbraRatioScale = at(params, count, kPenumbraRatioScale, 1.0f);
  if (soft.penumbraRatioScale <= 0.0f) soft.penumbraRatioScale = 1.0f;
  view.setSoftShadowOptions(soft);

  // Read only by variance shadows. Every default here is Filament's own, so
  // a block from before these existed changes nothing.
  const int flags = static_cast<int>(at(params, count, kShadowFlags, 0.0f));
  filament::VsmShadowOptions vsm;
  vsm.anisotropy = static_cast<uint8_t>(
      std::clamp(at(params, count, kVsmAnisotropy, 0.0f), 0.0f, 4.0f));
  vsm.mipmapping = (flags & kVsmMipmapping) != 0;
  vsm.highPrecision = (flags & kVsmHighPrecision) != 0;
  const float samples = at(params, count, kVsmSamples, 1.0f);
  vsm.msaaSamples = static_cast<uint8_t>(samples >= 4.0f   ? 4
                                         : samples >= 2.0f ? 2
                                                           : 1);
  vsm.lightBleedReduction =
      std::clamp(at(params, count, kVsmLightBleed, 0.15f), 0.0f, 1.0f);
  // `minVarianceScale` is deliberately left at Filament's default: 1.76 marks
  // it deprecated and states it has no effect, so there is nothing to send.
  view.setVsmShadowOptions(vsm);
}

void applyLightShadows(LightManager::ShadowOptions &options,
                       const float *params, size_t count) {
  using namespace pipeline;
  options.mapSize =
      static_cast<uint32_t>(std::max(at(params, count, kMapSize, 1024), 8.0f));
  const int cascades = static_cast<int>(at(params, count, kCascades, 1));
  options.shadowCascades = static_cast<uint8_t>(std::clamp(cascades, 1, 4));

  // Zero means "as far as the camera sees", and that is a reasonable thing to
  // ask for — but it was only half honoured once. The cascade splits fell
  // back to a hundred metres when it was zero while shadowFar stayed zero, so
  // the splits described one distance and the shadow described another, and
  // every surface sampled as shadowed. One fallback, used by both.
  constexpr float kDefaultShadowFar = 100.0f;
  const float far = at(params, count, kShadowFar, 0.0f);
  const float shadowFar = far > 0.0f ? far : kDefaultShadowFar;
  options.shadowFar = shadowFar;
  options.constantBias = at(params, count, kConstantBias, 0.001f);
  options.normalBias = at(params, count, kNormalBias, 1.0f);

  const int flags = static_cast<int>(at(params, count, kShadowFlags, 0.0f));
  options.stable = (flags & kStable) != 0;
  options.screenSpaceContactShadows = (flags & kContact) != 0;
  // How far a contact shadow is traced, and in how many steps. Longer finds
  // more and misses thin things between the steps; more steps costs more.
  const float contact = at(params, count, kContactDistance, 0.0f);
  options.maxShadowDistance = contact > 0.0f ? contact : 0.3f;
  const float steps = at(params, count, kContactSteps, 0.0f);
  options.stepCount =
      static_cast<uint8_t>(steps >= 1.0f ? std::min(steps, 255.0f) : 8.0f);
  options.vsm.elvsm = (flags & kVsmExponential) != 0;
  options.vsm.blurWidth =
      std::max(at(params, count, kVsmBlurWidth, 0.0f), 0.0f);

  // Where each cascade hands over to the next. Given outright when the host
  // gives them — a rising run of fractions of the shadow distance — and
  // otherwise the practical split, which is the usual compromise: evenly
  // spaced wastes the near cascades on ground the camera is standing on, and
  // logarithmic wastes the far ones on sky.
  if (options.shadowCascades > 1) {
    const int wanted = options.shadowCascades - 1;
    bool given = count > kSplits + wanted - 1;
    float previous = 0.0f;
    for (int i = 0; given && i < wanted; i++) {
      const float split = params[kSplits + i];
      if (!(split > previous && split < 1.0f)) given = false;
      previous = split;
    }
    if (given) {
      for (int i = 0; i < wanted; i++) {
        options.cascadeSplitPositions[i] = params[kSplits + i];
      }
    } else {
      LightManager::ShadowCascades::computePracticalSplits(
          options.cascadeSplitPositions, options.shadowCascades, 0.1f,
          shadowFar, at(params, count, kSplitLambda, 0.5f));
    }
  }
}

bool frameAreaShadow(const float3 &centre, float3 normal, float width,
                     float height, float falloff, AreaShadowFrame &out) {
  if (length(normal) < 1e-6f) return false;
  normal = normalize(normal);
  width = std::max(width, 1e-4f);
  height = std::max(height, 1e-4f);

  // How far it is worth looking. The window the shader applies already stops
  // the light at the falloff, so anything past it is out of the picture
  // whatever the map says.
  const float reach = falloff > 1e-3f ? falloff : 40.0f;

  // Near is set off the panel's own size rather than at some fixed epsilon:
  // depth precision is spent between near and far, and a near plane a
  // thousandth of the far one throws most of it away for a light whose
  // nearest interesting occluder is a pace in front of it.
  const float near = std::max(0.05f, std::max(width, height) * 0.05f);
  if (reach <= near) return false;

  // A hundred and twenty degrees, fixed.
  //
  // A panel lights the whole hemisphere in front of it and one perspective
  // map cannot hold a hemisphere, so this is a choice about where to spend
  // the pixels rather than a measurement. Wider than this and the map is all
  // distortion at the edges where nothing needs it; narrower and a surface
  // off to one side falls outside and is declared unshadowed — which is the
  // safe failure, because it keeps the light it would have had.
  //
  // Deriving it from the panel's size was tried first and was wrong: a
  // two-metre softbox came out at a hundred and seventy degrees, very nearly
  // a hemisphere squeezed into a square.
  constexpr float kFov = 120.0f;

  // A panel emits along its normal, so that is where it looks. Any up will do
  // as long as it is not the direction of travel.
  out.eye = centre;
  out.target = centre + normal * reach;
  out.up = std::abs(normal.y) > 0.9f ? float3{1, 0, 0} : float3{0, 1, 0};
  out.near = near;
  out.far = reach;
  out.fovDegrees = kFov;
  out.tanHalf = std::tan(kFov * 0.5f * float(M_PI) / 180.0f);
  return true;
}

mat4f depthFromClip() {
  // z' = -z/2 + w/2, which after the divide is (1 - z/w) / 2: minus one at
  // the near plane becomes one, and one at the far plane becomes nought.
  mat4f m;  // identity
  m[2][2] = -0.5f;
  m[3][2] = 0.5f;
  return m;
}

void packAreaShadowSettings(bool casting, const AreaShadowFrame &frame,
                            float width, float height, float out[4]) {
  // Doubles as the flag: nought is "does not cast", and a real tangent of
  // half of a hundred and twenty degrees is never nought.
  out[0] = casting ? frame.tanHalf : 0.0f;
  // Three centimetres. The comparison is between distances along the same
  // ray, so this is how far a surface has to be behind what the panel saw
  // before it counts as behind it — acne below it, a shadow detached from
  // its caster well above it. The slope term in the shader does the rest.
  out[1] = 0.03f;
  // The panel's size, which is what the penumbra is made from. The mean of
  // the two edges: a strip light is softer along its length than across it,
  // and one number per light is a compromise that errs neither way.
  out[2] = 0.5f * (std::max(width, 1e-4f) + std::max(height, 1e-4f));
  out[3] = casting ? frame.near : 0.0f;
}

}  // namespace orbis
