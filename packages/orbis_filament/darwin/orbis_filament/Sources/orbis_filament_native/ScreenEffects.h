// The arithmetic behind the god-ray and distortion passes, kept apart from the
// Objective-C++ renderer so that every port shares one copy of it.
//
// Plain C++ and Filament's header-only maths, nothing else: the renderer is
// going to Android, Linux, Windows, the web and consoles next, and none of
// this has anything to do with the platform it happens to be drawn on.
#pragma once

#include <math/mat3.h>
#include <math/mat4.h>
#include <math/vec2.h>
#include <math/vec3.h>
#include <math/vec4.h>

#include <cstddef>

namespace orbis {

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
/// so the shader never has to know where the camera is. `worldFromView`
/// receives the rotation back to the world, which is what a heat haze needs
/// to know which way is up.
///
/// Entries that would do nothing — a strength of nought, an unknown kind — are
/// left out, so a scene whose distortions are all at rest packs none and the
/// pass is a straight copy. Returns how many were packed, at most
/// kDistortionCapacity; `out` must hold kDistortionCapacity * kDistortionRows.
int packDistortions(const float *entries, size_t count,
                    const filament::math::mat4 &viewFromWorld,
                    filament::math::float4 *out,
                    filament::math::mat3f *worldFromView);

}  // namespace orbis
