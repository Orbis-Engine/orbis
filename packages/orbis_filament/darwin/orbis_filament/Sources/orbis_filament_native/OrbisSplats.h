// Gaussian splats on the processor: reading them, and putting them in order.
//
// Plain C++ with nothing from Filament, Apple or any platform in it, because
// this is the half of splatting that every port needs unchanged: the file
// formats are the same everywhere, and so is the sort. What differs from one
// renderer backend to the next is only how the result reaches the GPU, and
// that is OrbisSplatSet's business.
//
// 3D Gaussian splatting is Kerbl, Kopanas, Leimkühler and Drettakis,
// SIGGRAPH 2023. The compact `.splat` layout is the one antimatter15's web
// viewer introduced and most tools now write.
#pragma once

#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace orbis {

/// Floats per splat set in the scene message: a column-major transform, an
/// opacity multiplier and a brightness multiplier. Must match
/// OrbisSplats.stride in Dart and splatStride in the plugin.
constexpr size_t kSplatParams = 18;

/// Bytes per splat in the compact layout, which is also the layout an
/// in-memory cloud travels in: position, scale, colour, rotation.
constexpr size_t kSplatRecordBytes = 32;

/// Width of the textures the splats and their order live in. Must match
/// kWidth in splat.mat.
constexpr uint32_t kSplatTextureWidth = 2048;

/// Texels one splat takes in the splat texture: centre and the covariance's
/// first element; four more elements; the last element and the colour.
constexpr uint32_t kSplatTexelsPerSplat = 3;

/// The degree-zero spherical harmonic, which is what turns a trained
/// `f_dc` coefficient into a colour: 0.5 + SH_C0 * f_dc.
constexpr float kShC0 = 0.28209479177387814f;

/// The highest spherical-harmonic degree a capture is read at.
///
/// Three because there is no fourth to support: a trained capture carries 3,
/// 8 or 15 coefficients a colour channel and nothing else.
constexpr uint32_t kSplatMaxHarmonicDegree = 3;

/// Coefficients one colour channel has at each degree: none at all, then the
/// first band's three, the second band's five on top of those, the third's
/// seven on top again.
constexpr uint32_t kSplatHarmonicCoefficients[4] = {0, 3, 8, 15};

/// Texels one splat's harmonics take at `degree` — which is `degree` itself.
///
/// A texel of the harmonics texture is four unsigned integers and a
/// coefficient is quantised to a byte, so sixteen coefficients fit in one.
/// Nine bytes carry the first band for three channels, twenty-four carry two
/// bands and forty-five carry three: one, two and three texels exactly, with
/// seven, eight and three bytes spare. Paying those few bytes keeps a splat's
/// harmonics at a whole number of texels, so the shader fetches `degree` of
/// them at a known offset rather than working out which texel a coefficient
/// straddles.
constexpr uint32_t splatHarmonicTexels(uint32_t degree) { return degree; }

/// Bytes one splat's harmonics take before that padding.
constexpr uint32_t splatHarmonicBytes(uint32_t degree) {
  return kSplatHarmonicCoefficients[degree] * 3;
}

/// How far either side of a band's scale a stored byte reaches.
///
/// A coefficient becomes 128 + round(127 * coefficient / scale), so 128 is
/// nought exactly and 1 and 255 are the scale itself either way. Must match
/// the decode in splat.mat.
constexpr float kSplatHarmonicSteps = 127.0f;

/// A cloud as the renderer holds it, already turned into what the shader
/// reads: a centre, the six numbers of a symmetric 3D covariance, and a
/// colour with its opacity.
struct SplatCloud {
  uint32_t count = 0;
  std::vector<float> positions;    // three each
  std::vector<float> covariances;  // six each: 00 01 02 11 12 22
  std::vector<uint32_t> colours;   // RGBA8, red in the low byte
  /// A box around every splat out to three standard deviations.
  float minimum[3] = {0, 0, 0};
  float maximum[3] = {0, 0, 0};

  /// The degree of the spherical harmonics in `harmonics`: 0 for a cloud that
  /// is the same colour from everywhere, up to kSplatMaxHarmonicDegree.
  uint32_t harmonicDegree = 0;
  /// The bands above the flat one, a byte a coefficient: per splat, in the
  /// order the coefficients come, with red, green and blue together within
  /// each. splatHarmonicBytes(degree) of them a splat, and empty at degree 0.
  ///
  /// Not in the order the file has them. A `.ply` writes every coefficient of
  /// red, then of green, then of blue, which is the worst order to read one
  /// splat's coefficients in; this is the order the shader wants them.
  std::vector<uint8_t> harmonics;
  /// What a byte of `harmonics` is worth, band by band from the first.
  /// Nought for a band that is not there.
  float harmonicScale[3] = {0, 0, 0};

  /// Whether the file had higher spherical-harmonic bands that were read
  /// past. Said so a caller can report it rather than pretend.
  bool droppedHigherBands = false;
};

/// Σ = R S Sᵀ Rᵀ, from per-axis scales (already exponentiated) and a unit
/// quaternion in (w, x, y, z) order — the order `rot_0..3` are stored in.
void splatCovariance(const float scale[3], const float rotation[4],
                     float out[6]);

/// Reads the compact 32-byte layout: position float3, scale float3 (linear,
/// not log), colour RGBA8 with opacity in alpha, rotation as four bytes
/// (w, x, y, z), each (byte - 128) / 128.
bool readSplatRecords(const uint8_t *data, size_t length, SplatCloud &into,
                      std::string &error);

/// Reads the layout the reference trainer writes: a binary little-endian PLY
/// whose vertex element has x y z, f_dc_0..2, optional f_rest_*, opacity as
/// a logit, scale_0..2 as log-scales and rot_0..3.
///
/// `maxDegree` is how much of the view-dependent colour to keep: 0 for the
/// flat degree-zero colour alone, up to kSplatMaxHarmonicDegree. A file
/// carrying more bands than that is read to the degree asked for and says so
/// in `droppedHigherBands`; one carrying fewer is read as far as it goes.
bool readSplatPly(const uint8_t *data, size_t length, uint32_t maxDegree,
                  SplatCloud &into, std::string &error);

/// Either of the above, chosen by the file's extension. A `.splat` has no
/// room for higher bands, so `maxDegree` only reaches a `.ply`.
bool loadSplatFile(const std::string &path, uint32_t maxDegree,
                   SplatCloud &into, std::string &error);

/// The cloud as the RGBA32UI texels the shader fetches, padded out to whole
/// rows of kSplatTextureWidth.
void packSplatTexels(const SplatCloud &cloud, std::vector<uint32_t> &texels);

/// The cloud's harmonics as their own RGBA32UI texels, sixteen quantised
/// coefficients to a texel and splatHarmonicTexels(degree) texels a splat,
/// padded out to whole rows. Empty for a cloud at degree 0, which is what
/// keeps a capture without them costing nothing at all.
void packSplatHarmonicTexels(const SplatCloud &cloud,
                             std::vector<uint32_t> &texels);

/// A float as an unsigned integer that sorts the same way.
inline uint32_t sortableBits(float value) {
  uint32_t bits;
  static_assert(sizeof(bits) == sizeof(value), "a float is four bytes");
  __builtin_memcpy(&bits, &value, sizeof(bits));
  // Negative floats sort backwards and below the positive ones, so their
  // bits are all flipped; positive ones only need the sign bit set.
  return (bits & 0x80000000u) ? ~bits : (bits | 0x80000000u);
}

/// Puts every splat in order, farthest along `direction` first.
///
/// An LSD radix sort on a 32-bit key: the float depth made sortable, then
/// inverted so that ascending order is back to front. Four passes of eight
/// bits, each skipped when every key agrees on that byte. `scratch` is kept
/// by the caller so a million-splat sort does not allocate each time.
void sortSplatsBackToFront(const float *positions, uint32_t count,
                           const float direction[3],
                           std::vector<uint32_t> &order,
                           std::vector<uint32_t> &scratch);

/// Sorts on a thread of its own, so the render thread never waits for one.
///
/// The render thread asks, carries on drawing with the order it already has,
/// and picks the answer up on whichever frame it is ready. At a million
/// splats a sort is tens of milliseconds, and a frame that waited for it
/// would be the hitch every camera turn produced.
///
/// The positions are shared and never written after construction, so the
/// worker reads them without a lock. Only the request and the answer cross
/// between the threads, and both are behind one.
class SplatSorter {
 public:
  SplatSorter(std::shared_ptr<const std::vector<float>> positions,
              uint32_t count);
  ~SplatSorter();

  SplatSorter(const SplatSorter &) = delete;
  SplatSorter &operator=(const SplatSorter &) = delete;

  /// Asks for a sort along `direction`. A request made while another is
  /// still waiting replaces it: only the newest camera matters.
  void request(const float direction[3]);

  /// Whether a request is waiting or being worked on.
  bool busy();

  /// Hands over the newest finished order, if there is one since last time.
  bool take(std::vector<uint32_t> &order, double &milliseconds);

 private:
  void run();

  std::shared_ptr<const std::vector<float>> _positions;
  uint32_t _count;

  std::mutex _lock;
  std::condition_variable _wake;
  bool _stopping = false;
  bool _pending = false;
  bool _working = false;
  bool _ready = false;
  float _direction[3] = {0, 0, -1};
  std::vector<uint32_t> _result;
  double _milliseconds = 0;

  std::thread _worker;
};

}  // namespace orbis
