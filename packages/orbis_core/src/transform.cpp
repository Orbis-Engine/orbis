// Deriving world transforms from a parent link.
//
// The hierarchy is data, not structure: an entity carries its parent's handle
// and the engine resolves the chain. That keeps the archetype store free of any
// notion of a tree, and means reparenting is a component write rather than a
// move through a graph.

#include <cmath>
#include <cstring>
#include <unordered_map>
#include <vector>

#include "orbis_core.h"
#include "world.h"

namespace orbis {
namespace {

constexpr const char *kLocalName = "orbis.LocalTransform";
constexpr const char *kWorldName = "orbis.WorldTransform";
constexpr const char *kParentName = "orbis.Parent";

constexpr uint32_t kLocalFloats = 10;  // 3 translation, 4 rotation, 3 scale
constexpr uint32_t kWorldFloats = 16;

/// Guards against a parent chain that loops back on itself. Deeper than any
/// real scene, shallow enough that a cycle terminates immediately.
constexpr int kMaxDepth = 256;

void identity(float *m) {
  std::memset(m, 0, sizeof(float) * 16);
  m[0] = m[5] = m[10] = m[15] = 1.0f;
}

/// Column-major, matching glTF and Filament, so a matrix produced here can be
/// handed to either without a transpose.
void compose(const float *trs, float *m) {
  const float tx = trs[0], ty = trs[1], tz = trs[2];
  const float x = trs[3], y = trs[4], z = trs[5], w = trs[6];
  const float sx = trs[7], sy = trs[8], sz = trs[9];

  const float xx = x * x, yy = y * y, zz = z * z;
  const float xy = x * y, xz = x * z, yz = y * z;
  const float wx = w * x, wy = w * y, wz = w * z;

  m[0] = (1.0f - 2.0f * (yy + zz)) * sx;
  m[1] = (2.0f * (xy + wz)) * sx;
  m[2] = (2.0f * (xz - wy)) * sx;
  m[3] = 0.0f;

  m[4] = (2.0f * (xy - wz)) * sy;
  m[5] = (1.0f - 2.0f * (xx + zz)) * sy;
  m[6] = (2.0f * (yz + wx)) * sy;
  m[7] = 0.0f;

  m[8] = (2.0f * (xz + wy)) * sz;
  m[9] = (2.0f * (yz - wx)) * sz;
  m[10] = (1.0f - 2.0f * (xx + yy)) * sz;
  m[11] = 0.0f;

  m[12] = tx;
  m[13] = ty;
  m[14] = tz;
  m[15] = 1.0f;
}

void multiply(const float *a, const float *b, float *out) {
  for (int column = 0; column < 4; column++) {
    for (int row = 0; row < 4; row++) {
      float sum = 0.0f;
      for (int k = 0; k < 4; k++) {
        sum += a[k * 4 + row] * b[column * 4 + k];
      }
      out[column * 4 + row] = sum;
    }
  }
}

/// Resolves one entity's world matrix, resolving its ancestors on the way and
/// remembering each, so a chain shared by many children is walked once.
const float *resolve(World &world, OrbisEntity entity,
                     const OrbisTransforms &ids,
                     std::unordered_map<OrbisEntity, std::vector<float>> &done,
                     int depth) {
  auto existing = done.find(entity);
  if (existing != done.end()) return existing->second.data();

  auto *local = static_cast<const float *>(
      world.getComponent(entity, ids.local));
  std::vector<float> matrix(kWorldFloats);
  if (local == nullptr) {
    identity(matrix.data());
  } else {
    compose(local, matrix.data());
  }

  auto *parent =
      static_cast<const OrbisEntity *>(world.getComponent(entity, ids.parent));
  if (parent != nullptr && *parent != 0 && depth < kMaxDepth &&
      world.alive(*parent)) {
    // Inserted before recursing so a cycle finds a partial answer rather than
    // recursing forever; the guard above bounds it either way.
    const float *parentMatrix = resolve(world, *parent, ids, done, depth + 1);
    std::vector<float> combined(kWorldFloats);
    multiply(parentMatrix, matrix.data(), combined.data());
    matrix.swap(combined);
  }

  auto inserted = done.emplace(entity, std::move(matrix));
  return inserted.first->second.data();
}

}  // namespace
}  // namespace orbis

extern "C" {

OrbisTransforms orbis_transform_register(OrbisWorld *handle) {
  auto *world = reinterpret_cast<orbis::World *>(handle);
  OrbisTransforms ids;
  ids.local = world->registerComponent(
      orbis::kLocalName, sizeof(float) * orbis::kLocalFloats, alignof(float));
  ids.world = world->registerComponent(
      orbis::kWorldName, sizeof(float) * orbis::kWorldFloats, alignof(float));
  ids.parent = world->registerComponent(orbis::kParentName,
                                        sizeof(OrbisEntity), alignof(uint64_t));
  return ids;
}

void orbis_transform_compose(const float *trs, float *out) {
  if (trs == nullptr || out == nullptr) return;
  orbis::compose(trs, out);
}

uint32_t orbis_transform_propagate(OrbisWorld *handle) {
  auto *world = reinterpret_cast<orbis::World *>(handle);
  const OrbisComponent local = world->lookupComponent(orbis::kLocalName);
  const OrbisComponent worldId = world->lookupComponent(orbis::kWorldName);
  const OrbisComponent parent = world->lookupComponent(orbis::kParentName);
  if (local == 0 || worldId == 0) return 0;

  OrbisTransforms ids{local, worldId, parent};
  std::unordered_map<OrbisEntity, std::vector<float>> resolved;

  // Only entities that have somewhere to put the answer are visited.
  const OrbisComponent wanted[2] = {local, worldId};
  OrbisQuery *query = orbis_query_create(handle, wanted, 2);

  uint32_t written = 0;
  const uint32_t chunks = orbis_query_chunk_count(query);
  for (uint32_t chunk = 0; chunk < chunks; chunk++) {
    const uint32_t length = orbis_query_chunk_length(query, chunk);
    const OrbisEntity *entities = orbis_query_chunk_entities(query, chunk);
    auto *out = static_cast<float *>(
        orbis_query_chunk_column(query, chunk, 1));

    for (uint32_t row = 0; row < length; row++) {
      const float *matrix =
          orbis::resolve(*world, entities[row], ids, resolved, 0);
      std::memcpy(out + row * orbis::kWorldFloats, matrix,
                  sizeof(float) * orbis::kWorldFloats);
      written++;
    }
  }

  orbis_query_destroy(query);
  return written;
}

}  // extern "C"
