// God rays and screen distortion: the arithmetic, and the parameters the two
// effect materials read.
//
// Kept apart from the Objective-C++ renderer so every port shares one copy of
// it. Plain C++ and Filament's public API, nothing else: the renderer is going
// to Android, Linux, Windows, the web and consoles, and none of this has
// anything to do with the platform it happens to be drawn on. What the
// renderer itself does is small — keep one of these, hand it what the host
// sent, and call it while setting up an effect pass. Every place it does is
// marked "Hook (screen effects)" in OrbisRenderer.mm.
#pragma once

#include <filament/Camera.h>
#include <filament/MaterialInstance.h>
#include <filament/Texture.h>

#include <math/mat4.h>
#include <math/vec2.h>
#include <math/vec3.h>
#include <math/vec4.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace orbis {

/// The two effects' numbers, matching OrbisEffect on the Dart side. They
/// continue the renderer's own list — sharpen is nought, copy is five.
constexpr int kEffectGodRays = 6;
constexpr int kEffectDistortion = 7;

/// How many floats the god-ray settings take on the wire. Must match
/// OrbisGodRays.stride on the Dart side and the plugin's own check.
constexpr size_t kGodRayStride = 12;

/// How many floats one distortion takes on the wire. Must match
/// OrbisDistortion.stride on the Dart side and the plugin's own check.
constexpr size_t kDistortionStride = 12;

/// The most distortions one frame draws. The shader's loop is bounded by it,
/// so a scene asking for more has the extras dropped rather than read past
/// the end of an array.
constexpr size_t kDistortionCapacity = 8;

/// Each distortion goes to the shader as three four-wide rows.
constexpr size_t kDistortionRows = 3;

/// The kinds, matching OrbisDistortionKind's order.
constexpr int kDistortionShockwave = 1;
constexpr int kDistortionHaze = 2;
constexpr int kDistortionLens = 3;

/// Where the light is on the screen, and how much of the effect survives the
/// light being where it is.
struct SunOnScreen {
  /// Texture coordinates: nought to one across, nought at the top.
  filament::math::float2 uv = {0.5f, 0.5f};
  /// One with the light well inside the frame, falling to nought as it leaves
  /// the frame or turns side-on, and nought behind the camera.
  float fade = 0.0f;
};

/// Projects a direction — towards the sun or the moon — onto the screen.
///
/// A direction rather than a point, because the sun is infinitely far away:
/// the point projected is the one at infinity, which is what makes the shafts
/// converge in the same place however the camera is moved about.
SunOnScreen projectSun(const filament::math::mat4 &clipFromView,
                       const filament::math::mat4 &viewFromWorld,
                       filament::math::float3 towardLight);

/// How much of the shafts cloud leaves, for a cover of nought to one.
///
/// Scattered light needs a light to scatter, and overcast is the sun spread
/// across the whole sky with nothing to make a shaft from. Never quite nought:
/// broken cloud is exactly when shafts are seen most.
float cloudFactor(float cover);

/// Turns the scene's distortions, in the world, into what the shader reads.
///
/// `entries` is `count` rows of kDistortionStride. Positions come out in the
/// space the effect passes reconstruct from depth — x right, y up, and +z
/// *into* the screen, which is Filament's view space with z turned round —
/// so the shader never has to know where the camera is.
///
/// Entries that would do nothing — a strength of nought, an unknown kind — are
/// left out, so a scene whose distortions are all at rest packs none and the
/// pass is a straight copy. Returns how many were packed, at most
/// kDistortionCapacity; `out` must hold kDistortionCapacity * kDistortionRows.
int packDistortions(const float *entries, size_t count,
                    const filament::math::mat4 &viewFromWorld,
                    filament::math::float4 *out);

/// The compiled material for one of the two effects, as setup.sh built it.
///
/// Here rather than in the renderer so the generated headers are included in
/// exactly one place: they define their arrays with external linkage, and a
/// second file including one is a duplicate symbol at link time.
bool screenEffectPackage(int effect, const uint8_t **package, size_t *length);

/// What the host said about god rays and distortion, kept between frames,
/// and turned into material parameters when an effect pass runs.
///
/// Kept rather than applied on arrival because the parts that matter most are
/// worked out from the camera, and the renderer moves its camera between
/// messages — it predicts where the host's camera is going. The sun's place
/// on the screen has to come from the camera the frame is drawn with, or the
/// shafts would trail a frame behind every turn of the head.
class ScreenEffects {
 public:
  /// The god-ray settings, kGodRayStride floats. Anything else is off.
  void setGodRays(const float *params, size_t count);

  /// Every distortion, count * kDistortionStride floats.
  void setDistortions(const float *params, size_t count);

  /// Sets everything the god-ray material reads apart from its source.
  ///
  /// `camera` is the scene's camera, not the effect pass's own — the one
  /// whose projection made the depth being read.
  void applyGodRays(filament::MaterialInstance &material,
                    const filament::Camera &camera, uint32_t width,
                    uint32_t height, filament::Texture *depth) const;

  /// Sets everything the distortion material reads apart from its source.
  void applyDistortion(filament::MaterialInstance &material,
                       const filament::Camera &camera, uint32_t width,
                       uint32_t height, filament::Texture *depth) const;

 private:
  std::array<float, kGodRayStride> _godRays{};
  std::vector<float> _distortions;
};

}  // namespace orbis
