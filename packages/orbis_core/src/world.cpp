#include "world.h"

#include <algorithm>
#include <cstring>

namespace orbis {

// ------------------------------------------------------------ Archetype ----

Archetype::Archetype(std::vector<OrbisComponent> components,
                     const std::vector<ComponentType> &types)
    : components_(std::move(components)) {
  sizes_.reserve(components_.size());
  columns_.resize(components_.size());
  for (OrbisComponent component : components_) {
    sizes_.push_back(types[component - 1].size);
  }
}

bool Archetype::has(OrbisComponent component) const {
  return std::binary_search(components_.begin(), components_.end(), component);
}

int Archetype::columnOf(OrbisComponent component) const {
  auto it = std::lower_bound(components_.begin(), components_.end(), component);
  if (it == components_.end() || *it != component) return -1;
  return static_cast<int>(it - components_.begin());
}

uint32_t Archetype::appendRow(OrbisEntity entity) {
  const uint32_t row = static_cast<uint32_t>(entities_.size());
  entities_.push_back(entity);
  for (size_t i = 0; i < columns_.size(); i++) {
    // Zeroed rather than uninitialised: a component read before it is written
    // should be a predictable zero, not whatever the allocator handed back.
    columns_[i].resize(columns_[i].size() + sizes_[i], 0);
  }
  return row;
}

OrbisEntity Archetype::removeRow(uint32_t row) {
  const uint32_t last = static_cast<uint32_t>(entities_.size()) - 1;
  OrbisEntity moved = 0;

  if (row != last) {
    for (size_t i = 0; i < columns_.size(); i++) {
      const uint32_t size = sizes_[i];
      std::memcpy(columns_[i].data() + static_cast<size_t>(row) * size,
                  columns_[i].data() + static_cast<size_t>(last) * size, size);
    }
    moved = entities_[last];
    entities_[row] = moved;
  }

  entities_.pop_back();
  for (size_t i = 0; i < columns_.size(); i++) {
    columns_[i].resize(static_cast<size_t>(last) * sizes_[i]);
  }
  return moved;
}

void *Archetype::cell(uint32_t row, int column) {
  return columns_[column].data() +
         static_cast<size_t>(row) * sizes_[column];
}

// ---------------------------------------------------------------- World ----

World::World() {
  // Archetype 0 holds entities with no components, so a freshly created entity
  // already belongs somewhere and every later move is the same operation.
  archetypes_.emplace_back(std::vector<OrbisComponent>{}, types_);
  archetypesByComponents_[{}] = 0;
}

OrbisComponent World::registerComponent(const std::string &name, uint32_t size,
                                        uint32_t alignment) {
  if (size == 0) return 0;
  // Columns come from the default allocator, which guarantees alignment up to
  // max_align_t and no further. Over-aligned components are refused here rather
  // than misaligned silently at run time.
  if (alignment > alignof(std::max_align_t)) return 0;

  auto existing = typesByName_.find(name);
  if (existing != typesByName_.end()) {
    const ComponentType &type = types_[existing->second - 1];
    // Re-registering with the same layout is how two packages can both declare
    // a shared component; re-registering with a different one is a mistake.
    return (type.size == size && type.alignment == alignment) ? existing->second
                                                              : 0;
  }

  types_.push_back({name, size, alignment});
  const OrbisComponent id = static_cast<OrbisComponent>(types_.size());
  typesByName_[name] = id;
  return id;
}

OrbisComponent World::lookupComponent(const std::string &name) const {
  auto it = typesByName_.find(name);
  return it == typesByName_.end() ? 0 : it->second;
}

uint32_t World::componentSize(OrbisComponent component) const {
  if (component == 0 || component > types_.size()) return 0;
  return types_[component - 1].size;
}

const EntityRecord *World::recordFor(OrbisEntity entity) const {
  const uint32_t index = indexOf(entity);
  if (index >= records_.size()) return nullptr;
  const EntityRecord &record = records_[index];
  if (!record.alive || record.generation != generationOf(entity)) return nullptr;
  return &record;
}

EntityRecord *World::recordFor(OrbisEntity entity) {
  return const_cast<EntityRecord *>(
      static_cast<const World *>(this)->recordFor(entity));
}

bool World::alive(OrbisEntity entity) const {
  return entity != 0 && recordFor(entity) != nullptr;
}

OrbisEntity World::createEntity() {
  uint32_t index;
  if (!freeSlots_.empty()) {
    index = freeSlots_.back();
    freeSlots_.pop_back();
  } else {
    index = static_cast<uint32_t>(records_.size());
    records_.push_back(EntityRecord{});
    // Slot 0 would produce the handle 0, which the ABI reserves for "none", so
    // it is burned rather than special-cased at every call site.
    if (index == 0) {
      records_[0].generation = 1;
      index = static_cast<uint32_t>(records_.size());
      records_.push_back(EntityRecord{});
    }
  }

  EntityRecord &record = records_[index];
  record.alive = true;
  if (record.generation == 0) record.generation = 1;
  record.archetype = 0;
  record.row = archetypes_[0].appendRow(handle(index, record.generation));

  liveCount_++;
  version_++;
  return handle(index, record.generation);
}

void World::destroyEntity(OrbisEntity entity) {
  EntityRecord *record = recordFor(entity);
  if (!record) return;

  const uint32_t index = indexOf(entity);
  Archetype &archetype = archetypes_[record->archetype];
  const OrbisEntity moved = archetype.removeRow(record->row);
  if (moved != 0) records_[indexOf(moved)].row = record->row;

  record->alive = false;
  record->archetype = -1;
  // Bumping the generation is what makes every outstanding handle to this slot
  // detectably stale, rather than an alias for whoever is created next.
  record->generation++;
  if (record->generation == 0) record->generation = 1;

  freeSlots_.push_back(index);
  liveCount_--;
  version_++;
}

int World::archetypeFor(const std::vector<OrbisComponent> &components) {
  auto it = archetypesByComponents_.find(components);
  if (it != archetypesByComponents_.end()) return it->second;

  archetypes_.emplace_back(components, types_);
  const int index = static_cast<int>(archetypes_.size()) - 1;
  archetypesByComponents_[components] = index;
  return index;
}

void World::moveEntity(uint32_t index,
                       const std::vector<OrbisComponent> &components) {
  EntityRecord &record = records_[index];
  const int fromIndex = record.archetype;
  const int toIndex = archetypeFor(components);
  if (fromIndex == toIndex) return;

  const OrbisEntity entity = handle(index, record.generation);
  const uint32_t toRow = archetypes_[toIndex].appendRow(entity);

  // Copy across everything the two archetypes share. Anything only the source
  // had is dropped; anything only the destination has stays zeroed.
  for (OrbisComponent component : archetypes_[fromIndex].components()) {
    const int toColumn = archetypes_[toIndex].columnOf(component);
    if (toColumn < 0) continue;
    const int fromColumn = archetypes_[fromIndex].columnOf(component);
    std::memcpy(archetypes_[toIndex].cell(toRow, toColumn),
                archetypes_[fromIndex].cell(record.row, fromColumn),
                componentSize(component));
  }

  const OrbisEntity moved = archetypes_[fromIndex].removeRow(record.row);
  if (moved != 0) records_[indexOf(moved)].row = record.row;

  record.archetype = toIndex;
  record.row = toRow;
  version_++;
}

bool World::addComponent(OrbisEntity entity, OrbisComponent component,
                         const void *value) {
  EntityRecord *record = recordFor(entity);
  if (!record || component == 0 || component > types_.size()) return false;
  if (archetypes_[record->archetype].has(component)) return false;

  std::vector<OrbisComponent> components =
      archetypes_[record->archetype].components();
  components.insert(
      std::lower_bound(components.begin(), components.end(), component),
      component);
  moveEntity(indexOf(entity), components);

  if (value != nullptr) {
    Archetype &archetype = archetypes_[record->archetype];
    std::memcpy(archetype.cell(record->row, archetype.columnOf(component)),
                value, componentSize(component));
  }
  return true;
}

bool World::removeComponent(OrbisEntity entity, OrbisComponent component) {
  EntityRecord *record = recordFor(entity);
  if (!record) return false;
  if (!archetypes_[record->archetype].has(component)) return false;

  std::vector<OrbisComponent> components =
      archetypes_[record->archetype].components();
  components.erase(
      std::remove(components.begin(), components.end(), component),
      components.end());
  moveEntity(indexOf(entity), components);
  return true;
}

bool World::hasComponent(OrbisEntity entity, OrbisComponent component) const {
  const EntityRecord *record = recordFor(entity);
  return record && archetypes_[record->archetype].has(component);
}

void *World::getComponent(OrbisEntity entity, OrbisComponent component) {
  EntityRecord *record = recordFor(entity);
  if (!record) return nullptr;
  Archetype &archetype = archetypes_[record->archetype];
  const int column = archetype.columnOf(component);
  if (column < 0) return nullptr;
  return archetype.cell(record->row, column);
}

std::vector<int> World::matchingArchetypes(
    const std::vector<OrbisComponent> &components) const {
  std::vector<int> matches;
  for (size_t i = 0; i < archetypes_.size(); i++) {
    if (archetypes_[i].length() == 0) continue;  // nothing to iterate
    bool all = true;
    for (OrbisComponent component : components) {
      if (!archetypes_[i].has(component)) {
        all = false;
        break;
      }
    }
    if (all) matches.push_back(static_cast<int>(i));
  }
  return matches;
}

uint32_t World::registerSystem(const std::string &name, OrbisSystemFn function,
                               void *user) {
  systems_.push_back({name, function, user});
  return static_cast<uint32_t>(systems_.size());
}

void World::tick(double delta) {
  elapsed_ += delta;
  for (const System &system : systems_) {
    if (system.function) {
      system.function(reinterpret_cast<OrbisWorld *>(this), delta, system.user);
    }
  }
}

}  // namespace orbis
