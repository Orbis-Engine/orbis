#ifndef ORBIS_RENDERER_H
#define ORBIS_RENDERER_H

/* The renderer, as C.
 *
 * Everything a host needs to drive Orbis's renderer without Objective-C,
 * without C++ and without Flutter: create one with a backend and a surface,
 * resize it, publish a scene, draw at a time, and read back what it drew, what
 * it cost and what it could not do. A Kotlin plugin calls this through JNI, a
 * Linux or Windows plugin calls it from C++, and a console host with no Flutter
 * at all calls it from main().
 *
 * C rather than C++ because a C ABI is the one every language and every
 * compiler agrees on: a C++ class compiled by one toolchain cannot be called
 * from code compiled by another, and a JNI or FFI binding can only name C.
 *
 * Handles are opaque. Arrays arrive as a pointer and a count, and every count
 * is checked against what the layout needs before anything is read — a host
 * that gets a stride wrong is told so by a return value, not by a crash.
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

#ifdef __cplusplus
}
#endif

#endif /* ORBIS_RENDERER_H */
