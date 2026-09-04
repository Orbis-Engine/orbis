// The Orbis engine core: a C ABI over an archetype entity-component store.
//
// This header is the whole contract. Dart binds to it over dart:ffi, QuickJS
// binds to it directly, and a console shell with no Flutter in sight binds to
// the same functions — which is why nothing here mentions any of them.
//
// Two ideas carry most of the design:
//
//   Handles are generational. An entity is an index plus a generation counter,
//   so a handle to an entity that has been destroyed and its slot reused is
//   detected rather than silently addressing whatever now lives there. Three
//   runtimes with independent lifetimes will be holding these.
//
//   Iteration is by column, not by entity. Components of one type live
//   contiguously, and a query hands out raw pointers to those runs. A caller
//   crosses this boundary once per system per tick and then works in its own
//   language over its own view of the same memory. Calling in once per entity
//   is the thing this design exists to avoid.

#ifndef ORBIS_CORE_H
#define ORBIS_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// An entity handle: the low 32 bits index a slot, the high 32 bits count how
/// many times that slot has been reused. Zero is never a live entity.
typedef uint64_t OrbisEntity;

/// A registered component type. Zero means "no such component".
typedef uint32_t OrbisComponent;

typedef struct OrbisWorld OrbisWorld;
typedef struct OrbisQuery OrbisQuery;

/// Runs over a world each tick. `user` is whatever was passed at registration.
typedef void (*OrbisSystemFn)(OrbisWorld *world, double delta, void *user);

// ---------------------------------------------------------------- world ----

OrbisWorld *orbis_world_create(void);
void orbis_world_destroy(OrbisWorld *world);

/// Increments whenever an entity gains or loses a component, or is created or
/// destroyed. Queries use it to know when their cached archetype list is stale;
/// a caller holding a view can use it to know when the view may have moved.
uint64_t orbis_world_version(const OrbisWorld *world);

// ------------------------------------------------------------ components ----

/// Registers a component type, or returns the existing id if `name` is already
/// registered with the same layout. Returns 0 if the name is taken by a
/// different layout, since that is a build error rather than a runtime one.
OrbisComponent orbis_component_register(OrbisWorld *world, const char *name,
                                        uint32_t size, uint32_t alignment);

/// The id previously registered under `name`, or 0.
OrbisComponent orbis_component_lookup(const OrbisWorld *world, const char *name);

uint32_t orbis_component_size(const OrbisWorld *world, OrbisComponent component);
uint32_t orbis_component_count(const OrbisWorld *world);

// -------------------------------------------------------------- entities ----

OrbisEntity orbis_entity_create(OrbisWorld *world);
void orbis_entity_destroy(OrbisWorld *world, OrbisEntity entity);

/// False for a handle whose generation no longer matches its slot — the case
/// that would otherwise be a silent read of another entity's data.
bool orbis_entity_alive(const OrbisWorld *world, OrbisEntity entity);

uint32_t orbis_entity_count(const OrbisWorld *world);

/// Adds `component` to `entity`, copying `value` if it is not NULL and zeroing
/// the storage otherwise. False if the entity is dead or already has it.
bool orbis_entity_add(OrbisWorld *world, OrbisEntity entity,
                      OrbisComponent component, const void *value);

bool orbis_entity_remove(OrbisWorld *world, OrbisEntity entity,
                         OrbisComponent component);

bool orbis_entity_has(const OrbisWorld *world, OrbisEntity entity,
                      OrbisComponent component);

/// A pointer into the entity's storage, or NULL. Valid until the next
/// structural change to the world — see orbis_world_version.
void *orbis_entity_get(OrbisWorld *world, OrbisEntity entity,
                       OrbisComponent component);

// --------------------------------------------------------------- queries ----

/// A query over every entity carrying all of `components`.
///
/// The order given here is the slot order used by orbis_query_chunk_column, so
/// a caller indexes columns by position rather than by component id.
OrbisQuery *orbis_query_create(OrbisWorld *world, const OrbisComponent *components,
                               uint32_t count);
void orbis_query_destroy(OrbisQuery *query);

/// How many contiguous runs the matching entities occupy. Recomputed here if
/// the world has changed since the last call, so this is the function to call
/// first each tick.
uint32_t orbis_query_chunk_count(OrbisQuery *query);

/// How many entities are in `chunk`.
uint32_t orbis_query_chunk_length(OrbisQuery *query, uint32_t chunk);

/// The start of one component's run within `chunk`, holding
/// orbis_query_chunk_length entries laid out end to end. This is the pointer a
/// caller wraps as a typed array; nothing is copied.
void *orbis_query_chunk_column(OrbisQuery *query, uint32_t chunk, uint32_t slot);

/// The entity handles for `chunk`, in the same order as every column.
const OrbisEntity *orbis_query_chunk_entities(OrbisQuery *query, uint32_t chunk);

/// Every component carried by the entities in `chunk`, including ones the
/// query did not ask for, written in ascending id order into `out`.
///
/// Returns how many there are, which may exceed `capacity` — call with a null
/// `out` to size a buffer first. A caller that has to react to what an entity
/// happens to carry, rather than to a fixed set, needs this: replication asks
/// it once per run rather than once per entity.
uint32_t orbis_query_chunk_components(OrbisQuery *query, uint32_t chunk,
                                      OrbisComponent *out, uint32_t capacity);

/// A column in `chunk` addressed by component rather than by query slot, so a
/// caller can read something the query did not name. NULL if absent.
void *orbis_query_chunk_component_column(OrbisQuery *query, uint32_t chunk,
                                         OrbisComponent component);

// ------------------------------------------------------------ transforms ----

/// The built-in transform components.
///
/// A scene graph is a tree and an archetype store is flat, so the hierarchy
/// lives in a component rather than in the storage: an entity names its parent
/// and the engine derives world space from that. Nothing else in the core
/// knows about parenting, which is what keeps the storage general.
typedef struct {
  /// Ten floats: translation xyz, rotation as a quaternion xyzw, scale xyz.
  OrbisComponent local;

  /// Sixteen floats, column-major, the convention glTF and Filament both use.
  /// Derived — writing it directly is overwritten by the next propagation.
  OrbisComponent world;

  /// One OrbisEntity. Absent means the entity is a root.
  OrbisComponent parent;
} OrbisTransforms;

/// Registers the transform components, or returns the existing ids.
OrbisTransforms orbis_transform_register(OrbisWorld *world);

/// Derives every world transform from local transforms and parent links.
///
/// Each entity is resolved once however many children depend on it. A parent
/// chain that loops is treated as a root at the point it closes, so a cycle
/// costs a wrong transform rather than a hang.
///
/// Returns how many entities were written.
uint32_t orbis_transform_propagate(OrbisWorld *world);

/// Composes a local transform into a column-major matrix, without touching the
/// world. Exposed because a caller building a matrix for something that is not
/// an entity should not have to reimplement the convention.
void orbis_transform_compose(const float *translationRotationScale,
                             float *outMatrix16);

// --------------------------------------------------------------- systems ----

/// Registers a native system. Systems run in registration order.
///
/// Sequential for now: the ordering and the job pool arrive with physics, and
/// putting a scheduler in before there is anything to schedule would be
/// designing against an imagined workload.
uint32_t orbis_system_register(OrbisWorld *world, const char *name,
                               OrbisSystemFn function, void *user);

/// Runs every registered system once. The caller owns the frame — Dart drives
/// this from its frame callback, a console shell from its own loop.
void orbis_world_tick(OrbisWorld *world, double delta);

/// Seconds accumulated across ticks, for systems that want a clock without
/// keeping one.
double orbis_world_elapsed(const OrbisWorld *world);

#ifdef __cplusplus
}
#endif

#endif  // ORBIS_CORE_H
