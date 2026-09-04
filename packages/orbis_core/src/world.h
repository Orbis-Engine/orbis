// The archetype store behind the C ABI.
//
// Entities carrying the same set of components live together in one archetype,
// and within an archetype each component type occupies one contiguous column.
// Adding or removing a component therefore moves an entity between archetypes
// rather than leaving holes, which is what keeps a query's runs dense and makes
// a whole system's work one pointer and a length.

#ifndef ORBIS_WORLD_H
#define ORBIS_WORLD_H

#include <cstdint>
#include <map>
#include <string>
#include <unordered_map>
#include <vector>

#include "orbis_core.h"

namespace orbis {

struct ComponentType {
  std::string name;
  uint32_t size = 0;
  uint32_t alignment = 0;
};

class World;

/// One set of component types, and the entities that carry exactly that set.
class Archetype {
 public:
  explicit Archetype(std::vector<OrbisComponent> components,
                     const std::vector<ComponentType> &types);

  /// Sorted, so a component set has one canonical spelling and archetypes can
  /// be looked up by it.
  const std::vector<OrbisComponent> &components() const { return components_; }

  bool has(OrbisComponent component) const;

  /// Position of `component` among this archetype's columns, or -1.
  int columnOf(OrbisComponent component) const;

  uint32_t length() const { return static_cast<uint32_t>(entities_.size()); }
  const std::vector<OrbisEntity> &entities() const { return entities_; }

  /// The start of a column's storage. Moves when the archetype grows.
  void *columnData(int column) { return columns_[column].data(); }

  /// Appends a row for `entity` with every component zeroed, returning its
  /// index.
  uint32_t appendRow(OrbisEntity entity);

  /// Removes `row` by moving the last row into its place, so rows stay dense.
  /// The entity that moved is returned so the caller can fix its record; zero
  /// when the removed row was already last.
  OrbisEntity removeRow(uint32_t row);

  void *cell(uint32_t row, int column);

 private:
  std::vector<OrbisComponent> components_;
  std::vector<uint32_t> sizes_;
  std::vector<std::vector<uint8_t>> columns_;
  std::vector<OrbisEntity> entities_;
};

/// Where one entity's data currently lives.
struct EntityRecord {
  uint32_t generation = 0;
  bool alive = false;
  int archetype = -1;
  uint32_t row = 0;
};

struct System {
  std::string name;
  OrbisSystemFn function = nullptr;
  void *user = nullptr;
};

class World {
 public:
  World();

  uint64_t version() const { return version_; }
  double elapsed() const { return elapsed_; }

  // components
  OrbisComponent registerComponent(const std::string &name, uint32_t size,
                                   uint32_t alignment);
  OrbisComponent lookupComponent(const std::string &name) const;
  uint32_t componentSize(OrbisComponent component) const;
  uint32_t componentCount() const {
    return static_cast<uint32_t>(types_.size());
  }
  const std::vector<ComponentType> &types() const { return types_; }

  // entities
  OrbisEntity createEntity();
  void destroyEntity(OrbisEntity entity);
  bool alive(OrbisEntity entity) const;
  uint32_t entityCount() const { return liveCount_; }

  bool addComponent(OrbisEntity entity, OrbisComponent component,
                    const void *value);
  bool removeComponent(OrbisEntity entity, OrbisComponent component);
  bool hasComponent(OrbisEntity entity, OrbisComponent component) const;
  void *getComponent(OrbisEntity entity, OrbisComponent component);

  // queries
  std::vector<int> matchingArchetypes(
      const std::vector<OrbisComponent> &components) const;
  Archetype &archetype(int index) { return archetypes_[index]; }

  // systems
  uint32_t registerSystem(const std::string &name, OrbisSystemFn function,
                          void *user);
  void tick(double delta);

  static uint32_t indexOf(OrbisEntity entity) {
    return static_cast<uint32_t>(entity & 0xFFFFFFFFu);
  }
  static uint32_t generationOf(OrbisEntity entity) {
    return static_cast<uint32_t>(entity >> 32);
  }
  static OrbisEntity handle(uint32_t index, uint32_t generation) {
    return (static_cast<OrbisEntity>(generation) << 32) | index;
  }

 private:
  /// The archetype for a component set, created if it does not exist.
  int archetypeFor(const std::vector<OrbisComponent> &components);

  /// Moves an entity to the archetype for `components`, carrying across every
  /// component the two sets share.
  void moveEntity(uint32_t index, const std::vector<OrbisComponent> &components);

  const EntityRecord *recordFor(OrbisEntity entity) const;
  EntityRecord *recordFor(OrbisEntity entity);

  std::vector<ComponentType> types_;
  std::unordered_map<std::string, OrbisComponent> typesByName_;

  std::vector<Archetype> archetypes_;
  std::map<std::vector<OrbisComponent>, int> archetypesByComponents_;

  std::vector<EntityRecord> records_;
  std::vector<uint32_t> freeSlots_;
  uint32_t liveCount_ = 0;

  std::vector<System> systems_;
  uint64_t version_ = 1;
  double elapsed_ = 0.0;
};

}  // namespace orbis

#endif  // ORBIS_WORLD_H
