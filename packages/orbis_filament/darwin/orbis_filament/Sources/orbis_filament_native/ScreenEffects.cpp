#include "ScreenEffects.h"

#include <algorithm>
#include <cmath>

namespace orbis {

using filament::math::float2;
using filament::math::float3;
using filament::math::float4;
using filament::math::mat3f;
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
float3 toEffectSpace(const mat4 &viewFromWorld, float3 world, double w) {
  const auto v = viewFromWorld * filament::math::double4(world, w);
  return float3{float(v.x), float(v.y), float(-v.z)};
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
  const auto view = viewFromWorld * filament::math::double4(toward, 0.0);
  const auto clip = clipFromView * view;

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
                    const mat4 &viewFromWorld, float4 *out,
                    mat3f *worldFromView) {
  // The rotation from the effect space back to the world: the transpose of
  // the view's rotation, with the z turned round to match toEffectSpace.
  mat3f rotation;
  for (int column = 0; column < 3; column++) {
    for (int row = 0; row < 3; row++) {
      // viewFromWorld[column][row] is row `row` of column `column`, and the
      // transpose swaps them. Row 2 of the view picks up the flip.
      const float flip = column == 2 ? -1.0f : 1.0f;
      rotation[row][column] = float(viewFromWorld[row][column]) * flip;
    }
  }
  if (worldFromView != nullptr) *worldFromView = rotation;

  int packed = 0;
  for (size_t i = 0; i < count && packed < int(kDistortionCapacity); i++) {
    const float *e = entries + i * kDistortionStride;
    const int kind = int(std::lround(e[0]));
    const float strength = e[1];
    const float chromatic = e[2];
    if (strength == 0.0f || !std::isfinite(strength)) continue;

    float4 *row = out + packed * kDistortionRows;
    row[0] = float4{float(kind), strength, chromatic, 0.0f};
    row[1] = float4{0.0f};
    row[2] = float4{0.0f};

    switch (kind) {
      case kDistortionShockwave: {
        const float3 centre = toEffectSpace(viewFromWorld, {e[3], e[4], e[5]}, 1.0);
        const float radius = std::max(e[6], 0.0f);
        const float thickness = std::max(e[7], 1e-3f);
        row[1] = float4{centre, radius};
        row[2] = float4{thickness, 0.0f, 0.0f, 0.0f};
        break;
      }
      case kDistortionHaze: {
        const float3 centre = toEffectSpace(viewFromWorld, {e[3], e[4], e[5]}, 1.0);
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

}  // namespace orbis
