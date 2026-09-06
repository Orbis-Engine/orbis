// A script, in C++.
//
// The same four questions every script answers, whatever it is written in.
// What makes this one worth writing in C++ rather than TypeScript is the loop:
// it touches every entity's transform every frame, and that is the shape of
// work that has to be native.

#include <cmath>

#include "orbis_script.h"

namespace {

OrbisComponent spin;
OrbisTransforms transforms;
double elapsed = 0;

/// Ten floats: translation xyz, rotation xyzw, scale xyz.
struct Local {
  float values[10];
};

struct Spin {
  float turnsPerSecond;
};

}  // namespace

ORBIS_SCRIPT {
  transforms = orbis::host()->transform_register(orbis::world());
  spin = orbis::component<Spin>("Spin");
  orbis::log("spinner: started");
}

extern "C" void orbis_step(double delta) {
  elapsed += delta;

  const OrbisComponent wanted[] = {transforms.local, spin};
  OrbisQuery *query = orbis::host()->query_create(orbis::world(), wanted, 2);

  const uint32_t chunks = orbis::host()->query_chunk_count(query);
  for (uint32_t chunk = 0; chunk < chunks; ++chunk) {
    const uint32_t length = orbis::host()->query_chunk_length(query, chunk);
    auto *locals = static_cast<Local *>(
        orbis::host()->query_chunk_column(query, chunk, 0));
    auto *spins =
        static_cast<Spin *>(orbis::host()->query_chunk_column(query, chunk, 1));

    // One crossing of the boundary for the whole run, then plain C++ over the
    // engine's own memory. Calling in once per entity is the thing the column
    // layout exists to avoid.
    for (uint32_t i = 0; i < length; ++i) {
      const double angle = elapsed * spins[i].turnsPerSecond * 6.283185307;
      locals[i].values[3] = 0.0f;
      locals[i].values[4] = static_cast<float>(std::sin(angle * 0.5));
      locals[i].values[5] = 0.0f;
      locals[i].values[6] = static_cast<float>(std::cos(angle * 0.5));
    }
  }

  orbis::host()->query_destroy(query);
}

extern "C" void orbis_stop(void) { orbis::log("spinner: stopped"); }
