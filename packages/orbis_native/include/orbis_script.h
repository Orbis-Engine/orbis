// The contract a native script is compiled against.
//
// A script is not a language. It is a file that answers four questions — what
// version of this contract it was built for, what to do when it starts, what
// to do each frame, and what to do when it stops — and is handed a table of
// everything it may call back into. TypeScript answers the same four questions
// through QuickJS and Dart through FFI; this is the C++ front end onto the
// same boundary, not a second engine.
//
// Two decisions carry the design:
//
//   The host arrives as a table of function pointers, not as symbols to link
//   against. A script that linked to the engine would have to find the
//   engine's built library, would break the moment that library moved, and
//   would need a different answer on every platform. A table is one pointer,
//   resolved at load, identical everywhere, and versioned — which is what
//   makes it possible to say a script is *incompatible* rather than to find
//   out by crashing.
//
//   The table is filled on the Dart side from the same declarations Dart
//   already binds the core with. There is no hand-maintained mirror of the
//   core's API that could drift from it: if the binding is right, the table
//   is right.

#ifndef ORBIS_SCRIPT_H
#define ORBIS_SCRIPT_H

#include "orbis_core.h"

/// Bumped whenever anything below changes shape.
///
/// A script reports the number it was built against and the host refuses one
/// it does not know, because the alternative to refusing is calling through a
/// function pointer that means something else now.
#define ORBIS_SCRIPT_ABI 2

#ifdef __cplusplus
extern "C" {
#endif

/// Everything a script may call.
///
/// Laid out in one struct rather than passed as arguments because it grows:
/// adding a call is a new member and a bumped ABI, not a changed signature on
/// every entry point.
typedef struct OrbisScriptHost {
  /// ORBIS_SCRIPT_ABI as the *host* was built. A script that wants to run
  /// against more than one version of the engine can look at this; one that
  /// does not can ignore it and let the host do the refusing.
  uint32_t abi;

  /// sizeof(OrbisScriptHost) as the host was built.
  ///
  /// The version number catches a script built against a different contract.
  /// This catches the subtler thing: two builds that agree about the version
  /// and disagree about the struct, because one of them was compiled against a
  /// header that had been edited. Checked at load, before any member below it
  /// is read.
  uint32_t size;

  /// The world this script runs against. Never null while the script is
  /// started.
  OrbisWorld *world;

  /// Puts a line where the host puts its own. Not printf: a script's output
  /// belongs in the editor's console, and stdout is not that.
  void (*log)(const char *message);

  // --- the core, by pointer -------------------------------------------------
  //
  // The same functions declared in orbis_core.h. Reached this way rather than
  // by linking, so that a script is a file the host loads rather than a file
  // that has to have found the engine first.

  OrbisComponent (*component_register)(OrbisWorld *world, const char *name,
                                       uint32_t size, uint32_t alignment);
  OrbisComponent (*component_lookup)(const OrbisWorld *world, const char *name);

  OrbisEntity (*entity_create)(OrbisWorld *world);
  void (*entity_destroy)(OrbisWorld *world, OrbisEntity entity);
  bool (*entity_alive)(const OrbisWorld *world, OrbisEntity entity);
  uint32_t (*entity_count)(const OrbisWorld *world);
  bool (*entity_add)(OrbisWorld *world, OrbisEntity entity,
                     OrbisComponent component, const void *value);
  bool (*entity_remove)(OrbisWorld *world, OrbisEntity entity,
                        OrbisComponent component);
  bool (*entity_has)(const OrbisWorld *world, OrbisEntity entity,
                     OrbisComponent component);
  void *(*entity_get)(OrbisWorld *world, OrbisEntity entity,
                      OrbisComponent component);

  OrbisQuery *(*query_create)(OrbisWorld *world,
                              const OrbisComponent *components, uint32_t count);
  void (*query_destroy)(OrbisQuery *query);
  uint32_t (*query_chunk_count)(OrbisQuery *query);
  uint32_t (*query_chunk_length)(OrbisQuery *query, uint32_t chunk);
  void *(*query_chunk_column)(OrbisQuery *query, uint32_t chunk, uint32_t slot);
  const OrbisEntity *(*query_chunk_entities)(OrbisQuery *query, uint32_t chunk);

  OrbisTransforms (*transform_register)(OrbisWorld *world);

  // --- data objects ---------------------------------------------------------
  //
  // The values that live in the project rather than in a scene. A script reads
  // them; it does not own them, and it does not get a copy — asking again
  // after somebody changes one gives the new value, which is the whole reason
  // the data is a file rather than a constant in this source.

  double (*data_number)(const char *asset, const char *key, double fallback);
  bool (*data_toggle)(const char *asset, const char *key, bool fallback);

  /// Borrowed and valid until the next call to this function. Copy it if it
  /// has to outlive the line that read it.
  const char *(*data_text)(const char *asset, const char *key);

  // --- data objects, without the call ---------------------------------------
  //
  // The three above cross into the host every time they are read, which is
  // fine for a value read once when a script starts and is not fine for one
  // read inside a loop over a hundred thousand entities. These hand back the
  // address the value lives at instead: resolve once, then every read is a
  // load from memory and crosses nothing.
  //
  // The address is stable for the life of the host — the value behind it is
  // not. It is rewritten in place when somebody changes the data object, which
  // is exactly what a script wants: no call, and still the current value.
  //
  // NULL only if the host has been disposed.

  const double *(*number_at)(const char *asset, const char *key,
                             double fallback);
  const bool *(*toggle_at)(const char *asset, const char *key, bool fallback);

  /// A pointer to the string pointer, not to the string. Read it every time
  /// rather than keeping what it held: the string is replaced when the value
  /// changes, and the old one does not outlive the frame it changed in.
  const char *const *(*text_at)(const char *asset, const char *key);
} OrbisScriptHost;

// --- what a script must provide ---------------------------------------------

/// The contract version this script was built against.
///
/// Defined for you by ORBIS_SCRIPT, which is why it is the one entry point
/// nobody writes by hand: a number somebody has to remember to update is a
/// number that will be wrong.
uint32_t orbis_script_abi(void);

/// sizeof(OrbisScriptHost) as this script was built.
///
/// Also defined for you by ORBIS_SCRIPT. Two builds can agree about the
/// version and disagree about the struct — one of them compiled against a
/// header somebody had edited — and the only way to catch that is to compare
/// the thing itself rather than the number beside it.
uint32_t orbis_script_host_size(void);

/// Called once, when the script is loaded. The host outlives the call.
void orbis_start(const OrbisScriptHost *host);

/// Called every frame, with the seconds since the last one.
void orbis_step(double delta);

/// Called once, before the script is unloaded.
void orbis_stop(void);

#ifdef __cplusplus
}
#endif

// --- writing one ------------------------------------------------------------

#ifdef __cplusplus
namespace orbis {

/// The host, for everything below. Null before orbis_start.
inline const OrbisScriptHost *&host_slot() {
  static const OrbisScriptHost *held = nullptr;
  return held;
}

inline const OrbisScriptHost *host() { return host_slot(); }

inline OrbisWorld *world() { return host_slot()->world; }

inline void log(const char *message) { host_slot()->log(message); }

/// A component id, registered on first use.
template <typename T>
inline OrbisComponent component(const char *name) {
  return host_slot()->component_register(world(), name, sizeof(T), alignof(T));
}

inline OrbisEntity spawn() { return host_slot()->entity_create(world()); }

inline void destroy(OrbisEntity entity) {
  host_slot()->entity_destroy(world(), entity);
}

/// Adds a component with a value, in one call and with the type kept.
template <typename T>
inline bool give(OrbisEntity entity, OrbisComponent id, const T &value) {
  return host_slot()->entity_add(world(), entity, id, &value);
}

/// A pointer to an entity's component, or null. Valid until the next
/// structural change to the world — the same rule the core states, because it
/// is the same pointer.
template <typename T>
inline T *get(OrbisEntity entity, OrbisComponent id) {
  return static_cast<T *>(host_slot()->entity_get(world(), entity, id));
}

/// Reads a value, crossing into the host to do it.
///
/// For a key that is not known until it is computed, and for anything read
/// once when a script starts. Anything read every frame should hold the
/// address instead — see number_at below.
inline double number(const char *asset, const char *key, double fallback = 0) {
  return host_slot()->data_number(asset, key, fallback);
}

inline bool toggle(const char *asset, const char *key, bool fallback = false) {
  return host_slot()->data_toggle(asset, key, fallback);
}

inline const char *text(const char *asset, const char *key) {
  return host_slot()->data_text(asset, key);
}

/// Where a value lives, resolved once.
///
/// Hold the pointer and read through it. The address does not move; the value
/// behind it changes when somebody edits the data object. Written as a
/// function-local static in the headers the editor generates, so resolution
/// happens on the first read and every read after it is a load:
///
///     inline double speed(double fallback = 0) {
///       static const double *at = ::orbis::number_at(asset, "speed", 0.0);
///       return at ? *at : fallback;
///     }
inline const double *number_at(const char *asset, const char *key,
                               double fallback = 0) {
  return host_slot()->number_at(asset, key, fallback);
}

inline const bool *toggle_at(const char *asset, const char *key,
                             bool fallback = false) {
  return host_slot()->toggle_at(asset, key, fallback);
}

inline const char *const *text_at(const char *asset, const char *key) {
  return host_slot()->text_at(asset, key);
}

}  // namespace orbis

/// Writes the boilerplate every script would otherwise write identically.
///
/// Declares the ABI answer and stashes the host, then calls a `start` the
/// script itself defines. Put it once at the top of a script, after the
/// includes.
#define ORBIS_SCRIPT                                       \
  extern "C" uint32_t orbis_script_abi(void) {             \
    return ORBIS_SCRIPT_ABI;                               \
  }                                                        \
  extern "C" uint32_t orbis_script_host_size(void) {       \
    return (uint32_t)sizeof(OrbisScriptHost);              \
  }                                                        \
  static void orbis_script_started();                      \
  extern "C" void orbis_start(const OrbisScriptHost *h) {  \
    ::orbis::host_slot() = h;                              \
    orbis_script_started();                                \
  }                                                        \
  static void orbis_script_started()

#endif  // __cplusplus

#endif  // ORBIS_SCRIPT_H
