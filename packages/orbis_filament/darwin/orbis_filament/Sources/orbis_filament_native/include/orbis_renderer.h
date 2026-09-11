#ifndef ORBIS_RENDERER_H
#define ORBIS_RENDERER_H

/* The renderer, as C.
 *
 * Everything a host needs to drive Orbis's renderer without Objective-C,
 * without C++ and without Flutter: create one with a backend and a surface,
 * resize it, publish a scene, draw at a time, and read back what it drew, what
 * it cost and what it could not do. A Kotlin plugin calls this through JNI, a
 * Linux or Windows plugin calls it from C++, and a console host with no
 * Flutter at all calls it from main().
 *
 * C rather than C++ because a C ABI is the one every language and every
 * compiler agrees on: a C++ class compiled by one toolchain cannot be called
 * from code compiled by another, and a JNI or FFI binding can only name C.
 *
 * The rules, which every function below keeps:
 *
 *  - Handles are opaque, and every function takes NULL as a handle and
 *    returns ORBIS_ERROR_NULL rather than crashing.
 *  - Arrays arrive as a pointer and a length in elements. The length is
 *    checked against what the count and the layout need before anything is
 *    read, and a short array is ORBIS_ERROR_LENGTH with nothing applied — a
 *    host that gets a stride wrong is told by a return value, not by a crash.
 *    orbis_renderer_stride says how wide each row is, so a host need not
 *    copy the numbers.
 *  - Scene calls describe the whole of their part of the scene every time,
 *    as the Flutter plugin's do: anything not named has gone. The renderer
 *    works out what changed.
 *  - Nothing throws across this boundary. If Filament refuses something the
 *    renderer stops, the call returns ORBIS_ERROR_FAILED, and so does every
 *    call after it; orbis_renderer_destroy is still safe.
 *  - One thread drives a renderer, apart from orbis_renderer_set_camera,
 *    orbis_renderer_resize and orbis_renderer_copy_presented, which are safe
 *    from any thread.
 *
 * The row layouts are the Dart side's — OrbisLight, OrbisMaterial and the
 * rest in package:orbis_filament — and the documentation of each
 * orbis_renderer_* call is the documentation of the matching method in
 * OrbisRenderer.h, which this mirrors in the same order.
 */

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Which graphics API the renderer draws with.
 *
 * DEFAULT is the platform's own choice: Metal on Apple platforms, Vulkan on
 * Android, Linux (the Steam Deck included) and Windows with OpenGL as the
 * fallback where Vulkan will not start, and OpenGL — WebGL 2 — on the web.
 * WebGPU is reserved for the web and chosen only when asked for by name,
 * until the materials are compiled for it. The environment variable
 * ORBIS_BACKEND (metal, vulkan, opengl, webgpu) overrides DEFAULT, for
 * testing a backend on a machine whose default is another. */
typedef enum OrbisBackend {
  ORBIS_BACKEND_DEFAULT = 0,
  ORBIS_BACKEND_METAL = 1,
  ORBIS_BACKEND_VULKAN = 2,
  ORBIS_BACKEND_OPENGL = 3,
  ORBIS_BACKEND_WEBGPU = 4
} OrbisBackend;

/* What a call came to. Nought is success; everything else is negative. */
typedef enum orbis_result {
  ORBIS_OK = 0,
  /* A handle, or an array with a non-zero count, was NULL. */
  ORBIS_ERROR_NULL = -1,
  /* An array is shorter than its count and its row say it must be. */
  ORBIS_ERROR_LENGTH = -2,
  /* The renderer has stopped: Filament refused something, or it was
   * disposed. The reason was logged. */
  ORBIS_ERROR_FAILED = -3,
  /* An index names something past the end of its array: a render graph pass
   * reading a target the graph does not have, or a note that is not there. */
  ORBIS_ERROR_RANGE = -4
} orbis_result;

/* Where frames go. */
typedef enum orbis_surface_kind {
  /* Nowhere anybody sees: an offscreen swap chain, read back with
   * orbis_renderer_request_capture. Tests, servers, a console host that has
   * not opened a window. */
  ORBIS_SURFACE_HEADLESS = 0,
  /* A native window, in `window`: an ANativeWindow* on Android, an HWND on
   * Windows, an X11 Window or a wl_surface on Linux, a CAMetalLayer* on
   * Apple — whatever Filament's createSwapChain takes on that platform. */
  ORBIS_SURFACE_WINDOW = 1,
  /* The platform's texture-sharing surface, where it has one: on Apple, the
   * IOSurface-backed CVPixelBuffers the Flutter plugin hands to Flutter,
   * reached with orbis_renderer_copy_presented. Refused elsewhere. */
  ORBIS_SURFACE_PLATFORM = 2
} orbis_surface_kind;

typedef struct orbis_surface_desc {
  orbis_surface_kind kind;
  void *window;
} orbis_surface_desc;

/* The rows the scene calls take, so a host can size its arrays from the
 * renderer rather than from a copy of the numbers. */
typedef enum orbis_stride {
  ORBIS_STRIDE_TRANSFORM = 0,
  ORBIS_STRIDE_COLOUR,
  ORBIS_STRIDE_MATERIAL,
  ORBIS_STRIDE_MATERIAL_MAPS,
  ORBIS_STRIDE_VIDEO,
  ORBIS_STRIDE_LIGHT,
  ORBIS_STRIDE_DECAL,
  ORBIS_STRIDE_FOG,
  ORBIS_STRIDE_PROBE,
  ORBIS_STRIDE_FIELD,
  ORBIS_STRIDE_ENVIRONMENT,
  ORBIS_STRIDE_PASS,
  ORBIS_STRIDE_TARGET,
  ORBIS_STRIDE_GOD_RAYS,
  ORBIS_STRIDE_DISTORTION,
  ORBIS_STRIDE_POPULATION_BOUNDS,
  ORBIS_STRIDE_SPLAT,
  ORBIS_STRIDE_SPLAT_RECORD_BYTES,
  ORBIS_STRIDE_SKY,
  ORBIS_STRIDE_PRECIPITATION,
  ORBIS_STRIDE_OUTLINE,
  ORBIS_STRIDE_PIPELINE
} orbis_stride;

/* How wide one row of `which` is, in floats (bytes for a splat record), or
 * nought for a value this build does not know. */
uint32_t orbis_renderer_stride(orbis_stride which);

typedef struct orbis_renderer orbis_renderer;

/* ---- Lifetime ---- */

/* Starts Filament with `backend` onto `surface` (NULL is headless) at the
 * given size. NULL if the backend would not start or Filament refused, with
 * the reason logged. */
orbis_renderer *orbis_renderer_create(OrbisBackend backend,
                                      const orbis_surface_desc *surface,
                                      uint32_t width, uint32_t height);

/* Tears it down. NULL is fine. */
void orbis_renderer_destroy(orbis_renderer *renderer);

/* The backend the engine was built with. */
OrbisBackend orbis_renderer_backend(const orbis_renderer *renderer);

/* New dimensions, applied at the top of the next frame. Any thread. */
int orbis_renderer_resize(orbis_renderer *renderer, uint32_t width,
                          uint32_t height);

/* Draws one frame at `seconds` and presents it. */
int orbis_renderer_draw(orbis_renderer *renderer, double seconds);

/* ---- The scene ---- */

/* `count` objects: transforms are 16 floats each, column-major; colours 3;
 * meshes index `paths` or are -1 for the built-in cube; flags as
 * OrbisObject packs them; materials index the last apply_materials or are
 * -1; morph_counts say how many of `morph_weights` each takes, end to end. */
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
                                 uint32_t path_count);

int orbis_renderer_set_batching(orbis_renderer *renderer, int enabled);

/* `count` materials of ORBIS_STRIDE_MATERIAL floats and
 * ORBIS_STRIDE_MATERIAL_MAPS map indices each. Maps index `texture_paths`,
 * and `texture_srgb` has one entry per path. `videos` has one per material. */
int orbis_renderer_apply_materials(orbis_renderer *renderer, uint32_t count,
                                   const int64_t *keys, const int32_t *flags,
                                   const float *params, size_t param_floats,
                                   const int32_t *maps, size_t map_count,
                                   const char *const *texture_paths,
                                   const int32_t *texture_srgb,
                                   uint32_t texture_count,
                                   const int32_t *videos);

int orbis_renderer_set_pipeline(orbis_renderer *renderer, const float *params,
                                size_t count);

/* `count` videos of ORBIS_STRIDE_VIDEO floats; `paths` has one each. Where
 * the platform has no decoder yet, the notes say so and screens draw blank. */
int orbis_renderer_apply_videos(orbis_renderer *renderer, uint32_t count,
                                const int64_t *keys, const int32_t *flags,
                                const float *params, size_t param_floats,
                                const char *const *paths, uint32_t path_count);

/* `count` lights of ORBIS_STRIDE_LIGHT floats. */
int orbis_renderer_apply_lights(orbis_renderer *renderer, uint32_t count,
                                const int64_t *keys, const int32_t *kinds,
                                const int32_t *flags, const float *params,
                                size_t param_floats);

/* `count` decals of ORBIS_STRIDE_DECAL floats; `images` index `paths`. */
int orbis_renderer_apply_decals(orbis_renderer *renderer, uint32_t count,
                                const float *params, size_t param_floats,
                                const int32_t *images,
                                const char *const *paths, uint32_t path_count);

int orbis_renderer_set_fog(orbis_renderer *renderer, int enabled,
                           const float *params, size_t count);

int orbis_renderer_set_post_process(orbis_renderer *renderer,
                                    const float *params, size_t count);

/* `count` probes of ORBIS_STRIDE_PROBE floats. */
int orbis_renderer_apply_probes(orbis_renderer *renderer, uint32_t count,
                                const int64_t *keys, const float *params,
                                size_t param_floats);

/* One field of ORBIS_STRIDE_FIELD floats, filled from the target `from`. */
int orbis_renderer_apply_field(orbis_renderer *renderer, const float *params,
                               size_t count, const char *from);

/* Cubemap paths as cmgen writes them, either may be NULL or empty, and
 * ORBIS_STRIDE_ENVIRONMENT floats. */
int orbis_renderer_set_environment(orbis_renderer *renderer,
                                   const char *radiance, const char *skybox,
                                   const float *params, size_t count);

/* Passes of ORBIS_STRIDE_PASS floats, targets of ORBIS_STRIDE_TARGET, and a
 * name per target. */
int orbis_renderer_set_render_graph(orbis_renderer *renderer,
                                    uint32_t pass_count, const float *passes,
                                    size_t pass_floats, uint32_t target_count,
                                    const float *targets, size_t target_floats,
                                    const char *const *names,
                                    uint32_t name_count);

/* One row of god-ray settings, or none, and distortions end to end. */
int orbis_renderer_set_god_rays(orbis_renderer *renderer,
                                const float *god_rays, size_t god_ray_floats,
                                const float *distortions,
                                size_t distortion_floats);

/* `count` populations. bounds are ORBIS_STRIDE_POPULATION_BOUNDS floats
 * each; `changed` names the populations whose transforms (16 floats a
 * member) and colours (3) are packed end to end in that order. */
int orbis_renderer_apply_populations(
    orbis_renderer *renderer, uint32_t count, const int32_t *keys,
    const int32_t *counts, const int32_t *meshes, const int32_t *flags,
    const int32_t *revisions, const float *ranges, const float *bounds,
    size_t bound_floats, const char *const *paths, uint32_t path_count,
    const int32_t *changed, uint32_t changed_count, const float *transforms,
    size_t transform_floats, const float *colours, size_t colour_floats);

/* `count` splat clouds of ORBIS_STRIDE_SPLAT floats and a path each; the
 * `changed` in-memory clouds' records are in `data`, end to end. */
int orbis_renderer_apply_splats(orbis_renderer *renderer, uint32_t count,
                                const int32_t *keys, const int32_t *flags,
                                const int32_t *revisions, const float *params,
                                size_t param_floats, const char *const *paths,
                                uint32_t path_count, const int32_t *changed,
                                const int32_t *changed_counts,
                                uint32_t changed_count, const uint8_t *data,
                                size_t data_length);

int orbis_renderer_set_sky(orbis_renderer *renderer, int enabled,
                           const float *params, size_t count);

int orbis_renderer_set_precipitation(orbis_renderer *renderer, int enabled,
                                     const float *params, size_t count);

int orbis_renderer_set_sky_colour(orbis_renderer *renderer,
                                  const float colour[3], float ambient,
                                  int show_body);

/* Where the camera is, and when the host reckons that was, in its own
 * seconds. Any thread. */
int orbis_renderer_set_camera(orbis_renderer *renderer,
                              const float position[3], const float target[3],
                              float field_of_view, int orthographic,
                              float view_height, double at);

int orbis_renderer_set_exposure(orbis_renderer *renderer, float aperture,
                                float shutter, float sensitivity);

/* Objects to outline by key, and ORBIS_STRIDE_OUTLINE floats of style. */
int orbis_renderer_set_outline(orbis_renderer *renderer, const int64_t *keys,
                               uint32_t count, const float *params,
                               size_t param_floats);

/* ---- What it drew, and what it cost ---- */

/* Asks for the next frame drawn to be read back into memory. */
int orbis_renderer_request_capture(orbis_renderer *renderer);

/* The last frame read back: RGBA8, top row first. Returns the bytes it
 * takes, and copies them into `rgba` when `capacity` is at least that. Nought
 * until a frame has arrived, which is a frame or two after it was asked for.
 * `width` and `height` may be NULL. */
size_t orbis_renderer_read_capture(orbis_renderer *renderer, uint8_t *rgba,
                                   size_t capacity, uint32_t *width,
                                   uint32_t *height);

typedef struct orbis_stats {
  /* Medians of recent frames, in milliseconds; nought until the backend
   * has reported. */
  double gpu_milliseconds;
  double cpu_milliseconds;
  /* What the last apply_objects batched. */
  uint32_t batched_objects;
  uint32_t batch_groups;
  /* How many passes the last frame ran; see orbis_renderer_pass_timings. */
  uint32_t pass_count;
} orbis_stats;

int orbis_renderer_stats(orbis_renderer *renderer, orbis_stats *stats);

/* What each pass of the last frame cost and drew, up to `capacity` of them.
 * Returns how many there were. Either array may be NULL. */
uint32_t orbis_renderer_pass_timings(orbis_renderer *renderer,
                                     double *milliseconds, int32_t *drawn,
                                     uint32_t capacity);

/* The most recently presented frame, retained, for a PLATFORM surface: a
 * CVPixelBufferRef on Apple. NULL for any other surface. Any thread. */
void *orbis_renderer_copy_presented(orbis_renderer *renderer);

/* ---- What it could not do ---- */

/* Takes a snapshot of what the scene asked for that could not be given, and
 * returns how many notes it holds. */
uint32_t orbis_renderer_notes(orbis_renderer *renderer);

/* One note of the last snapshot: what it is about, and what it says. The
 * strings belong to the renderer and last until the next
 * orbis_renderer_notes or orbis_renderer_destroy. */
int orbis_renderer_note(orbis_renderer *renderer, uint32_t index,
                        const char **about, const char **saying);

#ifdef __cplusplus
}
#endif

#endif /* ORBIS_RENDERER_H */
