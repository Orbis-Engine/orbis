/* Where the web build presents its frames: a canvas's WebGL 2 context.
 *
 * Worked out from Filament's own web pieces rather than guessed, because
 * "native window" means something different in a browser:
 *
 * - filament/backend/src/opengl/platforms/PlatformWebGL.cpp — the backend
 *   this build actually runs (see OrbisBackend.cpp: __EMSCRIPTEN__ asks for
 *   ORBIS_BACKEND_OPENGL, which is WebGL 2 in a browser) — implements
 *   createSwapChain(void *nativeWindow, uint64_t) as nothing more than
 *   `static_cast<SwapChain*>(nativeWindow)`. It is never dereferenced, only
 *   carried around as an opaque identity, and makeCurrent/commit are both
 *   empty: Emscripten's own GL emulation owns the real WebGL context and
 *   binds it to whichever canvas the embedding page set as `Module.canvas`
 *   before the module started, the first time a GL call needs one.
 * - Its sized overload — createSwapChain(width, height, flags), the one a
 *   headless surface needs — is unimplemented upstream ("TODO: implement
 *   headless SwapChain") and always returns null.
 * - web/filament-js/jsbindings.cpp's own `_createSwapChainForCanvas` works
 *   around exactly this by handing the canvas's CSS selector across as that
 *   pointer: `engine->createSwapChain((void*)persistentCanvasId->c_str())`,
 *   keeping the string alive for as long as the swap chain needs it.
 *
 * So the "window" a web host hands ORBIS_SURFACE_WINDOW through
 * orbis_surface_desc is that selector — "#canvas", say — not a real native
 * handle, and this surface's whole job is to keep it alive and pass it
 * through unchanged. ORBIS_SURFACE_HEADLESS has nowhere to go on this
 * backend: it still allocates cleanly, and then fails at allocate() with a
 * null chain, which is the ABI's ordinary "the renderer would not start"
 * path (see orbis_renderer_create in OrbisRendererC.cpp) rather than a
 * crash — a real limitation of PlatformWebGL today, not a bug introduced
 * here, and worth knowing before reaching for orbis_renderer_request_capture
 * on the web build.
 *
 * Kept beside the web build rather than in the shared source tree: it reads
 * like OrbisSurfaceHeadless.cpp's SharedChainSurface because the same single
 * "one shared chain, however many slots" shape is correct here too, but the
 * two must not both define OrbisCreateWindowSurface/OrbisCreateHeadlessSurface
 * — build.sh compiles every portable .cpp beside the renderer except this
 * one's sibling, precisely to avoid that clash.
 */

#include "OrbisSurface.h"

#include <filament/Engine.h>
#include <filament/SwapChain.h>

#include <string>
#include <utility>

namespace {

class WebCanvasSurface final : public OrbisSurface {
 public:
  explicit WebCanvasSurface(std::string selector)
      : _selector(std::move(selector)) {}

  bool allocate(filament::Engine *engine, uint32_t width, uint32_t height,
                filament::SwapChain **chains, int count) override {
    // Empty selector is the headless case: there is no windowless overload
    // on this backend, so this deliberately asks anyway and lets Filament
    // say no, rather than special-casing the failure here.
    _chain = _selector.empty()
                 ? engine->createSwapChain(
                       width, height, filament::SwapChain::CONFIG_READABLE)
                 : engine->createSwapChain(
                       const_cast<void *>(static_cast<const void *>(_selector.c_str())), 0);
    for (int i = 0; i < count; i++) chains[i] = _chain;
    return _chain != nullptr;
  }

  void release(filament::Engine *engine, filament::SwapChain **chains,
               int count) override {
    if (_chain != nullptr) engine->destroy(_chain);
    _chain = nullptr;
    for (int i = 0; i < count; i++) chains[i] = nullptr;
  }

  // No texture-sharing surface on the web: a canvas is shown by drawing into
  // it, not by handing a buffer to something else that composites it.
  void *retainPresented(int) override { return nullptr; }

  // ORBIS_DUMP_FRAME has no sandboxed-writable path in a browser; a host
  // that wants the picture reads the canvas itself, or asks for a capture.
  void writeFrame(int) override {}

 private:
  // Kept alive for exactly as long as the surface is: the selector this
  // object's swap chain was made from, which Filament's PlatformWebGL holds
  // onto as an opaque pointer for the swap chain's whole lifetime.
  std::string _selector;
  filament::SwapChain *_chain = nullptr;
};

}  // namespace

OrbisSurface *OrbisCreateHeadlessSurface() {
  return new WebCanvasSurface(std::string());
}

OrbisSurface *OrbisCreateWindowSurface(void *window) {
  // A C string selector, e.g. "#canvas" — orbis_web_host.cpp's
  // orbis_web_create_on_canvas is what a JavaScript host actually calls, and
  // it builds this same way. Falls back to Emscripten's own default canvas
  // id if a host passes null through the plain ABI directly.
  const char *selector =
      window != nullptr ? static_cast<const char *>(window) : "#canvas";
  return new WebCanvasSurface(std::string(selector));
}
