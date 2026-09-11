#pragma once

// Which graphics API the renderer asks Filament for.
//
// Chosen once, when an engine is built, and chosen here rather than in the
// renderer: the renderer says "whatever this platform uses", and everything
// after that is Filament's business. Nothing else in the renderer depends on
// the answer — the materials carry a shader for every backend they were
// compiled for, and Filament picks the one that matches.
//
// The platform's own choice comes from a macro, because it is a fact about
// the build. A host may ask for one by name, and so may the environment
// variable ORBIS_BACKEND, so that a backend can be tried on a machine whose
// default is a different one.

#include <vector>

#include <filament/Engine.h>

#include "orbis_renderer.h"

namespace orbis {

/// The backends to try, in the order to try them, for what a host asked for.
///
/// One entry when a backend was named, because a host that names one has a
/// reason and should be told when it cannot have it rather than given
/// another. More than one only for the platform default, where the later
/// entries are what to fall back on if the first will not start.
std::vector<OrbisBackend> backendCandidates(OrbisBackend asked);

/// Filament's own name for one.
filament::Engine::Backend filamentBackend(OrbisBackend backend);

/// A backend as a person would write it: "Metal", "Vulkan", "OpenGL".
const char *backendName(OrbisBackend backend);

/// The backend a name means, ignoring case, or DEFAULT for a name that is not
/// one of them.
OrbisBackend backendNamed(const char *name);

}  // namespace orbis
