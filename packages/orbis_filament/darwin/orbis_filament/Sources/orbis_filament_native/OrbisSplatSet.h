// Gaussian splats as Filament draws them.
//
// C++ against Filament's public API and nothing else, so it moves to every
// backend Filament has without change. The .mm owns one SplatScene and calls
// it from the scene message and once a frame; everything about textures,
// buffers and sorting is here.
#pragma once

#include "OrbisSplats.h"

#include <filament/Engine.h>
#include <filament/IndexBuffer.h>
#include <filament/Material.h>
#include <filament/MaterialInstance.h>
#include <filament/Scene.h>
#include <filament/Texture.h>
#include <filament/VertexBuffer.h>
#include <math/vec3.h>
#include <utils/Entity.h>

#include <memory>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace orbis {

/// One cloud: its data on the GPU, its renderable, and its sorter.
class SplatSet {
 public:
  SplatSet(filament::Engine &engine, filament::Scene &scene,
           filament::Material &material, SplatCloud &&cloud);
  ~SplatSet();

  SplatSet(const SplatSet &) = delete;
  SplatSet &operator=(const SplatSet &) = delete;

  /// Column-major, model to world.
  void setTransform(const float matrix[16]);
  void setOpacity(float opacity);
  void setBrightness(float brightness);

  /// Off draws the splats in the order they were given, for measuring what
  /// the sort is worth. On is the only right answer for a picture.
  void setSorted(bool sorted);

  /// Once a frame, with the camera's forward vector in world space: asks for
  /// a new order when the view has turned far enough to change one, and
  /// uploads any order that has finished.
  void update(const filament::math::float3 &forward);

  uint32_t count() const { return _count; }
  double lastSortMilliseconds() const { return _lastSortMs; }

 private:
  void uploadOrder(const std::vector<uint32_t> &order);

  filament::Engine &_engine;
  filament::Scene &_scene;
  uint32_t _count = 0;

  filament::Texture *_splats = nullptr;
  filament::Texture *_order = nullptr;
  /// The higher spherical-harmonic bands, or a single texel standing in for
  /// them when the cloud has none: a material's sampler has to be bound
  /// whether or not the shader ever reads it.
  filament::Texture *_harmonics = nullptr;
  filament::VertexBuffer *_corners = nullptr;
  filament::IndexBuffer *_indices = nullptr;
  filament::MaterialInstance *_instance = nullptr;
  utils::Entity _entity;

  std::unique_ptr<SplatSorter> _sorter;
  float _matrix[16] = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
  bool _sorted = true;
  /// Whether the order on the GPU is the given one rather than a sort.
  bool _showingGiven = true;
  bool _everSorted = false;
  /// The model-space direction the order on the GPU, or on its way, was
  /// sorted along.
  filament::math::float3 _sortedAlong{0, 0, 0};
  double _lastSortMs = 0;
  uint32_t _sortsLanded = 0;
  bool _warnedDegenerate = false;
};

/// What the scene says about one cloud this frame.
struct SplatRequest {
  int32_t key = 0;
  int32_t flags = 0;
  int32_t revision = 0;
  const float *params = nullptr;  // kSplatParams floats
  std::string path;               // empty for a cloud sent in memory
  const uint8_t *data = nullptr;  // records, when they came with the message
  size_t bytes = 0;
};

/// Every cloud in a scene, kept by key between messages.
class SplatScene {
 public:
  SplatScene(filament::Engine &engine, filament::Scene &scene);
  ~SplatScene();

  /// The complete list, as every scene message states it. Clouds not named
  /// are removed. What could not be loaded is reported in `notes` as pairs
  /// of what it was and why.
  void apply(const std::vector<SplatRequest> &requests,
             std::vector<std::pair<std::string, std::string>> &notes);

  void update(const filament::math::float3 &forward);

  bool empty() const { return _sets.empty(); }
  void clear();

 private:
  struct Kept {
    std::unique_ptr<SplatSet> set;
    std::string path;
    int32_t revision = 0;
    /// The spherical-harmonic degree this one was read at. Kept because
    /// asking for a different one means reading the file again: what was
    /// dropped on the way in is not on the GPU to be brought back.
    uint32_t degree = 0;
    uint64_t seen = 0;
  };

  filament::Engine &_engine;
  filament::Scene &_scene;
  filament::Material *_material = nullptr;
  std::unordered_map<int32_t, Kept> _sets;
  uint64_t _generation = 0;
};

}  // namespace orbis
