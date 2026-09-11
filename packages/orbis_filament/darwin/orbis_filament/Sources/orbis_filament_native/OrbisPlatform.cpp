#include "OrbisPlatform.h"

// The half of the platform layer every build takes — strings, files, paths —
// and, under `#if !ORBIS_PLATFORM_APPLE`, the portable answers to the rest.
// OrbisPlatformApple.mm answers those on Apple platforms.

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>

#if !defined(_WIN32)
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

#if !ORBIS_PLATFORM_APPLE
#include <image/ImageSampler.h>
#include <image/LinearImage.h>
#if defined(__ANDROID__)
#include <android/log.h>
#endif

// stb_image's own declarations for the two functions used here.
//
// Filament's release links stb_image into libstb.a on every platform it
// ships — gltfio's texture provider decodes PNG and JPEG with it — but ships
// no header for it. These are stb_image.h's public signatures, unchanged in a
// decade, so declaring them is linking against what is already in the build
// rather than vendoring a second copy of eight thousand lines.
extern "C" {
unsigned char *stbi_load_from_memory(const unsigned char *buffer, int length,
                                     int *width, int *height, int *channels,
                                     int desiredChannels);
void stbi_image_free(void *pixels);
}
#endif

namespace orbis {

namespace {

bool isSeparator(char c) {
#if defined(_WIN32)
  return c == '/' || c == '\\';
#else
  return c == '/';
#endif
}

/// The path without any separators at its end, except a root on its own.
std::string trimmedOfSeparators(const std::string &path) {
  std::string trimmed = path;
  while (trimmed.size() > 1 && isSeparator(trimmed.back())) trimmed.pop_back();
  return trimmed;
}

size_t lastSeparator(const std::string &path) {
  for (size_t i = path.size(); i > 0; i--) {
    if (isSeparator(path[i - 1])) return i - 1;
  }
  return std::string::npos;
}

int hexValue(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

}  // namespace

std::string vformat(const char *format, va_list arguments) {
  va_list measuring;
  va_copy(measuring, arguments);
  const int needed = std::vsnprintf(nullptr, 0, format, measuring);
  va_end(measuring);
  if (needed <= 0) return std::string();
  std::string out(size_t(needed) + 1, '\0');
  std::vsnprintf(&out[0], out.size(), format, arguments);
  out.resize(size_t(needed));
  return out;
}

std::string format(const char *format, ...) {
  va_list arguments;
  va_start(arguments, format);
  std::string out = vformat(format, arguments);
  va_end(arguments);
  return out;
}

bool readFile(const std::string &path, std::vector<uint8_t> &out) {
  out.clear();
  std::FILE *file = std::fopen(path.c_str(), "rb");
  if (file == nullptr) return false;
  // Sized first where the file says how big it is, so a large model is one
  // allocation rather than a vector doubling its way up to it.
  if (std::fseek(file, 0, SEEK_END) == 0) {
    const long size = std::ftell(file);
    if (size > 0) out.reserve(size_t(size));
    std::fseek(file, 0, SEEK_SET);
  }
  uint8_t chunk[1 << 16];
  bool whole = true;
  for (;;) {
    const size_t got = std::fread(chunk, 1, sizeof(chunk), file);
    out.insert(out.end(), chunk, chunk + got);
    if (got < sizeof(chunk)) {
      // A directory opens and then refuses to be read. That is a failure,
      // not an empty file.
      whole = std::ferror(file) == 0;
      break;
    }
  }
  std::fclose(file);
  if (!whole) out.clear();
  return whole;
}

bool readWholeFile(const std::string &path, void **bytes, size_t *size) {
  *bytes = nullptr;
  *size = 0;
#if !defined(_WIN32)
  // Read, not mapped. Mapping looks like the frugal choice — the pages are
  // backed by the file and the system can evict them — but every page then
  // arrives as a fault when the decoder touches it, and paging four hundred
  // files in sixteen kilobytes at a time measured 2226 ms against 542 ms for
  // reading them. This data is read once, immediately, in full: the access
  // pattern a plain read is for.
  const int file = open(path.c_str(), O_RDONLY);
  if (file < 0) return false;

  struct stat facts;
  if (fstat(file, &facts) != 0 || facts.st_size <= 0) {
    close(file);
    return false;
  }

  const size_t total = size_t(facts.st_size);
  void *memory = std::malloc(total);
  if (memory == nullptr) {
    close(file);
    return false;
  }

  // In a loop, because a read is allowed to return early and a texture that
  // is nine tenths of itself decodes into something worse than a missing one.
  size_t got = 0;
  while (got < total) {
    const ssize_t some = read(file, static_cast<char *>(memory) + got, total - got);
    if (some <= 0) break;
    got += size_t(some);
  }
  close(file);

  if (got != total) {
    std::free(memory);
    return false;
  }
  *bytes = memory;
  *size = total;
  return true;
#else
  // No POSIX read under MSVC. Standard IO reads the same bytes.
  std::vector<uint8_t> all;
  if (!readFile(path, all) || all.empty()) return false;
  void *memory = std::malloc(all.size());
  if (memory == nullptr) return false;
  std::memcpy(memory, all.data(), all.size());
  *bytes = memory;
  *size = all.size();
  return true;
#endif
}

std::string deletingLastPathComponent(const std::string &path) {
  const std::string trimmed = trimmedOfSeparators(path);
  const size_t slash = lastSeparator(trimmed);
  if (slash == std::string::npos) return std::string();
  if (slash == 0) return trimmed.substr(0, 1);
  return trimmed.substr(0, slash);
}

std::string appendingPathComponent(const std::string &directory,
                                   const std::string &name) {
  size_t from = 0;
  while (from < name.size() && isSeparator(name[from])) from++;
  const std::string rest = name.substr(from);
  if (directory.empty()) return rest;
  if (isSeparator(directory.back())) return directory + rest;
  return directory + "/" + rest;
}

std::string lastPathComponent(const std::string &path) {
  const std::string trimmed = trimmedOfSeparators(path);
  if (trimmed.size() == 1 && isSeparator(trimmed[0])) return trimmed;
  const size_t slash = lastSeparator(trimmed);
  return slash == std::string::npos ? trimmed : trimmed.substr(slash + 1);
}

std::string lowercasePathExtension(const std::string &path) {
  const std::string name = lastPathComponent(path);
  const size_t dot = name.rfind('.');
  if (dot == std::string::npos || dot == 0 || dot + 1 >= name.size()) {
    return std::string();
  }
  std::string extension = name.substr(dot + 1);
  for (char &c : extension) {
    c = char(std::tolower(static_cast<unsigned char>(c)));
  }
  return extension;
}

std::string removingPercentEncoding(const std::string &uri) {
  std::string out;
  out.reserve(uri.size());
  for (size_t i = 0; i < uri.size(); i++) {
    if (uri[i] != '%') {
      out += uri[i];
      continue;
    }
    const int high = i + 2 < uri.size() ? hexValue(uri[i + 1]) : -1;
    const int low = i + 2 < uri.size() ? hexValue(uri[i + 2]) : -1;
    if (high < 0 || low < 0) return uri;
    out += char(high * 16 + low);
    i += 2;
  }
  return out;
}

bool hasPrefix(const std::string &text, const char *prefix) {
  return text.rfind(prefix, 0) == 0;
}

#if !ORBIS_PLATFORM_APPLE

void log(const char *format, ...) {
  va_list arguments;
  va_start(arguments, format);
#if defined(__ANDROID__)
  __android_log_vprint(ANDROID_LOG_INFO, "orbis", format, arguments);
#else
  const std::string line = vformat(format, arguments);
  std::fprintf(stderr, "%s\n", line.c_str());
  std::fflush(stderr);
#endif
  va_end(arguments);
}

double now() {
  using namespace std::chrono;
  return duration<double>(steady_clock::now().time_since_epoch()).count();
}

void parallelFor(size_t count, const std::function<void(size_t)> &body) {
  if (count == 0) return;
  const size_t cores = std::max(1u, std::thread::hardware_concurrency());
  const size_t workers = std::min(count, cores);
  if (workers <= 1) {
    for (size_t i = 0; i < count; i++) body(i);
    return;
  }
  // Indices handed out one at a time from a shared counter rather than split
  // into equal blocks: the work here is reading files, and one large texture
  // in a block would leave every other thread idle while it finished.
  std::atomic<size_t> next{0};
  const auto work = [&]() {
    for (size_t i = next.fetch_add(1); i < count; i = next.fetch_add(1)) {
      body(i);
    }
  };
  std::vector<std::thread> threads;
  threads.reserve(workers - 1);
  for (size_t t = 1; t < workers; t++) threads.emplace_back(work);
  work();
  for (std::thread &thread : threads) thread.join();
}

std::vector<uint8_t> readPicture(const std::string &path, uint32_t side) {
  std::vector<uint8_t> pixels;
  std::vector<uint8_t> file;
  if (side == 0 || !readFile(path, file) || file.empty()) return pixels;

  int wide = 0;
  int tall = 0;
  int channels = 0;
  unsigned char *decoded = stbi_load_from_memory(
      file.data(), int(file.size()), &wide, &tall, &channels, 4);
  if (decoded == nullptr) return pixels;
  if (wide <= 0 || tall <= 0) {
    stbi_image_free(decoded);
    return pixels;
  }

  // Premultiplied before it is resampled, as Core Graphics does it: filtering
  // straight alpha drags the colour of the transparent texels into the edge
  // of what is opaque, which is a dark fringe round every cut-out.
  image::LinearImage source(uint32_t(wide), uint32_t(tall), 4);
  float *into = source.getPixelRef();
  const size_t texels = size_t(wide) * size_t(tall);
  for (size_t i = 0; i < texels; i++) {
    const float alpha = decoded[i * 4 + 3] / 255.0f;
    into[i * 4 + 0] = decoded[i * 4 + 0] / 255.0f * alpha;
    into[i * 4 + 1] = decoded[i * 4 + 1] / 255.0f * alpha;
    into[i * 4 + 2] = decoded[i * 4 + 2] / 255.0f * alpha;
    into[i * 4 + 3] = alpha;
  }
  stbi_image_free(decoded);

  // Filament's own resampler, which picks Mitchell or Lanczos by whether the
  // picture is growing or shrinking — the same judgement kCGInterpolationHigh
  // makes. Row nought of what stb decodes is the top of the picture, which is
  // what the renderer wants, so there is no flip.
  const image::LinearImage square =
      image::resampleImage(source, side, side, image::Filter::DEFAULT);
  const float *from = square.getPixelRef();
  pixels.resize(size_t(side) * side * 4);
  for (size_t i = 0; i < pixels.size(); i++) {
    // Clamped, because both filters ring: a sharp edge overshoots a little
    // either side of itself, past nought and past one.
    pixels[i] = uint8_t(std::clamp(from[i], 0.0f, 1.0f) * 255.0f + 0.5f);
  }
  return pixels;
}

std::unique_ptr<VideoDecoder> createVideoDecoder() {
  // Nothing yet. Each platform has its own decoder — MediaCodec on Android,
  // GStreamer or FFmpeg on Linux, Media Foundation on Windows — and each is
  // its own piece of work. Until one exists the renderer says so in its notes
  // and draws the screen blank, rather than failing the scene it is on.
  return nullptr;
}

#endif  // !ORBIS_PLATFORM_APPLE

}  // namespace orbis
