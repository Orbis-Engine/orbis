// Projected decals: the part of them that is arithmetic.
//
// Plain C++ with no Objective-C and no Apple API in it, because the renderer
// is going to Android, Linux, Windows, the web and consoles next, and what a
// decal *is* — a box, a picture, and how the two are blended into a surface —
// is the same on all of them. What differs per platform is how an image file
// becomes pixels, and that stays on the platform's side of the line.
#pragma once

#include <cstddef>
#include <cstdint>

namespace orbis {

/// How many floats one decal takes on the wire.
///
/// Must match `OrbisDecal.stride` on the Dart side and `decalStride` in the
/// plugin; native_contract_test reads all three and fails when they drift.
///
///   0-2   where the box's centre is
///   3-6   how it is turned, as a quaternion x, y, z, w
///   7-9   how big it is along its own three axes, in metres
///   10-12 the tint, linear RGB
///   13    opacity
///   14    the angle from the projection axis at which fading starts
///   15    the angle at which it has faded to nothing, both in radians
///   16    the roughness it paints, 17 how much (0 leaves roughness alone)
///   18    the metalness it paints, 19 how much
///   20    which layers receive it, one bit per layer
///   21    its sort order: higher is painted later, so on top
constexpr size_t kDecalStride = 22;

/// How many decals one view paints.
///
/// Every lit fragment walks the list, so this is a cost paid per pixel rather
/// than per decal drawn — there is no culling in front of it. Thirty-two is a
/// street corner's worth of posters, scorches and markings, and a box test
/// that fails is a handful of instructions, so a surface outside all of them
/// pays very little for the loop.
constexpr uint32_t kDecalBudget = 32;

/// How many RGBA float texels one decal occupies in the data texture.
///
///   0-2   the three rows of the matrix that takes a world position into the
///         box, where the box is the cube from -0.5 to 0.5
///   3     tint and opacity
///   4     image layer (-1 for none), cosine of the fade's start, cosine of
///         its end, layer mask
///   5     roughness, how much, metalness, how much
///   6     the projection axis in the world; the first decal's w is the count
constexpr uint32_t kDecalTexels = 7;

/// What packing a frame's decals came to.
struct DecalPacking {
  /// How many were written, which is at most kDecalBudget.
  uint32_t packed = 0;

  /// How many the scene asked for. More than `packed` means some were past
  /// the budget, and the caller reports it rather than dropping them quietly.
  uint32_t asked = 0;
};

/// Writes a frame's decals into the rows the surface shader reads.
///
/// `params` is `count` decals of kDecalStride floats; `layers` is `count`
/// image-array layers, -1 for a decal with no picture. `out` must hold
/// kDecalBudget * kDecalTexels * 4 floats and is filled in full, zeros past
/// the last decal, so the caller can compare it against what the GPU already
/// holds and skip an upload that would change nothing.
///
/// The first kDecalBudget in the order given are kept, then sorted by their
/// sort order — stably, so two decals at the same order keep the order they
/// were listed in, and a scene that does not care about ordering gets the
/// order it wrote.
DecalPacking packDecals(const float *params, const int32_t *layers,
                        uint32_t count, float *out);

}  // namespace orbis
