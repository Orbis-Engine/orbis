// Shadows: the rectangle's own depth map, and Filament's shadow settings.
//
// Plain C++ with no Objective-C and nothing from Apple, because this is the
// part of the renderer that is arithmetic rather than platform: where a panel
// stands, what its map's depth means, and which of the pipeline's numbers land
// on which of Filament's fields. Every port needs exactly this and none of it
// should be written twice.
#pragma once

#include <cstddef>
#include <cstdint>

#include <filament/LightManager.h>
#include <filament/View.h>
#include <math/mat4.h>
#include <math/vec3.h>

namespace orbis {

// ---- The pipeline block ----
//
// Where each shadow number sits in the floats `OrbisPipeline.packed` sends.
// The first eighteen are older than this file and are listed for the reader;
// the rest were added with it. A host that sends a shorter block is one from
// before they existed, and gets Filament's own defaults for them.
namespace pipeline {
constexpr size_t kShadowsOn = 0;
constexpr size_t kShadowKind = 1;
constexpr size_t kMapSize = 2;
constexpr size_t kCascades = 3;
constexpr size_t kShadowFar = 4;
constexpr size_t kSplitLambda = 5;
constexpr size_t kConstantBias = 6;
constexpr size_t kNormalBias = 7;
constexpr size_t kShadowFlags = 8;
constexpr size_t kPenumbraScale = 9;
// 10-17 are resolution, multisampling, quality and the light grid.
constexpr size_t kSplits = 18;  // three: 18, 19, 20
constexpr size_t kPenumbraRatioScale = 21;
constexpr size_t kVsmAnisotropy = 22;
constexpr size_t kVsmBlurWidth = 23;
constexpr size_t kVsmLightBleed = 24;
constexpr size_t kVsmSamples = 25;
constexpr size_t kContactDistance = 26;
constexpr size_t kContactSteps = 27;
/// How many floats a current host sends. Kept equal to
/// `OrbisPipeline.stride` by native_contract_test.
constexpr size_t kPipelineStride = 28;

// Bits of kShadowFlags.
constexpr int kStable = 1;
constexpr int kContact = 2;
constexpr int kVsmHighPrecision = 4;
constexpr int kVsmMipmapping = 8;
constexpr int kVsmExponential = 16;
}  // namespace pipeline

/// Whether anything about shadows differs between two pipeline blocks.
///
/// Worth knowing because shadow options live on each light rather than on the
/// view, so a change means walking every light in the scene — and a scene
/// republished on every frame of a drag changes none of them.
bool shadowSettingsDiffer(const float *a, size_t countA, const float *b,
                          size_t countB);

/// The view's half of the shadow settings: on or off, which kind, and the
/// dials the soft and variance kinds have.
void applyViewShadows(filament::View &view, const float *params, size_t count);

/// The light's half: map size, cascades and where they split, biases, how
/// far, stability, contact shadows. Leaves `shadowBulbRadius` alone, because
/// that is a property of the light rather than of the pipeline.
void applyLightShadows(filament::LightManager::ShadowOptions &options,
                       const float *params, size_t count);

// ---- The rectangle's depth map ----

/// Where a casting rectangle's depth map is drawn from.
struct AreaShadowFrame {
  filament::math::float3 eye;
  filament::math::float3 target;
  filament::math::float3 up;
  float near = 0.0f;
  float far = 0.0f;
  float fovDegrees = 0.0f;
  /// tan(fovDegrees / 2), which the shader turns map units into metres by.
  float tanHalf = 0.0f;
};

/// Works out the frustum a panel draws its depth map through. False when the
/// panel has no direction or no reach, and so cannot cast.
bool frameAreaShadow(const filament::math::float3 &centre,
                     filament::math::float3 normal, float width, float height,
                     float falloff, AreaShadowFrame &out);

/// Takes a clip-space position from the projection a camera hands out to the
/// depth Filament actually writes into its buffer.
///
/// `Camera::getProjectionMatrix` is the OpenGL-style projection, z from minus
/// one to one. What lands in the depth buffer is that remapped to nought to
/// one and reversed — Filament does it in every vertex shader, on every
/// backend — so a point projected by the camera's matrix alone is compared in
/// the wrong units against the map. Multiplying by this first puts it in the
/// right ones: with the far plane at infinity, exactly near / distance.
filament::math::mat4f depthFromClip();

/// The four numbers the surface needs besides the matrix: nought when the
/// rectangle does not cast (otherwise tan of half the field of view), the
/// bias in metres, the panel's size in metres, and the near plane.
void packAreaShadowSettings(bool casting, const AreaShadowFrame &frame,
                            float width, float height, float out[4]);

}  // namespace orbis
