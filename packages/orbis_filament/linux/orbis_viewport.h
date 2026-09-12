#pragma once

// One Filament engine drawing into one Flutter texture -- the Linux
// counterpart to OrbisViewport.kt on Android and Viewport in
// OrbisFilamentPlugin.swift.
//
// ## How a frame reaches Flutter
//
// Through an FlPixelBufferTexture: the renderer draws into an offscreen,
// readable swap chain (ORBIS_SURFACE_HEADLESS), the frame is read back with
// the ABI's own capture calls, and Flutter copies those bytes into a texture
// of its own. That is a full copy of the frame every time, which the other
// three platforms all avoid -- Apple hands over an IOSurface, Android a
// SurfaceProducer's buffer -- so it is worth saying why it is the right
// answer here rather than a placeholder.
//
// Flutter's Linux embedder has two texture kinds. FlTextureGL hands Flutter
// the name of a GL texture, which is the copy-free route, but the texture
// has to live in Flutter's own GL context and the embedder offers no public
// way to get at it: the only moment that context is current on a thread you
// control is inside an FlTextureGL's own populate callback, so obtaining it
// means registering a throwaway texture purely to capture
// eglGetCurrentContext() and then building Filament's context shared with
// it. That works, and it is what a later change should do; it also depends
// on Filament choosing its OpenGL backend rather than Vulkan (Texture::
// import of a GL name is a GL-backend call and asserts on Vulkan, and
// Filament has no external-memory import outside Android), and on the
// driver honouring a shared context group. FlPixelBufferTexture depends on
// none of that, works on whichever backend actually started, and is what
// makes the gallery draw on Linux at all. The copy is the price.
//
// ## Threading
//
// The frame loop runs on the GLib main thread, where every method call also
// arrives, so the renderer is driven from one thread exactly as Android's
// is. `copy_pixels` is the exception: Flutter calls it on its own render
// thread. So the pixels are published under a lock into one of three slots
// and handed out by pointer -- three rather than two because the embedder
// takes the buffer's contents *after* copy_pixels returns and needs it
// intact until its next tick, so the slot Flutter last saw must not be the
// one the next frame is written into.

#include <flutter_linux/flutter_linux.h>

#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#include "orbis_renderer.h"
#include "orbis_scene.h"

namespace orbis_linux {

class Viewport {
 public:
  // Null if Filament would not start -- no backend (Vulkan, then OpenGL)
  // was available -- with the reason already logged by the renderer.
  static std::unique_ptr<Viewport> Start(FlTextureRegistrar* registrar,
                                         uint32_t width, uint32_t height);

  ~Viewport();

  Viewport(const Viewport&) = delete;
  Viewport& operator=(const Viewport&) = delete;

  int64_t texture_id() const { return texture_id_; }

  void Resize(uint32_t width, uint32_t height);
  void ApplyScene(const Scene& scene);

  // What the scene asked for that could not be given, as about/saying pairs.
  std::vector<std::pair<std::string, std::string>> Notes() const;

  double GpuMilliseconds() const;
  // Interleaved [ms0, drawn0, ms1, drawn1, ...], one pair per pass, in the
  // order they ran -- the shape OrbisView.capture() already reads.
  std::vector<double> PassTimings() const;
  // [batchedObjects, batchGroups].
  std::vector<int32_t> Batching() const;

  // Called on Flutter's render thread by the texture's copy_pixels.
  bool CopyPixels(const uint8_t** buffer, uint32_t* width, uint32_t* height);

 private:
  Viewport() = default;

  // One frame: draw, ask for it back, publish whatever has arrived. Returns
  // whether the loop should continue.
  bool OnFrame();
  static gboolean OnFrameThunk(gpointer self);

  // ORBIS_DUMP_FRAME's other half. The renderer prints the frame's cost and
  // then asks its surface to write the picture; a headless surface has no
  // file to write, and this is the only layer that holds the pixels, so the
  // picture is written here instead -- including the "-> path : written"
  // line tool/ci_draw_frame.sh waits for.
  void WriteFrameIfAsked(const uint8_t* rgba, uint32_t width, uint32_t height);

  orbis_renderer* renderer_ = nullptr;
  FlTextureRegistrar* registrar_ = nullptr;  // borrowed
  FlTexture* texture_ = nullptr;             // owned (one reference)
  int64_t texture_id_ = -1;
  guint frame_source_ = 0;
  int64_t started_micros_ = 0;
  int frame_count_ = 0;
  bool dumped_ = false;

  mutable std::mutex pixels_lock_;
  std::vector<uint8_t> slots_[3];
  int next_slot_ = 0;
  int front_slot_ = -1;
  uint32_t front_width_ = 0;
  uint32_t front_height_ = 0;
};

}  // namespace orbis_linux
