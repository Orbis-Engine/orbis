// The C ABI, over the archetype store in world.h.
//
// Thin on purpose: the interesting decisions are in the World, and this file's
// job is to keep C++ types from leaking across a boundary that Dart, QuickJS
// and a native console shell all have to speak.

#include "orbis_core.h"

#include <string>
#include <vector>

#include "world.h"

using orbis::Archetype;
using orbis::World;

namespace {

World *world_of(OrbisWorld *handle) {
  return reinterpret_cast<World *>(handle);
}

const World *world_of(const OrbisWorld *handle) {
  return reinterpret_cast<const World *>(handle);
}

OrbisWorld *handle_of(World *world) {
  return reinterpret_cast<OrbisWorld *>(world);
}

}  // namespace

/// A cached view of which archetypes match, refreshed when the world moves on.
///
/// Holding the resolved column index per slot means iterating costs a lookup
/// per archetype per tick rather than per entity.
struct OrbisQuery {
  World *world = nullptr;
  std::vector<OrbisComponent> components;
  uint64_t version = 0;
  std::vector<int> archetypes;
  std::vector<std::vector<int>> columns;

  void refresh() {
    if (version == world->version() && version != 0) return;
    version = world->version();
    archetypes = world->matchingArchetypes(components);
    columns.clear();
    columns.reserve(archetypes.size());
    for (int index : archetypes) {
      std::vector<int> slots;
      slots.reserve(components.size());
      for (OrbisComponent component : components) {
        slots.push_back(world->archetype(index).columnOf(component));
      }
      columns.push_back(std::move(slots));
    }
  }
};

// ---------------------------------------------------------------- world ----

OrbisWorld *orbis_world_create(void) { return handle_of(new World()); }

void orbis_world_destroy(OrbisWorld *world) { delete world_of(world); }

uint64_t orbis_world_version(const OrbisWorld *world) {
  return world_of(world)->version();
}

// ------------------------------------------------------------ components ----

OrbisComponent orbis_component_register(OrbisWorld *world, const char *name,
                                        uint32_t size, uint32_t alignment) {
  if (!name) return 0;
  return world_of(world)->registerComponent(name, size, alignment);
}

OrbisComponent orbis_component_lookup(const OrbisWorld *world,
                                      const char *name) {
  if (!name) return 0;
  return world_of(world)->lookupComponent(name);
}

uint32_t orbis_component_size(const OrbisWorld *world,
                              OrbisComponent component) {
  return world_of(world)->componentSize(component);
}

uint32_t orbis_component_count(const OrbisWorld *world) {
  return world_of(world)->componentCount();
}

// -------------------------------------------------------------- entities ----

OrbisEntity orbis_entity_create(OrbisWorld *world) {
  return world_of(world)->createEntity();
}

void orbis_entity_destroy(OrbisWorld *world, OrbisEntity entity) {
  world_of(world)->destroyEntity(entity);
}

bool orbis_entity_alive(const OrbisWorld *world, OrbisEntity entity) {
  return world_of(world)->alive(entity);
}

uint32_t orbis_entity_count(const OrbisWorld *world) {
  return world_of(world)->entityCount();
}

bool orbis_entity_add(OrbisWorld *world, OrbisEntity entity,
                      OrbisComponent component, const void *value) {
  return world_of(world)->addComponent(entity, component, value);
}

bool orbis_entity_remove(OrbisWorld *world, OrbisEntity entity,
                         OrbisComponent component) {
  return world_of(world)->removeComponent(entity, component);
}

bool orbis_entity_has(const OrbisWorld *world, OrbisEntity entity,
                      OrbisComponent component) {
  return world_of(world)->hasComponent(entity, component);
}

void *orbis_entity_get(OrbisWorld *world, OrbisEntity entity,
                       OrbisComponent component) {
  return world_of(world)->getComponent(entity, component);
}

// --------------------------------------------------------------- queries ----

OrbisQuery *orbis_query_create(OrbisWorld *world,
                               const OrbisComponent *components,
                               uint32_t count) {
  auto *query = new OrbisQuery();
  query->world = world_of(world);
  query->components.assign(components, components + count);
  return query;
}

void orbis_query_destroy(OrbisQuery *query) { delete query; }

uint32_t orbis_query_chunk_count(OrbisQuery *query) {
  query->refresh();
  return static_cast<uint32_t>(query->archetypes.size());
}

uint32_t orbis_query_chunk_length(OrbisQuery *query, uint32_t chunk) {
  if (chunk >= query->archetypes.size()) return 0;
  return query->world->archetype(query->archetypes[chunk]).length();
}

void *orbis_query_chunk_column(OrbisQuery *query, uint32_t chunk,
                               uint32_t slot) {
  if (chunk >= query->archetypes.size()) return nullptr;
  if (slot >= query->components.size()) return nullptr;
  const int column = query->columns[chunk][slot];
  if (column < 0) return nullptr;
  return query->world->archetype(query->archetypes[chunk]).columnData(column);
}

const OrbisEntity *orbis_query_chunk_entities(OrbisQuery *query,
                                              uint32_t chunk) {
  if (chunk >= query->archetypes.size()) return nullptr;
  return query->world->archetype(query->archetypes[chunk]).entities().data();
}

uint32_t orbis_query_chunk_components(OrbisQuery *query, uint32_t chunk,
                                      OrbisComponent *out, uint32_t capacity) {
  if (chunk >= query->archetypes.size()) return 0;
  const auto &components =
      query->world->archetype(query->archetypes[chunk]).components();
  if (out != nullptr) {
    const uint32_t writable =
        capacity < components.size() ? capacity
                                     : static_cast<uint32_t>(components.size());
    for (uint32_t i = 0; i < writable; i++) out[i] = components[i];
  }
  return static_cast<uint32_t>(components.size());
}

void *orbis_query_chunk_component_column(OrbisQuery *query, uint32_t chunk,
                                         OrbisComponent component) {
  if (chunk >= query->archetypes.size()) return nullptr;
  Archetype &archetype = query->world->archetype(query->archetypes[chunk]);
  const int column = archetype.columnOf(component);
  if (column < 0) return nullptr;
  return archetype.columnData(column);
}

// --------------------------------------------------------------- systems ----

uint32_t orbis_system_register(OrbisWorld *world, const char *name,
                               OrbisSystemFn function, void *user) {
  return world_of(world)->registerSystem(name ? name : "", function, user);
}

void orbis_world_tick(OrbisWorld *world, double delta) {
  world_of(world)->tick(delta);
}

double orbis_world_elapsed(const OrbisWorld *world) {
  return world_of(world)->elapsed();
}
