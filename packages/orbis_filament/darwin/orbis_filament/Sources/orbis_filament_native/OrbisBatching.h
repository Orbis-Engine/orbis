// Automatic batching: which objects are the same thing drawn more than once.
//
// Plain C++ with no Filament and no Apple in it, because the decision is
// arithmetic and the renderer is about to be ported to four more platforms.
// The .mm asks the questions and acts on the answers; nothing here knows what
// a material instance is beyond an opaque pointer it is handed.
//
// What batching *is*, in this renderer: Filament can already merge draws that
// use the same geometry and the same material instance into one instanced
// draw, carrying each copy's own transform in a per-instance block. It is off
// by default, and it would do almost nothing if switched on here, because
// Orbis gives every placeholder cube its own material instance (the colour is
// a parameter on it) and gltfio gives every copy of a model its own set. Two
// crates that look identical are, as far as Filament can tell, made of
// different things.
//
// So the work is to notice that they are not, and let them share. That is
// this file. The objects stay separate renderables — so a transform written
// to one of them moves that one and nothing else, and picking, culling and
// layers behave exactly as they did — and only what they are made of is
// pooled.
//
// Two kinds of object can be made to share, and they need different amounts
// of help:
//
//  * A placeholder cube wears one material instance of its own, holding its
//    colour. Cubes of the same colour are given one pooled instance between
//    them; each keeps its own, unwritten, so leaving a batch is a pointer put
//    back rather than anything rebuilt.
//  * An object wearing a named Orbis material already shares that material's
//    single instance with everything else made of it. Nothing has to be
//    arranged for it at all — it merges the moment the engine is told to
//    merge — so it is counted here and then left alone.
//
// A model wearing its own file's materials is the case deliberately left out.
// gltfio hands every copy its own instances, so merging them would mean
// dressing every copy in the first copy's, which changes what the others are
// made of rather than only how they are drawn; and it cannot be shown to draw
// the same picture without a model file, which this repository does not have.
// Give such a model a named material and it batches like anything else.
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <map>
#include <unordered_map>
#include <vector>

namespace orbis {

/// The fewest copies worth sharing a surface between.
///
/// Four rather than two. Below that the merged draw saves one or two calls
/// and costs a re-dress every time the group's membership wobbles across the
/// line; above it the saving is linear in the count and the re-dress happens
/// once. Filament merges any two draws it can once they share, so this only
/// decides when Orbis goes to the trouble of making them share.
constexpr uint32_t kBatchMinimum = 4;

/// What makes two objects the same draw.
///
/// The mesh and the named material are obvious. The colour only counts where
/// it decides the look — a placeholder cube on the default surface, whose
/// colour is a parameter on its material — and is left at zero otherwise, so
/// a hundred copies of a model tinted by a swatch the model ignores still
/// batch. The flags are in because an object that casts and one that does not
/// are in different passes, and one on another layer is drawn by another pass
/// entirely; grouping them would count a merge that cannot happen.
struct BatchKey {
  int32_t mesh = -1;
  int32_t surface = -1;
  std::array<uint32_t, 3> colour{0, 0, 0};
  int32_t flags = 0;

  bool operator==(const BatchKey &other) const noexcept {
    return mesh == other.mesh && surface == other.surface &&
           colour == other.colour && flags == other.flags;
  }
};

struct BatchKeyHash {
  size_t operator()(const BatchKey &key) const noexcept {
    // FNV-1a over the four fields. Nothing clever is needed: the keys of one
    // scene are few and the map is rebuilt every publish.
    uint64_t hash = 1469598103934665603ull;
    auto mix = [&hash](uint32_t value) {
      for (int i = 0; i < 4; i++) {
        hash ^= (value >> (i * 8)) & 0xFF;
        hash *= 1099511628211ull;
      }
    };
    mix(uint32_t(key.mesh));
    mix(uint32_t(key.surface));
    mix(key.colour[0]);
    mix(key.colour[1]);
    mix(key.colour[2]);
    mix(uint32_t(key.flags));
    return size_t(hash);
  }
};

/// The bits of a colour, so that "the same colour" means exactly the same
/// floats. Near enough is not the same picture, and batching that changed the
/// picture would have to be switched off to be trusted.
inline std::array<uint32_t, 3> colourBits(const float *colour) {
  std::array<uint32_t, 3> bits{};
  std::memcpy(bits.data(), colour, sizeof(float) * 3);
  return bits;
}

/// One publish's worth of counting: how many objects fall under each key.
///
/// Two passes over the objects, because whether an object batches depends on
/// how many others are like it, and that is not known until all of them have
/// been seen. The first pass counts; the second asks.
class BatchCensus {
 public:
  /// Forgets the last publish. The map keeps its buckets, so a scene of the
  /// same shape every frame allocates nothing after the first.
  void clear() {
    _sizes.clear();
    _keys.clear();
    _eligible.clear();
  }

  /// The key for one object. [colourMatters] is true for the placeholder
  /// cube on the default surface and false for everything else.
  static BatchKey keyFor(int32_t mesh, int32_t surface, const float *colour,
                         int32_t flags, bool colourMatters) {
    BatchKey key;
    key.mesh = mesh;
    key.surface = surface;
    if (colourMatters) key.colour = colourBits(colour);
    key.flags = flags;
    return key;
  }

  /// Counts one object in, and remembers its key by position so the second
  /// pass does not have to build it again. [eligible] false records the
  /// position and counts nothing: a morphing or hidden object is never
  /// merged, but it still has a place in the list.
  void add(const BatchKey &key, bool eligible) {
    _keys.push_back(key);
    _eligible.push_back(eligible);
    if (eligible) _sizes[key]++;
  }

  /// Whether the object at [index] is one of enough copies to batch.
  bool batches(size_t index) const {
    if (index >= _keys.size() || !_eligible[index]) return false;
    auto found = _sizes.find(_keys[index]);
    return found != _sizes.end() && found->second >= kBatchMinimum;
  }

  /// How many objects are in a group large enough to batch.
  uint32_t batchedObjects() const {
    uint32_t total = 0;
    for (const auto &entry : _sizes) {
      if (entry.second >= kBatchMinimum) total += entry.second;
    }
    return total;
  }

  /// How many such groups there are: the draws a pass is left with for them
  /// if every group merged completely.
  uint32_t batchGroups() const {
    uint32_t groups = 0;
    for (const auto &entry : _sizes) {
      if (entry.second >= kBatchMinimum) groups++;
    }
    return groups;
  }

 private:
  std::unordered_map<BatchKey, uint32_t, BatchKeyHash> _sizes;
  std::vector<BatchKey> _keys;
  std::vector<bool> _eligible;
};

/// One surface per colour, shared by every placeholder cube wearing it.
///
/// The surface itself is whatever the renderer makes — an opaque pointer
/// here — built on first request and handed back to the renderer to destroy
/// once a whole publish has gone by without anybody asking for it. That
/// order matters: a surface destroyed while a renderable still wears it is a
/// Filament precondition, which aborts rather than failing, so a surface is
/// only let go after every object has been re-dressed.
template <typename Surface>
class ColourPool {
 public:
  /// The surface for [colour], built by [make] if there is none yet, and
  /// marked as wanted by the publish numbered [generation].
  template <typename Make>
  Surface *take(const float *colour, uint64_t generation, Make &&make) {
    const auto bits = colourBits(colour);
    auto found = _entries.find(bits);
    if (found == _entries.end()) {
      found = _entries.emplace(bits, Entry{make(colour), generation}).first;
    }
    found->second.seen = generation;
    return found->second.surface;
  }

  /// Hands back every surface the publish numbered [generation] did not ask
  /// for, through [destroy].
  template <typename Destroy>
  void sweep(uint64_t generation, Destroy &&destroy) {
    for (auto it = _entries.begin(); it != _entries.end();) {
      if (it->second.seen == generation) {
        ++it;
        continue;
      }
      if (it->second.surface != nullptr) destroy(it->second.surface);
      it = _entries.erase(it);
    }
  }

  /// Hands back every surface, for a renderer being taken down.
  template <typename Destroy>
  void clear(Destroy &&destroy) {
    for (auto &entry : _entries) {
      if (entry.second.surface != nullptr) destroy(entry.second.surface);
    }
    _entries.clear();
  }

  /// Every surface currently held, for the per-frame writes that every lit
  /// surface has to be given (the irradiance field's atlas, for one).
  template <typename Visit>
  void forEach(Visit &&visit) const {
    for (const auto &entry : _entries) {
      if (entry.second.surface != nullptr) visit(entry.second.surface);
    }
  }

  size_t size() const { return _entries.size(); }

 private:
  struct Entry {
    Surface *surface;
    uint64_t seen;
  };
  std::map<std::array<uint32_t, 3>, Entry> _entries;
};

}  // namespace orbis
