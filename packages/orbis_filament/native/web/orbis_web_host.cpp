/* A one-call entry point onto the C ABI, for JavaScript's ccall/cwrap.
 *
 * orbis_renderer.h is not changed for this: orbis_renderer_create takes an
 * orbis_surface_desc by pointer, and building one from JavaScript means
 * allocating wasm memory and laying out its fields by hand through
 * Module.setValue before every call — awkward for the one shape the web
 * actually needs, ORBIS_SURFACE_WINDOW onto a canvas selector string. This
 * gives the host page a plain call instead: backend, selector, width,
 * height, straight through to the unmodified ABI.
 *
 * A C ABI itself, same rules as orbis_renderer.h: a NULL handle in is a NULL
 * handle out, not a crash. Exported by build.sh's -sEXPORTED_FUNCTIONS, not
 * declared anywhere a Dart or Kotlin host would see — this is web-only.
 */

#include "orbis_renderer.h"

extern "C" orbis_renderer *orbis_web_create_on_canvas(OrbisBackend backend,
                                                       const char *selector,
                                                       uint32_t width,
                                                       uint32_t height) {
  orbis_surface_desc surface{ORBIS_SURFACE_WINDOW,
                             const_cast<char *>(selector)};
  return orbis_renderer_create(backend, &surface, width, height);
}
