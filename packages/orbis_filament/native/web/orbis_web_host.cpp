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
 * It also makes the WebGL 2 context that ABI call needs to find already
 * current, which nothing else in this build does — found by testing, not
 * documented anywhere obvious. Filament's own PlatformWebGL
 * (filament/backend/src/opengl/platforms/PlatformWebGL.cpp in the fork)
 * never calls emscripten_webgl_create_context, and neither does Emscripten
 * implicitly just because -sUSE_WEBGL2=1 was linked and Module.canvas is
 * set: the very first GL call Engine::create makes — glGetString, querying
 * the version string — reached Emscripten's library_webgl.js with no
 * current context and threw "Cannot read properties of undefined (reading
 * 'getParameter')", which is that library reading a context variable that
 * was never set. Filament's own filament.js sidesteps this because
 * Emscripten's GL library creates a context lazily the first time
 * SOMETHING asks for one through the html5.h API — which filament.js's
 * generated Embind glue does on the JS side before Engine::create ever
 * runs, and this build has no equivalent JS glue, so it is done here
 * instead, in C++, before the ABI call that needs it.
 *
 * A C ABI itself, same rules as orbis_renderer.h: a NULL handle in is a NULL
 * handle out, not a crash. Exported by build.sh's -sEXPORTED_FUNCTIONS, not
 * declared anywhere a Dart or Kotlin host would see — this is web-only.
 */

#include "orbis_renderer.h"

#include <emscripten/html5.h>

extern "C" orbis_renderer *orbis_web_create_on_canvas(OrbisBackend backend,
                                                       const char *selector,
                                                       uint32_t width,
                                                       uint32_t height) {
  EmscriptenWebGLContextAttributes attributes;
  emscripten_webgl_init_context_attributes(&attributes);
  attributes.majorVersion = 2;
  attributes.minorVersion = 0;
  // Filament composites nothing with the page behind the canvas and draws
  // its own depth/stencil-using passes into its own render targets, not the
  // default framebuffer's; alpha/premultipliedAlpha off avoids the browser
  // blending the canvas against the page, and depth/stencil on match what a
  // native GL context would hand Filament by default.
  attributes.alpha = false;
  attributes.depth = true;
  attributes.stencil = true;
  attributes.antialias = false;

  const EMSCRIPTEN_WEBGL_CONTEXT_HANDLE context =
      emscripten_webgl_create_context(selector, &attributes);
  if (context <= 0 ||
      emscripten_webgl_make_context_current(context) != EMSCRIPTEN_RESULT_SUCCESS) {
    return nullptr;
  }

  orbis_surface_desc surface{ORBIS_SURFACE_WINDOW,
                             const_cast<char *>(selector)};
  return orbis_renderer_create(backend, &surface, width, height);
}
