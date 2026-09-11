#include "OrbisSurface.h"

#include <filament/Engine.h>
#include <filament/SwapChain.h>

/// Presentation where there is no texture to share: into a native window, or
/// into nothing anybody sees.
///
/// One swap chain, lent to every slot the renderer asks for. The renderer
/// alternates between buffers because on Apple each is a separate image that
/// Flutter samples while the next is drawn. A window has its own buffering
/// behind one swap chain — and two chains onto one window is an error on
/// Vulkan — and an offscreen chain is only ever read back, so both are one
/// chain however many slots there are.
namespace {

class SharedChainSurface final : public OrbisSurface {
 public:
  explicit SharedChainSurface(void *window) : _window(window) {}

  bool allocate(filament::Engine *engine, uint32_t width, uint32_t height,
                filament::SwapChain **chains, int count) override {
    // Readable when offscreen, because being read back is the whole point of
    // it. Not for a window, where the flag can cost the driver a copy.
    _chain = _window != nullptr
                 ? engine->createSwapChain(_window, 0)
                 : engine->createSwapChain(
                       width, height, filament::SwapChain::CONFIG_READABLE);
    for (int i = 0; i < count; i++) chains[i] = _chain;
    return _chain != nullptr;
  }

  void release(filament::Engine *engine, filament::SwapChain **chains,
               int count) override {
    if (_chain != nullptr) engine->destroy(_chain);
    _chain = nullptr;
    for (int i = 0; i < count; i++) chains[i] = nullptr;
  }

  /// Nothing to hand over: a window shows its own frames, and an offscreen
  /// one is read back with Renderer::requestCapture.
  void *retainPresented(int) override { return nullptr; }

  /// ORBIS_DUMP_FRAME has no file to write here; a host that wants the
  /// picture asks for a capture instead.
  void writeFrame(int) override {}

 private:
  void *_window = nullptr;
  filament::SwapChain *_chain = nullptr;
};

}  // namespace

OrbisSurface *OrbisCreateHeadlessSurface() {
  return new SharedChainSurface(nullptr);
}

OrbisSurface *OrbisCreateWindowSurface(void *window) {
  return new SharedChainSurface(window);
}
