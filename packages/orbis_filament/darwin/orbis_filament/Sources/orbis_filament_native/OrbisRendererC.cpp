#include "orbis_renderer.h"

// The C ABI over orbis::Renderer.
//
// Every function here does three things and no more: refuses what would make
// the renderer read past an array, turns C's types into the core's, and
// makes sure nothing thrown inside Filament unwinds into a caller that cannot
// catch it. The renderer's behaviour is the core's; nothing is decided here.

#include <algorithm>
#include <cstring>
#include <exception>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "OrbisDecals.h"
#include "OrbisOutline.h"
#include "OrbisRendererCore.h"
#include "OrbisShadows.h"
#include "OrbisSplats.h"
#include "ScreenEffects.h"

struct orbis_renderer {
  std::unique_ptr<orbis::Renderer> core;

  /// The last snapshot orbis_renderer_notes took, which orbis_renderer_note
  /// hands out pointers into.
  std::vector<std::pair<std::string, std::string>> notes;

  /// Set when a call threw. A renderer Filament has refused is not given
  /// another chance to do the same thing again.
  bool failed = false;
};

namespace {

// The blocks the renderer reads a fixed number of floats from, with no count
// of its own. The Dart side packs them (OrbisFog.stride and the rest) and the
// Swift plugin checks the same numbers before it calls; they are checked
// again here because a C host has no Swift in front of it.
constexpr size_t kFogFloats = 16;
constexpr size_t kPrecipitationFloats = 12;
constexpr size_t kSkyFloats = 34;
constexpr size_t kEnvironmentFloats = 4;
constexpr size_t kPopulationBounds = 6;
constexpr size_t kTransformFloats = 16;
constexpr size_t kColourFloats = 3;

/// Whether an array of `have` elements holds `count` rows of `stride`, and
/// is there at all when it has to be. Divided rather than multiplied, so a
/// count near the top of its range cannot wrap round and look small.
bool holds(const void *array, size_t have, size_t count, size_t stride) {
  if (count == 0) return true;
  if (array == nullptr || stride == 0) return false;
  return have / stride >= count;
}

/// Whether every array a call reads `count` entries of is there.
bool present(uint32_t count, std::initializer_list<const void *> arrays) {
  if (count == 0) return true;
  for (const void *array : arrays) {
    if (array == nullptr) return false;
  }
  return true;
}

std::vector<std::string> strings(const char *const *items, uint32_t count) {
  std::vector<std::string> out;
  out.reserve(count);
  for (uint32_t i = 0; i < count; i++) {
    const char *item = items != nullptr ? items[i] : nullptr;
    out.emplace_back(item != nullptr ? item : "");
  }
  return out;
}

std::string text(const char *from) { return from != nullptr ? from : ""; }

/// Runs one call into the core, turning a throw into a result.
template <typename Body>
int guarded(orbis_renderer *renderer, Body body) {
  if (renderer == nullptr || renderer->core == nullptr) return ORBIS_ERROR_NULL;
  if (renderer->failed) return ORBIS_ERROR_FAILED;
  try {
    body(*renderer->core);
    return ORBIS_OK;
  } catch (const std::exception &error) {
    orbis::log("[orbis] the renderer refused a call and has stopped: %s",
               error.what());
  } catch (...) {
    orbis::log("[orbis] the renderer refused a call and has stopped.");
  }
  renderer->failed = true;
  return ORBIS_ERROR_FAILED;
}

}  // namespace

extern "C" {

uint32_t orbis_renderer_stride(orbis_stride which) {
  switch (which) {
    case ORBIS_STRIDE_TRANSFORM:
      return uint32_t(kTransformFloats);
    case ORBIS_STRIDE_COLOUR:
      return uint32_t(kColourFloats);
    case ORBIS_STRIDE_MATERIAL:
      return uint32_t(orbis::kMaterialParams);
    case ORBIS_STRIDE_MATERIAL_MAPS:
      return uint32_t(orbis::kMaterialMaps);
    case ORBIS_STRIDE_VIDEO:
      return uint32_t(orbis::kVideoParams);
    case ORBIS_STRIDE_LIGHT:
      return orbis::kLightStride;
    case ORBIS_STRIDE_DECAL:
      return uint32_t(orbis::kDecalStride);
    case ORBIS_STRIDE_FOG:
      return uint32_t(kFogFloats);
    case ORBIS_STRIDE_PROBE:
      return orbis::kProbeStride;
    case ORBIS_STRIDE_FIELD:
      return orbis::kFieldStride;
    case ORBIS_STRIDE_ENVIRONMENT:
      return uint32_t(kEnvironmentFloats);
    case ORBIS_STRIDE_PASS:
      return orbis::kPassStride;
    case ORBIS_STRIDE_TARGET:
      return orbis::kTargetStride;
    case ORBIS_STRIDE_GOD_RAYS:
      return uint32_t(orbis::kGodRayStride);
    case ORBIS_STRIDE_DISTORTION:
      return uint32_t(orbis::kDistortionStride);
    case ORBIS_STRIDE_POPULATION_BOUNDS:
      return uint32_t(kPopulationBounds);
    case ORBIS_STRIDE_SPLAT:
      return uint32_t(orbis::kSplatParams);
    case ORBIS_STRIDE_SPLAT_RECORD_BYTES:
      return uint32_t(orbis::kSplatRecordBytes);
    case ORBIS_STRIDE_SKY:
      return uint32_t(kSkyFloats);
    case ORBIS_STRIDE_PRECIPITATION:
      return uint32_t(kPrecipitationFloats);
    case ORBIS_STRIDE_OUTLINE:
      return uint32_t(orbis::kOutlineParams);
    case ORBIS_STRIDE_PIPELINE:
      return uint32_t(orbis::pipeline::kPipelineStride);
  }
  return 0;
}

// ---- Lifetime ----

orbis_renderer *orbis_renderer_create(OrbisBackend backend,
                                      const orbis_surface_desc *surface,
                                      uint32_t width, uint32_t height) {
  const orbis_surface_kind kind =
      surface != nullptr ? surface->kind : ORBIS_SURFACE_HEADLESS;
  OrbisSurface *made = nullptr;
  switch (kind) {
    case ORBIS_SURFACE_HEADLESS:
      made = OrbisCreateHeadlessSurface();
      break;
    case ORBIS_SURFACE_WINDOW:
      if (surface->window == nullptr) return nullptr;
      made = OrbisCreateWindowSurface(surface->window);
      break;
    case ORBIS_SURFACE_PLATFORM:
#if ORBIS_PLATFORM_APPLE
      made = OrbisCreateSurface();
      break;
#else
      orbis::log("[orbis] this platform has no texture-sharing surface yet; "
                 "draw into a window or a headless one.");
      return nullptr;
#endif
  }
  if (made == nullptr) return nullptr;

  orbis_renderer *renderer = nullptr;
  try {
    renderer = new orbis_renderer();
    renderer->core = std::make_unique<orbis::Renderer>(made, backend);
  } catch (...) {
    // Nothing took the surface, so it is still this function's.
    delete made;
    delete renderer;
    return nullptr;
  }
  // The core owns the surface from here, and its destructor gives it back.
  if (!renderer->core->initWithWidth(width, height)) {
    delete renderer;
    return nullptr;
  }
  return renderer;
}

void orbis_renderer_destroy(orbis_renderer *renderer) {
  if (renderer == nullptr) return;
  try {
    renderer->core.reset();
  } catch (...) {
    // Teardown that throws leaves nothing more to be done about it here.
  }
  delete renderer;
}

OrbisBackend orbis_renderer_backend(const orbis_renderer *renderer) {
  if (renderer == nullptr || renderer->core == nullptr) {
    return ORBIS_BACKEND_DEFAULT;
  }
  return renderer->core->backend();
}

int orbis_renderer_resize(orbis_renderer *renderer, uint32_t width,
                          uint32_t height) {
  return guarded(renderer, [&](orbis::Renderer &core) {
    core.resizeToWidth(width, height);
  });
}

int orbis_renderer_draw(orbis_renderer *renderer, double seconds) {
  return guarded(renderer,
                 [&](orbis::Renderer &core) { core.renderAtTime(seconds); });
}

// ---- The scene ----

int orbis_renderer_apply_objects(orbis_renderer *renderer, uint32_t count,
                                 const int64_t *keys,
                                 const float *transforms,
                                 size_t transform_floats,
                                 const float *colours, size_t colour_floats,
                                 const int32_t *meshes, const int32_t *flags,
                                 const int32_t *materials,
                                 const int32_t *morph_counts,
                                 const float *morph_weights,
                                 size_t morph_weight_floats,
                                 const char *const *paths,
                                 uint32_t path_count) {
  if (renderer == nullptr) return ORBIS_ERROR_NULL;
  if (!present(count, {keys, meshes, flags, materials, morph_counts})) {
    return ORBIS_ERROR_NULL;
  }
  if (!holds(transforms, transform_floats, count, kTransformFloats) ||
      !holds(colours, colour_floats, count, kColourFloats)) {
    return ORBIS_ERROR_LENGTH;
  }
  // The shapes are end to end, so what they need is the sum of the counts.
  size_t weights = 0;
  for (uint32_t i = 0; i < count; i++) {
    weights += size_t(std::max(morph_counts[i], 0));
  }
  if (!holds(morph_weights, morph_weight_floats, weights, 1)) {
    return ORBIS_ERROR_LENGTH;
  }
  if (path_count > 0 && paths == nullptr) return ORBIS_ERROR_NULL;
  const std::vector<std::string> named = strings(paths, path_count);
  static const float kNoWeights[1] = {0.0f};
  return guarded(renderer, [&](orbis::Renderer &core) {
    core.applyObjects(keys, transforms, colours, meshes, flags, materials,
                      morph_counts,
                      morph_weights != nullptr ? morph_weights : kNoWeights,
                      named, count);
  });
}

int orbis_renderer_set_batching(orbis_renderer *renderer, int enabled) {
  return guarded(renderer,
                 [&](orbis::Renderer &core) { core.setBatching(enabled != 0); });
}

int orbis_renderer_apply_materials(orbis_renderer *renderer, uint32_t count,
                                   const int64_t *keys, const int32_t *flags,
                                   const float *params, size_t param_floats,
                                   const int32_t *maps, size_t map_count,
                                   const char *const *texture_paths,
                                   const int32_t *texture_srgb,
                                   uint32_t texture_count,
                                   const int32_t *videos) {
  if (renderer == nullptr) return ORBIS_ERROR_NULL;
  if (!present(count, {keys, flags, videos})) return ORBIS_ERROR_NULL;
  if (!holds(params, param_floats, count, orbis::kMaterialParams) ||
      !holds(maps, map_count, count, orbis::kMaterialMaps)) {
    return ORBIS_ERROR_LENGTH;
  }
  if (!present(texture_count, {texture_paths, texture_srgb})) {
    return ORBIS_ERROR_NULL;
  }
  const std::vector<std::string> named = strings(texture_paths, texture_count);
  return guarded(renderer, [&](orbis::Renderer &core) {
    core.applyMaterials(keys, flags, params, maps, named, texture_srgb, videos,
                        count);
  });
}

int orbis_renderer_set_pipeline(orbis_renderer *renderer, const float *params,
                                size_t count) {
  if (renderer == nullptr) return ORBIS_ERROR_NULL;
  // The whole block: the pipeline reads its dials by position, and a short
  // one would be read past its end rather than defaulted.
  if (!holds(params, count, 1, orbis::pipeline::kPipelineStride)) {
    return ORBIS_ERROR_LENGTH;
  }
  return guarded(renderer,
                 [&](orbis::Renderer &core) { core.setPipeline(params, count); });
}

int orbis_renderer_apply_videos(orbis_renderer *renderer, uint32_t count,
                                const int64_t *keys, const int32_t *flags,
                                const float *params, size_t param_floats,
                                const char *const *paths,
                                uint32_t path_count) {
  if (renderer == nullptr) return ORBIS_ERROR_NULL;
  if (!present(count, {keys, flags})) return ORBIS_ERROR_NULL;
  if (!holds(params, param_floats, count, orbis::kVideoParams)) {
    return ORBIS_ERROR_LENGTH;
  }
  if (path_count > 0 && paths == nullptr) return ORBIS_ERROR_NULL;
  const std::vector<std::string> named = strings(paths, path_count);
  return guarded(renderer, [&](orbis::Renderer &core) {
    core.applyVideos(keys, flags, params, named, count);
  });
}

int orbis_renderer_apply_lights(orbis_renderer *renderer, uint32_t count,
                                const int64_t *keys, const int32_t *kinds,
                                const int32_t *flags, const float *params,
                                size_t param_floats) {
  if (renderer == nullptr) return ORBIS_ERROR_NULL;
  if (!present(count, {keys, kinds, flags})) return ORBIS_ERROR_NULL;
  if (!holds(params, param_floats, count, orbis::kLightStride)) {
    return ORBIS_ERROR_LENGTH;
  }
  return guarded(renderer, [&](orbis::Renderer &core) {
    core.applyLights(keys, kinds, flags, params, count);
  });
}

int orbis_renderer_apply_decals(orbis_renderer *renderer, uint32_t count,
                                const float *params, size_t param_floats,
                                const int32_t *images,
                                const char *const *paths,
                                uint32_t path_count) {
  if (renderer == nullptr) return ORBIS_ERROR_NULL;
  if (!present(count, {images})) return ORBIS_ERROR_NULL;
  if (!holds(params, param_floats, count, orbis::kDecalStride)) {
    return ORBIS_ERROR_LENGTH;
  }
  if (path_count > 0 && paths == nullptr) return ORBIS_ERROR_NULL;
  const std::vector<std::string> named = strings(paths, path_count);
  return guarded(renderer, [&](orbis::Renderer &core) {
    core.applyDecals(params, images, named, count);
  });
}

int orbis_renderer_set_fog(orbis_renderer *renderer, int enabled,
                           const float *params, size_t count) {
  if (renderer == nullptr) return ORBIS_ERROR_NULL;
  if (!holds(params, count, 1, kFogFloats)) return ORBIS_ERROR_LENGTH;
  return guarded(renderer, [&](orbis::Renderer &core) {
    core.setFogEnabled(enabled != 0, params);
  });
}

int orbis_renderer_set_post_process(orbis_renderer *renderer,
                                    const float *params, size_t count) {
  if (renderer == nullptr) return ORBIS_ERROR_NULL;
  // Read one number at a time against the count, so any length is safe.
  if (count > 0 && params == nullptr) return ORBIS_ERROR_NULL;
  return guarded(renderer, [&](orbis::Renderer &core) {
    core.setPostProcess(params, count);
  });
}

int orbis_renderer_apply_probes(orbis_renderer *renderer, uint32_t count,
                                const int64_t *keys, const float *params,
                                size_t param_floats) {
  if (renderer == nullptr) return ORBIS_ERROR_NULL;
  if (!present(count, {keys})) return ORBIS_ERROR_NULL;
  if (!holds(params, param_floats, count, orbis::kProbeStride)) {
    return ORBIS_ERROR_LENGTH;
  }
  return guarded(renderer, [&](orbis::Renderer &core) {
    core.applyProbes(keys, params, count);
  });
}

int orbis_renderer_apply_field(orbis_renderer *renderer, const float *params,
                               size_t count, const char *from) {
  if (renderer == nullptr) return ORBIS_ERROR_NULL;
  if (!holds(params, count, 1, orbis::kFieldStride)) return ORBIS_ERROR_LENGTH;
  const std::string source = text(from);
  return guarded(renderer, [&](orbis::Renderer &core) {
    core.applyField(params, source);
  });
}

int orbis_renderer_set_environment(orbis_renderer *renderer,
                                   const char *radiance, const char *skybox,
                                   const float *params, size_t count) {
  if (renderer == nullptr) return ORBIS_ERROR_NULL;
  if (!holds(params, count, 1, kEnvironmentFloats)) return ORBIS_ERROR_LENGTH;
  const std::string light = text(radiance);
  const std::string backdrop = text(skybox);
  return guarded(renderer, [&](orbis::Renderer &core) {
    core.setEnvironmentRadiance(light, backdrop, params);
  });
}

int orbis_renderer_set_render_graph(orbis_renderer *renderer,
                                    uint32_t pass_count, const float *passes,
                                    size_t pass_floats, uint32_t target_count,
                                    const float *targets, size_t target_floats,
                                    const char *const *names,
                                    uint32_t name_count) {
  if (renderer == nullptr) return ORBIS_ERROR_NULL;
  if (!holds(passes, pass_floats, pass_count, orbis::kPassStride) ||
      !holds(targets, target_floats, target_count, orbis::kTargetStride)) {
    return ORBIS_ERROR_LENGTH;
  }
  // A pass reads targets by index, and the renderer trusts the index: the
  // Dart graph that writes one never names a target it does not have. A C
  // host is told instead.
  for (uint32_t p = 0; p < pass_count; p++) {
    const float *row = passes + size_t(p) * orbis::kPassStride;
    for (int r = 4; r < 8; r++) {
      if (int(row[r]) >= int(target_count)) return ORBIS_ERROR_RANGE;
    }
  }
  if (name_count > 0 && names == nullptr) return ORBIS_ERROR_NULL;
  const std::vector<std::string> named = strings(names, name_count);
  return guarded(renderer, [&](orbis::Renderer &core) {
    core.setRenderGraph(passes, pass_count, targets, target_count, named);
  });
}

int orbis_renderer_set_god_rays(orbis_renderer *renderer,
                                const float *god_rays, size_t god_ray_floats,
                                const float *distortions,
                                size_t distortion_floats) {
  if (renderer == nullptr) return ORBIS_ERROR_NULL;
  // ScreenEffects reads whole rows of what it is given and takes a row that
  // is not whole as none, so any length is safe once the pointers are there.
  if ((god_ray_floats > 0 && god_rays == nullptr) ||
      (distortion_floats > 0 && distortions == nullptr)) {
    return ORBIS_ERROR_NULL;
  }
  return guarded(renderer, [&](orbis::Renderer &core) {
    core.setGodRays(god_rays, god_ray_floats, distortions, distortion_floats);
  });
}

int orbis_renderer_apply_populations(
    orbis_renderer *renderer, uint32_t count, const int32_t *keys,
    const int32_t *counts, const int32_t *meshes, const int32_t *flags,
    const int32_t *revisions, const float *ranges, const float *bounds,
    size_t bound_floats, const char *const *paths, uint32_t path_count,
    const int32_t *changed, uint32_t changed_count, const float *transforms,
    size_t transform_floats, const float *colours, size_t colour_floats) {
  if (renderer == nullptr) return ORBIS_ERROR_NULL;
  if (!present(count, {keys, counts, meshes, flags, revisions, ranges})) {
    return ORBIS_ERROR_NULL;
  }
  if (!holds(bounds, bound_floats, count, kPopulationBounds)) {
    return ORBIS_ERROR_LENGTH;
  }
  if (changed_count > 0 && changed == nullptr) return ORBIS_ERROR_NULL;
  // The members that arrive are the changed populations', end to end — the
  // same walk the renderer makes to find where each one starts.
  size_t members = 0;
  for (uint32_t c = 0; c < changed_count; c++) {
    for (uint32_t i = 0; i < count; i++) {
      if (keys[i] != changed[c]) continue;
      members += size_t(std::max(counts[i], 0));
      break;
    }
  }
  if (!holds(transforms, transform_floats, members, kTransformFloats) ||
      !holds(colours, colour_floats, members, kColourFloats)) {
    return ORBIS_ERROR_LENGTH;
  }
  if (path_count > 0 && paths == nullptr) return ORBIS_ERROR_NULL;
  const std::vector<std::string> named = strings(paths, path_count);
  return guarded(renderer, [&](orbis::Renderer &core) {
    core.applyPopulations(keys, counts, meshes, flags, revisions, ranges,
                          bounds, named, changed, changed_count, transforms,
                          colours, count);
  });
}

int orbis_renderer_apply_splats(orbis_renderer *renderer, uint32_t count,
                                const int32_t *keys, const int32_t *flags,
                                const int32_t *revisions, const float *params,
                                size_t param_floats, const char *const *paths,
                                uint32_t path_count, const int32_t *changed,
                                const int32_t *changed_counts,
                                uint32_t changed_count, const uint8_t *data,
                                size_t data_length) {
  if (renderer == nullptr) return ORBIS_ERROR_NULL;
  if (!present(count, {keys, flags, revisions})) return ORBIS_ERROR_NULL;
  if (!holds(params, param_floats, count, orbis::kSplatParams)) {
    return ORBIS_ERROR_LENGTH;
  }
  if (!present(changed_count, {changed, changed_counts})) {
    return ORBIS_ERROR_NULL;
  }
  // The records themselves are measured against data_length by the splat
  // set, which stops at the first cloud that would run past the end.
  if (data_length > 0 && data == nullptr) return ORBIS_ERROR_NULL;
  if (path_count > 0 && paths == nullptr) return ORBIS_ERROR_NULL;
  const std::vector<std::string> named = strings(paths, path_count);
  return guarded(renderer, [&](orbis::Renderer &core) {
    core.applySplats(keys, flags, revisions, params, named, changed,
                     changed_counts, changed_count, data, data_length, count);
  });
}

int orbis_renderer_set_sky(orbis_renderer *renderer, int enabled,
                           const float *params, size_t count) {
  if (renderer == nullptr) return ORBIS_ERROR_NULL;
  if (!holds(params, count, 1, kSkyFloats)) return ORBIS_ERROR_LENGTH;
  return guarded(renderer, [&](orbis::Renderer &core) {
    core.setSkyEnabled(enabled != 0, params);
  });
}

int orbis_renderer_set_precipitation(orbis_renderer *renderer, int enabled,
                                     const float *params, size_t count) {
  if (renderer == nullptr) return ORBIS_ERROR_NULL;
  if (!holds(params, count, 1, kPrecipitationFloats)) {
    return ORBIS_ERROR_LENGTH;
  }
  return guarded(renderer, [&](orbis::Renderer &core) {
    core.setPrecipitationEnabled(enabled != 0, params);
  });
}

int orbis_renderer_set_sky_colour(orbis_renderer *renderer,
                                  const float colour[3], float ambient,
                                  int show_body) {
  if (renderer == nullptr || colour == nullptr) return ORBIS_ERROR_NULL;
  return guarded(renderer, [&](orbis::Renderer &core) {
    core.setSkyColour(colour, ambient, show_body != 0);
  });
}

int orbis_renderer_set_camera(orbis_renderer *renderer,
                              const float position[3], const float target[3],
                              float field_of_view, int orthographic,
                              float view_height, double at) {
  if (renderer == nullptr || position == nullptr || target == nullptr) {
    return ORBIS_ERROR_NULL;
  }
  return guarded(renderer, [&](orbis::Renderer &core) {
    core.setCameraPosition(position, target, field_of_view, orthographic != 0,
                           view_height, at);
  });
}

int orbis_renderer_set_exposure(orbis_renderer *renderer, float aperture,
                                float shutter, float sensitivity) {
  return guarded(renderer, [&](orbis::Renderer &core) {
    core.setExposure(aperture, shutter, sensitivity);
  });
}

int orbis_renderer_set_outline(orbis_renderer *renderer, const int64_t *keys,
                               uint32_t count, const float *params,
                               size_t param_floats) {
  if (renderer == nullptr) return ORBIS_ERROR_NULL;
  if (!present(count, {keys})) return ORBIS_ERROR_NULL;
  if (!holds(params, param_floats, 1, orbis::kOutlineParams)) {
    return ORBIS_ERROR_LENGTH;
  }
  return guarded(renderer, [&](orbis::Renderer &core) {
    core.setOutlineKeys(keys, count, params);
  });
}

// ---- What it drew, and what it cost ----

int orbis_renderer_request_capture(orbis_renderer *renderer) {
  return guarded(renderer,
                 [](orbis::Renderer &core) { core.requestCapture(); });
}

size_t orbis_renderer_read_capture(orbis_renderer *renderer, uint8_t *rgba,
                                   size_t capacity, uint32_t *width,
                                   uint32_t *height) {
  if (renderer == nullptr || renderer->core == nullptr) return 0;
  std::vector<uint8_t> pixels;
  uint32_t wide = 0;
  uint32_t tall = 0;
  if (!renderer->core->capturedFrame(pixels, wide, tall)) return 0;
  if (width != nullptr) *width = wide;
  if (height != nullptr) *height = tall;
  if (rgba != nullptr && capacity >= pixels.size()) {
    std::memcpy(rgba, pixels.data(), pixels.size());
  }
  return pixels.size();
}

int orbis_renderer_stats(orbis_renderer *renderer, orbis_stats *stats) {
  if (stats == nullptr) return ORBIS_ERROR_NULL;
  return guarded(renderer, [&](orbis::Renderer &core) {
    stats->gpu_milliseconds = core.gpuMilliseconds();
    stats->cpu_milliseconds = core.cpuMilliseconds();
    stats->batched_objects = core.batchedObjects();
    stats->batch_groups = core.batchGroups();
    stats->pass_count = uint32_t(core.passTimings().size());
  });
}

uint32_t orbis_renderer_pass_timings(orbis_renderer *renderer,
                                     double *milliseconds, int32_t *drawn,
                                     uint32_t capacity) {
  if (renderer == nullptr || renderer->core == nullptr) return 0;
  const std::vector<orbis::PassTiming> timings = renderer->core->passTimings();
  for (uint32_t i = 0; i < capacity && i < timings.size(); i++) {
    if (milliseconds != nullptr) milliseconds[i] = timings[i].milliseconds;
    if (drawn != nullptr) drawn[i] = timings[i].drawn;
  }
  return uint32_t(timings.size());
}

void *orbis_renderer_copy_presented(orbis_renderer *renderer) {
  if (renderer == nullptr || renderer->core == nullptr) return nullptr;
  return renderer->core->copyPresentedBuffer();
}

// ---- What it could not do ----

uint32_t orbis_renderer_notes(orbis_renderer *renderer) {
  if (renderer == nullptr || renderer->core == nullptr) return 0;
  renderer->notes.clear();
  for (const auto &note : renderer->core->notes()) {
    renderer->notes.emplace_back(note.first, note.second);
  }
  return uint32_t(renderer->notes.size());
}

int orbis_renderer_note(orbis_renderer *renderer, uint32_t index,
                        const char **about, const char **saying) {
  if (renderer == nullptr) return ORBIS_ERROR_NULL;
  if (index >= renderer->notes.size()) return ORBIS_ERROR_RANGE;
  if (about != nullptr) *about = renderer->notes[index].first.c_str();
  if (saying != nullptr) *saying = renderer->notes[index].second.c_str();
  return ORBIS_OK;
}

}  // extern "C"
