#include "OrbisDecals.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>

namespace orbis {

namespace {

constexpr float kPi = 3.14159265358979f;

/// One decal's rows, written into `row`.
///
/// The shader wants the inverse of the box's placement — world to box, not
/// box to world — because what it has is a world position and what it needs
/// to know is where in the box that is. A general 4x4 inverse would do, but
/// the placement is built out of a rotation and a scale and nothing else, so
/// its inverse is the rotation's transpose divided by the scale: exact, and
/// with no determinant to go to nought on a decal that is flat in one axis.
void packOne(const float *p, int32_t layer, float *row) {
  const float px = p[0], py = p[1], pz = p[2];

  // Normalised here rather than trusted: a quaternion that has drifted off
  // unit length through a few hundred editor drags is a rotation that also
  // scales, and the box it describes is not the one on screen.
  float qx = p[3], qy = p[4], qz = p[5], qw = p[6];
  const float length = std::sqrt(qx * qx + qy * qy + qz * qz + qw * qw);
  if (length > 1e-8f) {
    qx /= length;
    qy /= length;
    qz /= length;
    qw /= length;
  } else {
    qx = qy = qz = 0.0f;
    qw = 1.0f;
  }

  // The rotation's three columns: where the box's own x, y and z point in
  // the world.
  const float axes[3][3] = {
      {1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy + qz * qw),
       2 * (qx * qz - qy * qw)},
      {2 * (qx * qy - qz * qw), 1 - 2 * (qx * qx + qz * qz),
       2 * (qy * qz + qx * qw)},
      {2 * (qx * qz + qy * qw), 2 * (qy * qz - qx * qw),
       1 - 2 * (qx * qx + qy * qy)},
  };

  // A box with no depth catches nothing, and dividing by it is infinity in
  // the shader. A tenth of a millimetre is thinner than anything visible and
  // still a number.
  const float size[3] = {std::max(std::abs(p[7]), 1e-4f),
                         std::max(std::abs(p[8]), 1e-4f),
                         std::max(std::abs(p[9]), 1e-4f)};

  for (int i = 0; i < 3; i++) {
    const float *axis = axes[i];
    row[i * 4 + 0] = axis[0] / size[i];
    row[i * 4 + 1] = axis[1] / size[i];
    row[i * 4 + 2] = axis[2] / size[i];
    row[i * 4 + 3] = -(axis[0] * px + axis[1] * py + axis[2] * pz) / size[i];
  }

  // Tint and opacity, clamped: an opacity past one paints the decal over the
  // surface by more than all of it, which the blend turns into a negative
  // amount of the surface underneath.
  row[12] = std::max(p[10], 0.0f);
  row[13] = std::max(p[11], 0.0f);
  row[14] = std::max(p[12], 0.0f);
  row[15] = std::min(std::max(p[13], 0.0f), 1.0f);

  // The fade, as cosines, so the shader compares a dot product it already has
  // rather than taking an arc cosine per fragment. Ordered, because a start
  // past the end is a fade that runs backwards.
  const float start = std::min(std::max(p[14], 0.0f), kPi);
  const float end = std::min(std::max(p[15], start), kPi);
  row[16] = float(layer);
  row[17] = std::cos(start);
  row[18] = std::cos(end);
  // Seven layers, the same seven an object can be on. Carried as a float
  // because the texture is float; the shader turns it back into bits, and
  // every integer up to 2^24 survives the trip exactly.
  row[19] = float(int32_t(p[20]) & 0x7F);

  row[20] = std::min(std::max(p[16], 0.0f), 1.0f);
  row[21] = std::min(std::max(p[17], 0.0f), 1.0f);
  row[22] = std::min(std::max(p[18], 0.0f), 1.0f);
  row[23] = std::min(std::max(p[19], 0.0f), 1.0f);

  // Which way the decal is projected: along the box's own y, towards minus.
  // A surface facing back along plus y is square to the projector and takes
  // the whole picture; one turned away from it takes less, which is the angle
  // fade.
  row[24] = axes[1][0];
  row[25] = axes[1][1];
  row[26] = axes[1][2];
  row[27] = 0.0f;
}

}  // namespace

DecalPacking packDecals(const float *params, const int32_t *layers,
                        uint32_t count, float *out) {
  const size_t rowFloats = size_t(kDecalTexels) * 4;
  std::memset(out, 0, sizeof(float) * rowFloats * kDecalBudget);

  DecalPacking result;
  result.asked = count;
  const uint32_t kept = std::min(count, kDecalBudget);

  std::vector<uint32_t> order(kept);
  for (uint32_t i = 0; i < kept; i++) order[i] = i;
  std::stable_sort(order.begin(), order.end(), [&](uint32_t a, uint32_t b) {
    return params[size_t(a) * kDecalStride + 21] <
           params[size_t(b) * kDecalStride + 21];
  });

  for (uint32_t slot = 0; slot < kept; slot++) {
    const uint32_t i = order[slot];
    packOne(params + size_t(i) * kDecalStride, layers[i],
            out + size_t(slot) * rowFloats);
  }

  // How many, in the first decal's spare channel. The same trick the area
  // lights use: the count cannot fall out of step with the data because it is
  // the data, and with no decals the whole texture is zeros, which reads as a
  // count of nought without a special case.
  out[kDecalTexels * 4 - 1] = float(kept);
  result.packed = kept;
  return result;
}

}  // namespace orbis
