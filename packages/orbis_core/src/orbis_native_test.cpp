// A standalone check of the store, so a storage bug is found here rather than
// through two language bindings. Built by tool/check_native.sh, not by the
// package — Dart's tests cover the same ground through the ABI.

#include <cstdio>
#include <cstring>
#include <vector>

#include "orbis_core.h"

namespace {

int failures = 0;

void check(bool condition, const char *what) {
  if (!condition) {
    std::printf("FAIL  %s\n", what);
    failures++;
  } else {
    std::printf("ok    %s\n", what);
  }
}

struct Position {
  float x, y, z;
};

}  // namespace

int main() {
  OrbisWorld *world = orbis_world_create();

  const OrbisComponent position =
      orbis_component_register(world, "Position", sizeof(Position), alignof(Position));
  const OrbisComponent velocity =
      orbis_component_register(world, "Velocity", sizeof(Position), alignof(Position));
  check(position != 0 && velocity != 0 && position != velocity,
        "components register with distinct ids");
  check(orbis_component_register(world, "Position", sizeof(Position), alignof(Position)) == position,
        "re-registering an identical layout returns the same id");
  check(orbis_component_register(world, "Position", 8, 4) == 0,
        "re-registering a different layout is refused");

  const OrbisEntity entity = orbis_entity_create(world);
  check(entity != 0 && orbis_entity_alive(world, entity), "an entity is created alive");

  Position start{1.0f, 2.0f, 3.0f};
  check(orbis_entity_add(world, entity, position, &start), "a component is added");
  check(orbis_entity_has(world, entity, position), "the entity reports having it");
  auto *stored = static_cast<Position *>(orbis_entity_get(world, entity, position));
  check(stored && stored->x == 1.0f && stored->z == 3.0f, "the value survives the add");

  orbis_entity_destroy(world, entity);
  check(!orbis_entity_alive(world, entity), "a destroyed entity is not alive");

  const OrbisEntity reused = orbis_entity_create(world);
  check(orbis_entity_alive(world, reused), "the freed slot is reused");
  check(!orbis_entity_alive(world, entity),
        "the stale handle stays dead after its slot is reused");
  check(reused != entity, "the reused handle differs by generation");

  // Dense iteration over a mixed world: only the entities carrying both
  // components should appear.
  std::vector<OrbisEntity> movers;
  for (int i = 0; i < 100; i++) {
    OrbisEntity e = orbis_entity_create(world);
    Position p{static_cast<float>(i), 0, 0};
    orbis_entity_add(world, e, position, &p);
    if (i % 2 == 0) {
      Position v{1.0f, 0, 0};
      orbis_entity_add(world, e, velocity, &v);
      movers.push_back(e);
    }
  }

  const OrbisComponent wanted[2] = {position, velocity};
  OrbisQuery *query = orbis_query_create(world, wanted, 2);
  uint32_t seen = 0;
  for (uint32_t chunk = 0; chunk < orbis_query_chunk_count(query); chunk++) {
    const uint32_t length = orbis_query_chunk_length(query, chunk);
    auto *positions = static_cast<Position *>(orbis_query_chunk_column(query, chunk, 0));
    auto *velocities = static_cast<Position *>(orbis_query_chunk_column(query, chunk, 1));
    for (uint32_t i = 0; i < length; i++) {
      positions[i].x += velocities[i].x;
    }
    seen += length;
  }
  check(seen == movers.size(), "the query sees exactly the entities with both");

  // movers[i] came from loop counter 2i, so its x started at 2i and the
  // column write above should have advanced it by one.
  bool advanced = true;
  for (size_t i = 0; i < movers.size(); i++) {
    auto *p = static_cast<Position *>(orbis_entity_get(world, movers[i], position));
    if (!p || p->x != static_cast<float>(i * 2) + 1.0f) advanced = false;
  }
  check(advanced, "writes through the column land on the right entities");

  orbis_entity_remove(world, movers[0], velocity);
  check(!orbis_entity_has(world, movers[0], velocity), "a component is removed");
  check(orbis_entity_has(world, movers[0], position), "the other component survives");
  check(orbis_query_chunk_count(query) > 0, "the query refreshes after a move");

  uint32_t after = 0;
  for (uint32_t chunk = 0; chunk < orbis_query_chunk_count(query); chunk++) {
    after += orbis_query_chunk_length(query, chunk);
  }
  check(after == movers.size() - 1, "the moved entity leaves the query");

  orbis_query_destroy(query);
  orbis_world_destroy(world);

  std::printf(failures == 0 ? "\nALL PASSED\n" : "\n%d FAILED\n", failures);
  return failures == 0 ? 0 : 1;
}
