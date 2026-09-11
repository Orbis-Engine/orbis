#include "OrbisRendererCore.h"

// The renderer's work, in the order OrbisRenderer.mm had it. See the header
// for how this file maps onto the old one.

#include <filament/LightManager.h>
#include <filament/Options.h>
#include <filament/RenderableManager.h>
#include <filament/TransformManager.h>
#include <filament/Viewport.h>
#include <geometry/SurfaceOrientation.h>
#include <gltfio/materials/uberarchive.h>
#include <image/Ktx1Bundle.h>
#include <ktxreader/Ktx1Reader.h>
#include <utils/EntityManager.h>
#include <utils/Panic.h>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <limits>

#include "OrbisBackend.h"
#include "OrbisDecals.h"

// M_PI is POSIX rather than C++, and MSVC only defines it when asked to.
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

using namespace filament;
using namespace filament::math;

namespace orbis {
namespace {

// The compiled materials and the lookup tables, as the C arrays setup.sh
// writes. In an anonymous namespace because xxd chooses their names and
// makes them global: a library other hosts link should not export
// `klit_opaqueMaterial` into their symbol table, and two copies of the
// renderer in one binary — as there briefly were while it moved — would not
// link at all.
#include "generated/lit_opaque_material.h"
#include "generated/sharpen_material.h"
#include "generated/smaa_edges_material.h"
#include "generated/smaa_weights_material.h"
#include "generated/smaa_blend_material.h"
#include "generated/bounce_material.h"
#include "generated/irradiance_material.h"
#include "generated/copy_material.h"
// SMAA's precomputed tables, fetched by setup.sh from the reference
// implementation. MIT, Jorge Jimenez et al. — see LICENSES/SMAA.txt.
#include "generated/AreaTex.h"
#include "generated/SearchTex.h"
#include "generated/LtcTables.h"
#include "generated/lit_transparent_material.h"
#include "generated/lit_fade_material.h"
#include "generated/lit_masked_material.h"
#include "generated/lit_add_material.h"
#include "generated/unlit_opaque_material.h"
#include "generated/unlit_transparent_material.h"
#include "generated/unlit_fade_material.h"
#include "generated/unlit_masked_material.h"
#include "generated/unlit_add_material.h"
#include "generated/video_opaque_material.h"
#include "generated/video_transparent_material.h"
#include "generated/video_fade_material.h"
#include "generated/video_masked_material.h"
#include "generated/video_add_material.h"
#include "generated/mist_material.h"
#include "generated/instanced_material.h"
#include "generated/shadowcatcher_material.h"
#include "generated/sky_material.h"
#include "generated/rain_material.h"

}  // namespace

