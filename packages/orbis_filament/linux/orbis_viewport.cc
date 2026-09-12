#include "orbis_viewport.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace {

// ---- The texture Flutter samples ---------------------------------------
//
// An FlPixelBufferTexture subclass whose pixels are whichever frame the
// viewport last published. It holds the viewport as a bare pointer and the
// viewport outlives it by construction: the viewport unregisters and drops
// this in its own destructor, before anything else of it is torn down.

G_DECLARE_FINAL_TYPE(OrbisFrameTexture,
                     orbis_frame_texture,
                     ORBIS,
                     FRAME_TEXTURE,
                     FlPixelBufferTexture)

struct _OrbisFrameTexture {
  FlPixelBufferTexture parent_instance;
  orbis_linux::Viewport* viewport;
};

G_DEFINE_TYPE(OrbisFrameTexture,
              orbis_frame_texture,
              fl_pixel_buffer_texture_get_type())

// Flutter's render thread, not the main one. Everything it touches is
// behind the viewport's own lock.
static gboolean orbis_frame_texture_copy_pixels(FlPixelBufferTexture* texture,
                                                const uint8_t** buffer,
                                                uint32_t* width,
                                                uint32_t* height,
                                                GError** error) {
  auto* self = ORBIS_FRAME_TEXTURE(texture);
  if (self->viewport == nullptr ||
      !self->viewport->CopyPixels(buffer, width, height)) {
    // No frame has been read back yet. An error rather than a blank buffer,
    // because Flutter simply skips the texture this tick and tries again,
    // which is what should happen for the frame or two before the first
    // capture arrives.
    g_set_error(error, g_quark_from_static_string("orbis-filament"), 0,
                "no frame yet");
    return FALSE;
  }
  return TRUE;
}

static void orbis_frame_texture_class_init(OrbisFrameTextureClass* klass) {
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels =
      orbis_frame_texture_copy_pixels;
}

static void orbis_frame_texture_init(OrbisFrameTexture* self) {}

// ---- A PNG, written without a library ----------------------------------
//
// The same stored-block deflate native/headless/orbis_headless.c writes, in
// C++ and against a vector: a PNG needs no compressor if every block is
// stored and the two checksums are right, so this is sixty lines rather than
// a dependency on zlib or on Filament's image library. Deliberately a second
// copy rather than a shared one -- the other lives inside a standalone C
// program in a different build, and hoisting it would mean a new public
// header and a new translation unit in every platform's build to save sixty
// lines that will never change.

void Put32(uint8_t* to, uint32_t value) {
  to[0] = uint8_t(value >> 24);
  to[1] = uint8_t(value >> 16);
  to[2] = uint8_t(value >> 8);
  to[3] = uint8_t(value);
}

uint32_t Crc32(const uint8_t* bytes, size_t length, uint32_t crc) {
  static uint32_t table[256];
  static bool made = false;
  if (!made) {
    for (uint32_t n = 0; n < 256; n++) {
      uint32_t c = n;
      for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
      table[n] = c;
    }
    made = true;
  }
  crc ^= 0xFFFFFFFFu;
  for (size_t i = 0; i < length; i++) {
    crc = table[(crc ^ bytes[i]) & 0xFF] ^ (crc >> 8);
  }
  return crc ^ 0xFFFFFFFFu;
}

bool WriteChunk(std::FILE* file, const char* type, const uint8_t* data,
                size_t length) {
  uint8_t head[8];
  Put32(head, uint32_t(length));
  std::memcpy(head + 4, type, 4);
  uint32_t crc = Crc32(head + 4, 4, 0);
  crc = Crc32(data, length, crc);
  uint8_t tail[4];
  Put32(tail, crc);
  return std::fwrite(head, 1, 8, file) == 8 &&
         (length == 0 || std::fwrite(data, 1, length, file) == length) &&
         std::fwrite(tail, 1, 4, file) == 4;
}

bool WritePng(const char* path, const uint8_t* rgba, uint32_t width,
              uint32_t height) {
  const size_t row = size_t(width) * 4 + 1;
  const size_t raw = row * height;
  std::vector<uint8_t> zlib;
  zlib.reserve(raw + raw / 65535 * 5 + 16);
  zlib.push_back(0x78);
  zlib.push_back(0x01);

  uint32_t a = 1;
  uint32_t b = 0;
  size_t done = 0;
  while (done < raw) {
    const size_t take = raw - done < 65535 ? raw - done : 65535;
    zlib.push_back(done + take == raw ? 1 : 0);
    zlib.push_back(uint8_t(take & 0xFF));
    zlib.push_back(uint8_t(take >> 8));
    zlib.push_back(uint8_t(~take & 0xFF));
    zlib.push_back(uint8_t((~take >> 8) & 0xFF));
    for (size_t i = 0; i < take; i++) {
      const size_t offset = done + i;
      const size_t column = offset % row;
      // A filter byte of nought in front of every row, then the row itself.
      const uint8_t byte =
          column == 0 ? 0 : rgba[(offset / row) * width * 4 + column - 1];
      zlib.push_back(byte);
      a = (a + byte) % 65521;
      b = (b + a) % 65521;
    }
    done += take;
  }
  uint8_t adler[4];
  Put32(adler, (b << 16) | a);
  zlib.insert(zlib.end(), adler, adler + 4);

  uint8_t header[13];
  Put32(header, width);
  Put32(header + 4, height);
  header[8] = 8;  // bits per channel
  header[9] = 6;  // RGBA
  header[10] = header[11] = header[12] = 0;

  std::FILE* file = std::fopen(path, "wb");
  if (file == nullptr) return false;
  static const uint8_t signature[8] = {137, 'P', 'N', 'G', 13, 10, 26, 10};
  bool ok = std::fwrite(signature, 1, 8, file) == 8 &&
            WriteChunk(file, "IHDR", header, sizeof header) &&
            WriteChunk(file, "IDAT", zlib.data(), zlib.size()) &&
            WriteChunk(file, "IEND", nullptr, 0);
  ok = std::fclose(file) == 0 && ok;
  return ok;
}

}  // namespace

namespace orbis_linux {

std::unique_ptr<Viewport> Viewport::Start(FlTextureRegistrar* registrar,
                                          uint32_t width, uint32_t height) {
  std::unique_ptr<Viewport> viewport(new Viewport());
  viewport->registrar_ = registrar;

  // Offscreen and readable. ORBIS_BACKEND_DEFAULT is the platform's own
  // choice -- orbis::backendCandidates asks for Vulkan and falls back to
  // OpenGL off Apple -- or whatever ORBIS_BACKEND names.
  orbis_surface_desc surface{};
  surface.kind = ORBIS_SURFACE_HEADLESS;
  surface.window = nullptr;
  viewport->renderer_ = orbis_renderer_create(ORBIS_BACKEND_DEFAULT, &surface,
                                              width, height);
  if (viewport->renderer_ == nullptr) return nullptr;

  auto* texture = ORBIS_FRAME_TEXTURE(
      g_object_new(orbis_frame_texture_get_type(), nullptr));
  texture->viewport = viewport.get();
  viewport->texture_ = FL_TEXTURE(texture);
  if (!fl_texture_registrar_register_texture(registrar, viewport->texture_)) {
    return nullptr;
  }
  viewport->texture_id_ = fl_texture_get_id(viewport->texture_);

  viewport->started_micros_ = g_get_monotonic_time();
  // Roughly sixty a second. Flutter's own frame clock is not offered to a
  // plugin on this embedder, and a timer is what the renderer's draw loop
  // needs -- it paces itself against the camera's timestamps rather than
  // against when it is called.
  viewport->frame_source_ =
      g_timeout_add(16, Viewport::OnFrameThunk, viewport.get());
  return viewport;
}

Viewport::~Viewport() {
  if (frame_source_ != 0) {
    g_source_remove(frame_source_);
    frame_source_ = 0;
  }
  // Unregistered and let go before the renderer, so nothing can be sampling
  // the pixels while they are being freed. The texture's back-pointer is
  // cleared first for the same reason: a copy_pixels already in flight on
  // the render thread finds a viewport it must not touch.
  if (texture_ != nullptr) {
    ORBIS_FRAME_TEXTURE(texture_)->viewport = nullptr;
    fl_texture_registrar_unregister_texture(registrar_, texture_);
    g_object_unref(texture_);
    texture_ = nullptr;
  }
  if (renderer_ != nullptr) {
    orbis_renderer_destroy(renderer_);
    renderer_ = nullptr;
  }
}

gboolean Viewport::OnFrameThunk(gpointer self) {
  return static_cast<Viewport*>(self)->OnFrame() ? G_SOURCE_CONTINUE
                                                 : G_SOURCE_REMOVE;
}

bool Viewport::OnFrame() {
  if (renderer_ == nullptr) return false;

  const double seconds =
      double(g_get_monotonic_time() - started_micros_) / 1e6;

  // Asked for before the draw, because the draw is what performs the
  // readback: the renderer only reads pixels back inside a frame, and a
  // request made after one waits for the next. Requesting every frame is
  // free when one is already in flight -- the core ignores it.
  orbis_renderer_request_capture(renderer_);
  orbis_renderer_draw(renderer_, seconds);
  frame_count_++;

  uint32_t width = 0;
  uint32_t height = 0;
  const size_t bytes =
      orbis_renderer_read_capture(renderer_, nullptr, 0, &width, &height);
  if (bytes == 0 || width == 0 || height == 0) return true;

  // Into the slot Flutter is least likely to still be reading. Three slots
  // rotating, so the one handed out last time survives at least until the
  // embedder's next tick -- see this class's header comment.
  std::vector<uint8_t>& slot = slots_[next_slot_];
  slot.resize(bytes);
  orbis_renderer_read_capture(renderer_, slot.data(), slot.size(), &width,
                              &height);
  {
    std::lock_guard<std::mutex> lock(pixels_lock_);
    front_slot_ = next_slot_;
    front_width_ = width;
    front_height_ = height;
  }
  next_slot_ = (next_slot_ + 1) % 3;

  WriteFrameIfAsked(slot.data(), width, height);
  fl_texture_registrar_mark_texture_frame_available(registrar_, texture_);
  return true;
}

bool Viewport::CopyPixels(const uint8_t** buffer, uint32_t* width,
                          uint32_t* height) {
  std::lock_guard<std::mutex> lock(pixels_lock_);
  if (front_slot_ < 0) return false;
  *buffer = slots_[front_slot_].data();
  *width = front_width_;
  *height = front_height_;
  return true;
}

void Viewport::WriteFrameIfAsked(const uint8_t* rgba, uint32_t width,
                                 uint32_t height) {
  const char* wanted = std::getenv("ORBIS_DUMP_FRAME");
  if (wanted == nullptr || dumped_) return;
  // The same rule the renderer's own dump uses: a number names the frame,
  // and anything unparseable means the sixtieth. `flash` is the renderer's
  // own business and is left to it.
  const int at = std::atoi(wanted) > 1 ? std::atoi(wanted) : 60;
  // Counted in frames that actually came back rather than frames drawn: the
  // readback runs a frame or two behind, so the two counts differ by that
  // much and it is the picture that is being asked for.
  if (frame_count_ < at) return;
  dumped_ = true;

  const std::string path =
      std::string(g_get_tmp_dir()) + "/orbis_frame.png";
  const bool wrote = WritePng(path.c_str(), rgba, width, height);
  // The line tool/ci_draw_frame.sh waits for, in the shape
  // OrbisSurfaceApple.mm prints it -- printed after the readback, so it is
  // evidence that a frame exists and not merely that one was asked for.
  std::fprintf(stderr, "[orbis] frame (%ux%u) -> %s : %s\n", width, height,
               path.c_str(), wrote ? "written" : "REFUSED");
  std::fflush(stderr);
}

void Viewport::Resize(uint32_t width, uint32_t height) {
  if (renderer_ == nullptr || width == 0 || height == 0) return;
  orbis_renderer_resize(renderer_, width, height);
}

void Viewport::ApplyScene(const Scene& scene) {
  if (renderer_ == nullptr) return;
  scene.ApplyTo(renderer_);
}

std::vector<std::pair<std::string, std::string>> Viewport::Notes() const {
  std::vector<std::pair<std::string, std::string>> out;
  if (renderer_ == nullptr) return out;
  const uint32_t count = orbis_renderer_notes(renderer_);
  out.reserve(count);
  for (uint32_t i = 0; i < count; i++) {
    const char* about = nullptr;
    const char* saying = nullptr;
    if (orbis_renderer_note(renderer_, i, &about, &saying) != ORBIS_OK) {
      continue;
    }
    out.emplace_back(about != nullptr ? about : "",
                     saying != nullptr ? saying : "");
  }
  return out;
}

double Viewport::GpuMilliseconds() const {
  if (renderer_ == nullptr) return 0;
  orbis_stats stats{};
  if (orbis_renderer_stats(renderer_, &stats) != ORBIS_OK) return 0;
  return stats.gpu_milliseconds;
}

std::vector<double> Viewport::PassTimings() const {
  if (renderer_ == nullptr) return {};
  const uint32_t count =
      orbis_renderer_pass_timings(renderer_, nullptr, nullptr, 0);
  std::vector<double> milliseconds(count);
  std::vector<int32_t> drawn(count);
  orbis_renderer_pass_timings(renderer_, milliseconds.data(), drawn.data(),
                              count);
  std::vector<double> interleaved;
  interleaved.reserve(size_t(count) * 2);
  for (uint32_t i = 0; i < count; i++) {
    interleaved.push_back(milliseconds[i]);
    interleaved.push_back(double(drawn[i]));
  }
  return interleaved;
}

std::vector<int32_t> Viewport::Batching() const {
  if (renderer_ == nullptr) return {0, 0};
  orbis_stats stats{};
  if (orbis_renderer_stats(renderer_, &stats) != ORBIS_OK) return {0, 0};
  return {int32_t(stats.batched_objects), int32_t(stats.batch_groups)};
}

}  // namespace orbis_linux
