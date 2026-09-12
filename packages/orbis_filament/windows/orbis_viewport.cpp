#include "orbis_viewport.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace {

// The window class the frame timer's message-only window belongs to.
// Registered once for the process; unregistering it is not worth the
// bookkeeping, since the class costs nothing and the plugin lives as long as
// the engine does.
constexpr const wchar_t kTimerWindowClass[] = L"OrbisFilamentFrameTimer";

// ---- A PNG, written without a library ----------------------------------
//
// The same stored-block deflate native/headless/orbis_headless.c writes, and
// that ../linux/orbis_viewport.cc carries: a PNG needs no compressor if every
// block is stored and the two checksums are right, so this is sixty lines
// rather than a dependency on zlib or on Filament's image library.
// Deliberately a third copy rather than a shared one, for the reason the
// Linux one gives: hoisting it would mean a new public header and a new
// translation unit in every platform's build to save sixty lines that will
// never change.

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

  std::FILE* file = nullptr;
  // fopen_s rather than fopen: MSVC treats the latter as deprecated and the
  // plugin is compiled without the suppressing define.
  if (fopen_s(&file, path, "wb") != 0 || file == nullptr) return false;
  static const uint8_t signature[8] = {137, 'P', 'N', 'G', 13, 10, 26, 10};
  bool ok = std::fwrite(signature, 1, 8, file) == 8 &&
            WriteChunk(file, "IHDR", header, sizeof header) &&
            WriteChunk(file, "IDAT", zlib.data(), zlib.size()) &&
            WriteChunk(file, "IEND", nullptr, 0);
  ok = std::fclose(file) == 0 && ok;
  return ok;
}

}  // namespace

namespace orbis_windows {

std::unique_ptr<Viewport> Viewport::Start(flutter::TextureRegistrar* registrar,
                                          uint32_t width, uint32_t height) {
  std::unique_ptr<Viewport> viewport(new Viewport());
  viewport->registrar_ = registrar;

  // Offscreen and readable. ORBIS_BACKEND_DEFAULT is the platform's own
  // choice -- orbis::backendCandidates asks for Vulkan and falls back to
  // OpenGL off Apple, which is what Windows wants -- or whatever
  // ORBIS_BACKEND names.
  orbis_surface_desc surface{};
  surface.kind = ORBIS_SURFACE_HEADLESS;
  surface.window = nullptr;
  viewport->renderer_ = orbis_renderer_create(ORBIS_BACKEND_DEFAULT, &surface,
                                              width, height);
  if (viewport->renderer_ == nullptr) return nullptr;

  // The texture Flutter samples. The callback captures the shared pixel block
  // by value rather than `this`, so it stays safe if it lands after the
  // viewport has been torn down -- see the header.
  std::shared_ptr<Shared> shared = viewport->shared_;
  viewport->texture_ =
      std::make_unique<flutter::TextureVariant>(flutter::PixelBufferTexture(
          [shared](size_t, size_t) -> const FlutterDesktopPixelBuffer* {
            std::lock_guard<std::mutex> guard(shared->lock);
            if (!shared->alive || shared->front < 0) {
              // No frame has been read back yet. Null rather than a blank
              // buffer, because Flutter simply skips the texture this tick
              // and tries again, which is what should happen for the frame
              // or two before the first capture arrives.
              return nullptr;
            }
            return &shared->buffers[shared->front];
          }));

  viewport->texture_id_ = registrar->RegisterTexture(viewport->texture_.get());
  if (viewport->texture_id_ < 0) return nullptr;

  // A message-only window to hang the frame timer on. HWND_MESSAGE means it
  // is never shown, never sized and never composited; it exists only so the
  // platform thread's message loop has somewhere to deliver WM_TIMER.
  WNDCLASSW window_class{};
  window_class.lpfnWndProc = Viewport::WindowProc;
  window_class.hInstance = GetModuleHandle(nullptr);
  window_class.lpszClassName = kTimerWindowClass;
  // Harmless if another viewport already registered it; the only failure
  // that matters is CreateWindowExW's below.
  RegisterClassW(&window_class);

  viewport->timer_window_ =
      CreateWindowExW(0, kTimerWindowClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE,
                      nullptr, GetModuleHandle(nullptr), viewport.get());
  if (viewport->timer_window_ == nullptr) return nullptr;

  QueryPerformanceFrequency(&viewport->frequency_);
  QueryPerformanceCounter(&viewport->started_);

  // Roughly sixty a second. Flutter's own frame clock is not offered to a
  // plugin on this embedder, and a timer is what the renderer's draw loop
  // needs -- it paces itself against the camera's timestamps rather than
  // against when it is called.
  viewport->timer_ = SetTimer(viewport->timer_window_, 1, 16, nullptr);
  return viewport;
}

Viewport::~Viewport() {
  // The timer and its window first, so no further frame can start.
  if (timer_ != 0 && timer_window_ != nullptr) {
    KillTimer(timer_window_, timer_);
    timer_ = 0;
  }
  if (timer_window_ != nullptr) {
    DestroyWindow(timer_window_);
    timer_window_ = nullptr;
  }

  // Then the pixels are declared gone, before anything is freed. A copy
  // callback already in flight on the render thread takes the lock, sees
  // this, and reports that there is no frame.
  {
    std::lock_guard<std::mutex> guard(shared_->lock);
    shared_->alive = false;
    shared_->front = -1;
  }

  // Unregistering is asynchronous here, which is exactly why the block above
  // is shared rather than owned: this returns before Flutter has necessarily
  // finished with the texture, and that is safe.
  if (texture_id_ >= 0 && registrar_ != nullptr) {
    registrar_->UnregisterTexture(texture_id_, nullptr);
    texture_id_ = -1;
  }

  if (renderer_ != nullptr) {
    orbis_renderer_destroy(renderer_);
    renderer_ = nullptr;
  }
}

LRESULT CALLBACK Viewport::WindowProc(HWND window, UINT message, WPARAM wparam,
                                      LPARAM lparam) {
  if (message == WM_CREATE) {
    // The viewport is handed over as the creation parameter and kept on the
    // window, which is how WM_TIMER finds its way back to an instance.
    auto* created = reinterpret_cast<CREATESTRUCTW*>(lparam);
    SetWindowLongPtrW(window, GWLP_USERDATA,
                      reinterpret_cast<LONG_PTR>(created->lpCreateParams));
    return 0;
  }
  if (message == WM_TIMER) {
    auto* viewport = reinterpret_cast<Viewport*>(
        GetWindowLongPtrW(window, GWLP_USERDATA));
    if (viewport != nullptr) viewport->OnFrame();
    return 0;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

void Viewport::OnFrame() {
  if (renderer_ == nullptr) return;

  LARGE_INTEGER now;
  QueryPerformanceCounter(&now);
  const double seconds =
      frequency_.QuadPart == 0
          ? 0.0
          : double(now.QuadPart - started_.QuadPart) /
                double(frequency_.QuadPart);

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
  if (bytes == 0 || width == 0 || height == 0) return;

  // Into the slot Flutter is least likely to still be reading. Three slots
  // rotating, so the one handed out last time survives at least until the
  // embedder's next tick -- see this class's header comment.
  const int slot = next_slot_;
  std::vector<uint8_t>& pixels = shared_->pixels[slot];
  pixels.resize(bytes);
  orbis_renderer_read_capture(renderer_, pixels.data(), pixels.size(), &width,
                              &height);
  {
    std::lock_guard<std::mutex> guard(shared_->lock);
    FlutterDesktopPixelBuffer& buffer = shared_->buffers[slot];
    buffer.buffer = pixels.data();
    buffer.width = width;
    buffer.height = height;
    // Nothing to release: the bytes belong to this viewport and are kept
    // alive by the rotation, not by the embedder telling us it has finished.
    buffer.release_callback = nullptr;
    buffer.release_context = nullptr;
    shared_->front = slot;
  }
  next_slot_ = (next_slot_ + 1) % 3;

  WriteFrameIfAsked(pixels.data(), width, height);
  if (registrar_ != nullptr && texture_id_ >= 0) {
    registrar_->MarkTextureFrameAvailable(texture_id_);
  }
}

void Viewport::WriteFrameIfAsked(const uint8_t* rgba, uint32_t width,
                                 uint32_t height) {
  if (dumped_) return;
  // _dupenv_s rather than getenv: MSVC deprecates the latter, and this is
  // the one place the plugin reads the environment.
  char* wanted = nullptr;
  size_t wanted_length = 0;
  if (_dupenv_s(&wanted, &wanted_length, "ORBIS_DUMP_FRAME") != 0 ||
      wanted == nullptr) {
    return;
  }
  // The same rule the renderer's own dump uses: a number names the frame,
  // and anything unparseable means the sixtieth. `flash` is the renderer's
  // own business and is left to it.
  const int asked = std::atoi(wanted);
  free(wanted);
  const int at = asked > 1 ? asked : 60;
  // Counted in frames that actually came back rather than frames drawn: the
  // readback runs a frame or two behind, so the two counts differ by that
  // much and it is the picture that is being asked for.
  if (frame_count_ < at) return;
  dumped_ = true;

  char directory[MAX_PATH] = {};
  const DWORD length = GetTempPathA(MAX_PATH, directory);
  const std::string path =
      (length > 0 ? std::string(directory, length) : std::string(".\\")) +
      "orbis_frame.png";

  const bool wrote = WritePng(path.c_str(), rgba, width, height);
  // The line tool/ci_draw_frame_windows.sh waits for, in the shape
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

}  // namespace orbis_windows
