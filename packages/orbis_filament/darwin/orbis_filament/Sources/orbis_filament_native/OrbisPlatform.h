#pragma once

// The few things the renderer needs from the operating system, and nothing
// else.
//
// Everything the renderer does with Filament is the same code on every
// platform. What is not is a short list: how to say something to a developer,
// what time it is, how to read a file and a picture, how to run a loop on
// every core, and how to decode a video. Each is declared here in plain C++
// and answered twice — OrbisPlatformApple.mm with the frameworks the Apple
// build has always used, and OrbisPlatform.cpp with the standard library and
// what Filament's own release ships — so the renderer asks without knowing
// which platform answered.
//
// Not in include/, for the reason OrbisSurface.h is not: that directory is
// the Swift module's public headers, which Swift reads as C.

#include <cstdarg>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

// Which answers a build gets. Apple's on Apple platforms, unless
// ORBIS_PLATFORM_PORTABLE is defined — which is how the portable answers are
// compiled and run on a Mac, to prove they work somewhere they can be looked
// at before they are needed somewhere they cannot.
#if defined(__APPLE__) && !defined(ORBIS_PLATFORM_PORTABLE)
#define ORBIS_PLATFORM_APPLE 1
#else
#define ORBIS_PLATFORM_APPLE 0
#endif

#if defined(__GNUC__) || defined(__clang__)
#define ORBIS_PRINTF(which, first) \
  __attribute__((format(printf, which, first)))
#else
#define ORBIS_PRINTF(which, first)
#endif

namespace filament {
class Engine;
class Texture;
}  // namespace filament

namespace orbis {

// ---- Saying things ----

/// Writes one line for a developer to read, printf-style.
///
/// NSLog on Apple, so it lands where it always has — tool/ci_draw_frame.sh
/// reads the app's log for the "[orbis] frame" line and must keep finding it.
/// Standard error elsewhere, and logcat on Android, where standard error goes
/// nowhere anybody looks.
void log(const char *format, ...) ORBIS_PRINTF(1, 2);

/// printf into a string. What -[NSString stringWithFormat:] was for, which
/// is almost entirely the notes a scene gets back.
std::string format(const char *format, ...) ORBIS_PRINTF(1, 2);

/// The same, given the arguments as a va_list.
std::string vformat(const char *format, va_list arguments);

// ---- Time ----

/// Seconds, on a clock that only means anything relative to itself.
///
/// CoreFoundation's absolute time on Apple, because that is what the
/// renderer has always measured against: the camera lines the application's
/// clock up with this one by arithmetic on the two, and keeping the same
/// clock keeps that arithmetic exactly as it was. A steady clock elsewhere,
/// which is the better choice anyway — it never jumps when the wall clock is
/// corrected.
double now();

// ---- Files ----

/// Reads a file whole. False if it cannot be opened or read. An empty file
/// is an empty answer rather than a failure, which is what NSData said, and
/// what lets the caller report "not a glTF file" rather than "missing".
bool readFile(const std::string &path, std::vector<uint8_t> &out);

/// Reads a file whole into memory from malloc, for a Filament buffer
/// descriptor whose callback frees it. False, with nothing allocated, when
/// the file is missing, empty, or comes back short.
bool readWholeFile(const std::string &path, void **bytes, size_t *size);

/// The directory a path is in: "/a/b/c.gltf" is "/a/b", "c.gltf" is "", and
/// "/c.gltf" is "/". NSString's stringByDeletingLastPathComponent.
std::string deletingLastPathComponent(const std::string &path);

/// A name inside a directory: "/a/b" and "c.png" is "/a/b/c.png", and an
/// empty directory is the name alone. stringByAppendingPathComponent.
std::string appendingPathComponent(const std::string &directory,
                                   const std::string &name);

/// The last part of a path: "/a/b/c.gltf" is "c.gltf".
std::string lastPathComponent(const std::string &path);

/// The extension of the last part, lower-cased and without its dot: "C.JPG"
/// is "jpg", and a name with no dot has none.
std::string lowercasePathExtension(const std::string &path);

/// A URI with its %XX escapes decoded, or the URI as it came when an escape
/// is malformed — which is what `stringByRemovingPercentEncoding ?: uri` did.
std::string removingPercentEncoding(const std::string &uri);

/// Whether `text` starts with `prefix`.
bool hasPrefix(const std::string &text, const char *prefix);

// ---- Work on every core ----

/// Calls `body` once for every index below `count`, on as many threads as
/// there are cores, and returns when all of them have. The bodies must touch
/// nothing shared. dispatch_apply on Apple; std::thread elsewhere.
void parallelFor(size_t count, const std::function<void(size_t)> &body);

// ---- Pictures ----

/// Reads an image file into a `side` by `side` square of premultiplied sRGB
/// RGBA, row nought at the top of the picture. Empty on failure.
///
/// ImageIO and Core Graphics on Apple. Elsewhere, stb_image — which
/// Filament's release already links into libstb.a for gltfio, on every
/// platform it ships — and Filament's own resampler from libimage.
std::vector<uint8_t> readPicture(const std::string &path, uint32_t side);

// ---- Video ----

/// One video being decoded onto a Filament external texture.
///
/// A state is described to it, as everything else in the renderer is: open
/// a file, play at a rate, pause, loop or not. It hands the newest decoded
/// frame to the texture when asked, which is once a frame. AVFoundation on
/// Apple; nothing yet anywhere else.
class VideoDecoder {
 public:
  virtual ~VideoDecoder() = default;

  /// Opens a file, or a URL beginning with http. False if it cannot.
  virtual bool open(const std::string &path) = 0;

  /// Jumps exactly to `seconds`, without snapping to a keyframe.
  virtual void seek(double seconds) = 0;

  virtual void setVolume(float volume) = 0;
  virtual void play(float rate) = 0;
  virtual void pause() = 0;

  /// Whether reaching the end starts it again from the beginning.
  virtual void setLooping(bool looping) = 0;

  /// Hands the newest frame to `texture`, if a new one is ready, keeping it
  /// until the next replaces it. False when there was nothing new.
  virtual bool pump(filament::Engine &engine, filament::Texture *texture) = 0;

  /// Stops decoding and lets go of the player. The last frame handed over is
  /// kept until the decoder is destroyed, because the texture showing it is
  /// destroyed first.
  virtual void stop() = 0;
};

/// A decoder for this platform, or null where video is not supported yet —
/// which the renderer reports in its notes rather than failing.
std::unique_ptr<VideoDecoder> createVideoDecoder();

}  // namespace orbis
