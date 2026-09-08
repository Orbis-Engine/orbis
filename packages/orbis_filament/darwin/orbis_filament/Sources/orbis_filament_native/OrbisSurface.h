#pragma once

// Not in include/. That directory is this target's *public* headers, and the
// Swift plugin imports the module they form — which Swift builds as C, not
// C++, so a public header cannot reach <cstdint> or name a C++ class. The
// existing renderer header says as much and stays free of C++ for the same
// reason. This one is C++ throughout and is nobody's business but the
// renderer's, so it lives beside it instead.

#include <cstdint>

namespace filament {
class Engine;
class SwapChain;
}  // namespace filament

/// Where the renderer presents its frames.
///
/// This is the platform seam, and it is deliberately the whole of it. Of the
/// renderer's four and a half thousand lines, almost none are about a
/// particular operating system — Filament abstracts the graphics backend, so
/// the scene, the materials, the lights and the passes are the same code
/// everywhere. What is not the same is how a finished frame is handed to
/// whoever composites it: an IOSurface-backed CVPixelBuffer that Flutter's
/// texture registry adopts on Apple platforms, an ANativeWindow from a
/// SurfaceProducer on Android, a shared texture on Windows.
///
/// So that question lives here, behind four calls, and the renderer asks them
/// without knowing which platform answered. Everything the renderer does with
/// a frame after that is portable.
///
/// Deliberately free of platform types in its own signature: a buffer leaves
/// through `retainPresented` as an opaque pointer, because the only thing that
/// needs to know what it really is is the host that asked for it.
class OrbisSurface {
 public:
  virtual ~OrbisSurface() = default;

  /// Creates `count` buffers of this size and a swap chain onto each, writing
  /// the chains into `chains`. False if any could not be made.
  ///
  /// More than one, because rendering and sampling are not on the same thread:
  /// the frame being drawn into is not the frame being shown, and handing out
  /// the one being drawn into would tear.
  virtual bool allocate(filament::Engine* engine, uint32_t width,
                        uint32_t height, filament::SwapChain** chains,
                        int count) = 0;

  /// Destroys the chains and the buffers behind them. Safe to call twice.
  virtual void release(filament::Engine* engine, filament::SwapChain** chains,
                       int count) = 0;

  /// The buffer at `index`, with a reference the caller then owns, or null.
  ///
  /// Opaque here and concrete at the call site: on Apple this is a retained
  /// CVPixelBufferRef and the plugin casts it back. A renderer that knew that
  /// would be a renderer that only worked there.
  virtual void* retainPresented(int index) = 0;

  /// Writes the buffer at `index` somewhere a developer can look at it, and
  /// says where. Diagnostics, for ORBIS_DUMP_FRAME.
  ///
  /// Here rather than in the renderer because both halves are platform work:
  /// reading the pixels back, and choosing a path a sandboxed application is
  /// allowed to write to.
  virtual void writeFrame(int index) = 0;
};

/// The implementation for whichever platform this was built for.
OrbisSurface* OrbisCreateSurface();
