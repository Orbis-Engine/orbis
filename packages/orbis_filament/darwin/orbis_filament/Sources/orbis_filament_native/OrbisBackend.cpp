#include "OrbisBackend.h"

#include <cctype>
#include <cstdlib>
#include <string>

#if defined(_WIN32)
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace orbis {

bool backendLoadable(OrbisBackend backend) {
  if (backend != ORBIS_BACKEND_VULKAN) return true;
  // The names bluevk opens, platform by platform — libs/bluevk/src in
  // Filament — so the answer here is the answer it would get.
#if defined(_WIN32)
  HMODULE library = LoadLibraryA("vulkan-1.dll");
  if (library == nullptr) return false;
  FreeLibrary(library);
  return true;
#else
#if defined(__ANDROID__)
  const char *name = "libvulkan.so";
#elif defined(__APPLE__)
  const char *name = "libvulkan.1.dylib";
#else
  const char *name = "libvulkan.so.1";
#endif
  void *library = dlopen(name, RTLD_NOW | RTLD_LOCAL);
  if (library == nullptr) return false;
  dlclose(library);
  return true;
#endif
}

std::vector<OrbisBackend> backendCandidates(OrbisBackend asked) {
  // The override, for trying a backend on a machine whose default is another.
  // Only read when the host has not named one itself: a host that asks for
  // OpenGL has a reason, and a variable left set in somebody's shell should
  // not overrule it.
  if (asked == ORBIS_BACKEND_DEFAULT) {
    const char *named = std::getenv("ORBIS_BACKEND");
    if (named != nullptr && *named != '\0') asked = backendNamed(named);
  }
  if (asked != ORBIS_BACKEND_DEFAULT) return {asked};

#if defined(__APPLE__)
  // Metal, and only Metal. The materials are compiled for it alone unless
  // setup.sh is told otherwise, so falling back to OpenGL here would build an
  // engine that cannot load a single surface — and macOS's OpenGL stops at
  // 4.1, which is feature level 1, below the standard surface.
  return {ORBIS_BACKEND_METAL};
#elif defined(__EMSCRIPTEN__)
  // WebGL 2, which is Filament's OpenGL backend in a browser. WebGPU is where
  // the web is going and is reserved for it, but the release's matc cannot
  // compile a material for WebGPU yet, so defaulting to it would build an
  // engine with nothing it can draw.
  return {ORBIS_BACKEND_OPENGL};
#else
  // Android, Linux — the Steam Deck included — and Windows. Vulkan first,
  // because it is what Filament recommends on all three and what reaches the
  // third feature level on most hardware; OpenGL behind it for the machine
  // with no Vulkan driver at all, which is an old phone or a desktop in a
  // virtual machine.
  return {ORBIS_BACKEND_VULKAN, ORBIS_BACKEND_OPENGL};
#endif
}

filament::Engine::Backend filamentBackend(OrbisBackend backend) {
  using Backend = filament::Engine::Backend;
  switch (backend) {
    case ORBIS_BACKEND_METAL:
      return Backend::METAL;
    case ORBIS_BACKEND_VULKAN:
      return Backend::VULKAN;
    case ORBIS_BACKEND_OPENGL:
      return Backend::OPENGL;
    case ORBIS_BACKEND_WEBGPU:
      return Backend::WEBGPU;
    case ORBIS_BACKEND_DEFAULT:
      break;
  }
  return Backend::DEFAULT;
}

const char *backendName(OrbisBackend backend) {
  switch (backend) {
    case ORBIS_BACKEND_METAL:
      return "Metal";
    case ORBIS_BACKEND_VULKAN:
      return "Vulkan";
    case ORBIS_BACKEND_OPENGL:
      return "OpenGL";
    case ORBIS_BACKEND_WEBGPU:
      return "WebGPU";
    case ORBIS_BACKEND_DEFAULT:
      break;
  }
  return "the default backend";
}

OrbisBackend backendNamed(const char *name) {
  std::string lower(name != nullptr ? name : "");
  for (char &c : lower) c = char(std::tolower(static_cast<unsigned char>(c)));
  if (lower == "metal") return ORBIS_BACKEND_METAL;
  if (lower == "vulkan") return ORBIS_BACKEND_VULKAN;
  if (lower == "opengl" || lower == "gl") return ORBIS_BACKEND_OPENGL;
  if (lower == "webgpu") return ORBIS_BACKEND_WEBGPU;
  return ORBIS_BACKEND_DEFAULT;
}

}  // namespace orbis
