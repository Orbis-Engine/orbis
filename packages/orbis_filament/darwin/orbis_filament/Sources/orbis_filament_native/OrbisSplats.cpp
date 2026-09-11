#include "OrbisSplats.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <fstream>
#include <limits>
#include <sstream>

namespace orbis {

void splatCovariance(const float scale[3], const float rotation[4],
                     float out[6]) {
  // Normalised here rather than trusted: a quaternion quantised to bytes is
  // never quite unit length, and a rotation that is not a rotation scales.
  float w = rotation[0], x = rotation[1], y = rotation[2], z = rotation[3];
  const float length = std::sqrt(w * w + x * x + y * y + z * z);
  if (length > 0) {
    w /= length;
    x /= length;
    y /= length;
    z /= length;
  } else {
    w = 1;
    x = y = z = 0;
  }

  // The rotation matrix of a unit quaternion, rows.
  const float r[3][3] = {
      {1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)},
      {2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)},
      {2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)},
  };
  const float s2[3] = {scale[0] * scale[0], scale[1] * scale[1],
                       scale[2] * scale[2]};

  // Σ = R diag(s²) Rᵀ, so Σij = Σk Rik Rjk sk². The same matrix the
  // reference builds as (S R)ᵀ (S R) with its column-major R.
  auto sigma = [&](int i, int j) {
    return r[i][0] * r[j][0] * s2[0] + r[i][1] * r[j][1] * s2[1] +
           r[i][2] * r[j][2] * s2[2];
  };
  out[0] = sigma(0, 0);
  out[1] = sigma(0, 1);
  out[2] = sigma(0, 2);
  out[3] = sigma(1, 1);
  out[4] = sigma(1, 2);
  out[5] = sigma(2, 2);
}

namespace {

uint8_t toByte(float value) {
  return uint8_t(std::clamp(std::lround(value * 255.0f), 0l, 255l));
}

/// Makes room, and resets the box so the first splat sets it.
void begin(SplatCloud &cloud, uint32_t count) {
  cloud.count = count;
  cloud.positions.assign(size_t(count) * 3, 0.0f);
  cloud.covariances.assign(size_t(count) * 6, 0.0f);
  cloud.colours.assign(count, 0u);
  for (int a = 0; a < 3; a++) {
    cloud.minimum[a] = std::numeric_limits<float>::max();
    cloud.maximum[a] = std::numeric_limits<float>::lowest();
  }
  cloud.harmonicDegree = 0;
  cloud.harmonics.clear();
  for (int band = 0; band < 3; band++) cloud.harmonicScale[band] = 0;
  cloud.droppedHigherBands = false;
}

/// One splat into the cloud, and the box grown round it to three sigma.
void put(SplatCloud &cloud, uint32_t i, const float position[3],
         const float scale[3], const float rotation[4], uint32_t colour) {
  std::memcpy(&cloud.positions[size_t(i) * 3], position, sizeof(float) * 3);
  splatCovariance(scale, rotation, &cloud.covariances[size_t(i) * 6]);
  cloud.colours[i] = colour;

  const float reach =
      3.0f * std::max({std::abs(scale[0]), std::abs(scale[1]), std::abs(scale[2])});
  for (int a = 0; a < 3; a++) {
    cloud.minimum[a] = std::min(cloud.minimum[a], position[a] - reach);
    cloud.maximum[a] = std::max(cloud.maximum[a], position[a] + reach);
  }
}

void finish(SplatCloud &cloud) {
  if (cloud.count > 0) return;
  for (int a = 0; a < 3; a++) cloud.minimum[a] = cloud.maximum[a] = 0;
}

}  // namespace

bool readSplatRecords(const uint8_t *data, size_t length, SplatCloud &into,
                      std::string &error) {
  if (length % kSplatRecordBytes != 0) {
    error = "a .splat file is whole 32-byte records, and this is " +
            std::to_string(length) + " bytes";
    return false;
  }
  const uint32_t count = uint32_t(length / kSplatRecordBytes);
  begin(into, count);

  for (uint32_t i = 0; i < count; i++) {
    const uint8_t *record = data + size_t(i) * kSplatRecordBytes;
    float position[3], scale[3];
    std::memcpy(position, record, 12);
    std::memcpy(scale, record + 12, 12);
    uint32_t colour;
    std::memcpy(&colour, record + 24, 4);
    const float rotation[4] = {
        (float(record[28]) - 128.0f) / 128.0f,
        (float(record[29]) - 128.0f) / 128.0f,
        (float(record[30]) - 128.0f) / 128.0f,
        (float(record[31]) - 128.0f) / 128.0f,
    };
    put(into, i, position, scale, rotation, colour);
  }
  finish(into);
  return true;
}

namespace {

/// What one PLY property is and where it sits in a vertex.
struct Property {
  std::string name;
  size_t offset = 0;
  size_t size = 0;
  char kind = 'f';  // f float, d double, u unsigned integer, i signed
};

size_t sizeOf(const std::string &type, char &kind) {
  if (type == "float" || type == "float32") { kind = 'f'; return 4; }
  if (type == "double" || type == "float64") { kind = 'd'; return 8; }
  if (type == "uchar" || type == "uint8") { kind = 'u'; return 1; }
  if (type == "char" || type == "int8") { kind = 'i'; return 1; }
  if (type == "ushort" || type == "uint16") { kind = 'u'; return 2; }
  if (type == "short" || type == "int16") { kind = 'i'; return 2; }
  if (type == "uint" || type == "uint32") { kind = 'u'; return 4; }
  if (type == "int" || type == "int32") { kind = 'i'; return 4; }
  return 0;
}

float readAs(const uint8_t *at, const Property &p) {
  switch (p.kind) {
    case 'f': { float v; std::memcpy(&v, at, 4); return v; }
    case 'd': { double v; std::memcpy(&v, at, 8); return float(v); }
    case 'u': {
      uint32_t v = 0;
      std::memcpy(&v, at, p.size);
      return float(v);
    }
    default: {
      if (p.size == 1) return float(int8_t(at[0]));
      if (p.size == 2) { int16_t v; std::memcpy(&v, at, 2); return float(v); }
      int32_t v; std::memcpy(&v, at, 4); return float(v);
    }
  }
}

/// Which band a coefficient belongs to, counting the first band as nought:
/// three coefficients in the first, five in the second, seven in the third.
uint32_t bandOf(uint32_t coefficient) {
  if (coefficient < 3) return 0;
  return coefficient < 8 ? 1 : 2;
}

/// One coefficient as the byte the shader decodes: 128 is nought, and the
/// band's scale either way is 1 and 255. Anything past the scale clamps.
uint8_t toHarmonicByte(float value, float scale) {
  if (!(scale > 0) || !std::isfinite(value)) return 128;
  const float unit = std::clamp(value / scale, -1.0f, 1.0f);
  return uint8_t(std::lround(unit * kSplatHarmonicSteps) + 128);
}

/// Reads the higher bands out of a PLY's vertices into the cloud.
///
/// `rest` is the property each kept coefficient lives in, channel-major as
/// the file has them: coefficient k of channel c is rest[c * keep + k].
///
/// Two passes, because what a byte is worth cannot be known until every
/// coefficient has been seen. The first only counts magnitudes; the second
/// writes the bytes, and reorders them on the way — out of the file's
/// channel-major order into one splat's coefficients together, which is how
/// the shader reads them.
void readHarmonics(const uint8_t *vertices, uint64_t count, size_t stride,
                   const std::vector<const Property *> &rest, uint32_t degree,
                   SplatCloud &into) {
  const uint32_t keep = kSplatHarmonicCoefficients[degree];
  if (keep == 0 || count == 0) return;

  // What a byte of each band is worth.
  //
  // A trained capture's coefficients are nearly all small and a few are not:
  // a handful of splats carry a coefficient many times larger than anything
  // else in the file, and a scale stretched to reach those would spend most
  // of a byte's 255 steps on values nothing has. So each band is scaled by
  // the magnitude 99.9% of its own coefficients are below and the rest clamp:
  // a few splats very slightly too bright, against a step several times finer
  // on all of them.
  //
  // The magnitudes go into fixed bins of a 128th up to eight rather than into
  // bins sized from the largest one seen, so this is one pass and not two,
  // and so one absurd coefficient cannot coarsen the histogram itself.
  constexpr int kBins = 1024;
  constexpr float kPerUnit = 128.0f;
  std::vector<uint64_t> histogram(size_t(kBins) * 3, 0);
  for (uint64_t i = 0; i < count; i++) {
    const uint8_t *v = vertices + size_t(i) * stride;
    for (uint32_t c = 0; c < 3; c++) {
      for (uint32_t k = 0; k < keep; k++) {
        const Property &p = *rest[size_t(c) * keep + k];
        const float value = readAs(v + p.offset, p);
        if (!std::isfinite(value)) continue;
        int bin = int(std::abs(value) * kPerUnit);
        if (bin >= kBins) bin = kBins - 1;
        histogram[size_t(bandOf(k)) * kBins + bin]++;
      }
    }
  }

  for (uint32_t band = 0; band < 3; band++) {
    uint64_t total = 0;
    for (int bin = 0; bin < kBins; bin++) total += histogram[size_t(band) * kBins + bin];
    if (total == 0) continue;
    const uint64_t want = uint64_t(double(total) * 0.999);
    uint64_t seen = 0;
    int at = 0;
    for (; at < kBins - 1; at++) {
      seen += histogram[size_t(band) * kBins + at];
      if (seen >= want) break;
    }
    // The top of that bin, and never nought: a band whose coefficients are
    // all exactly zero would otherwise be scaled by zero.
    into.harmonicScale[band] = std::max(float(at + 1) / kPerUnit, 1.0f / kPerUnit);
  }

  into.harmonicDegree = degree;
  into.harmonics.assign(size_t(count) * splatHarmonicBytes(degree), 128);
  for (uint64_t i = 0; i < count; i++) {
    const uint8_t *v = vertices + size_t(i) * stride;
    uint8_t *out = &into.harmonics[size_t(i) * splatHarmonicBytes(degree)];
    for (uint32_t k = 0; k < keep; k++) {
      const float scale = into.harmonicScale[bandOf(k)];
      for (uint32_t c = 0; c < 3; c++) {
        const Property &p = *rest[size_t(c) * keep + k];
        out[size_t(k) * 3 + c] = toHarmonicByte(readAs(v + p.offset, p), scale);
      }
    }
  }
}

}  // namespace

bool readSplatPly(const uint8_t *data, size_t length, uint32_t maxDegree,
                  SplatCloud &into, std::string &error) {
  // The header is text and ends at the first "end_header" line. Capped, so a
  // file that is not a PLY at all is refused rather than scanned to its end.
  const char *text = reinterpret_cast<const char *>(data);
  const size_t searchable = std::min<size_t>(length, 64 * 1024);
  const std::string head(text, searchable);
  const size_t end = head.find("end_header");
  if (head.rfind("ply", 0) != 0 || end == std::string::npos) {
    error = "not a PLY file: no ply/end_header header";
    return false;
  }
  size_t body = head.find('\n', end);
  if (body == std::string::npos) {
    error = "the PLY header has no line after end_header";
    return false;
  }
  body += 1;

  std::istringstream lines(head.substr(0, end));
  std::string line;
  bool binaryLittle = false;
  bool inVertex = false;
  bool vertexFirst = true;
  bool sawElement = false;
  uint64_t vertices = 0;
  size_t stride = 0;
  std::vector<Property> properties;

  while (std::getline(lines, line)) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    std::istringstream words(line);
    std::string word;
    words >> word;
    if (word == "format") {
      std::string format;
      words >> format;
      binaryLittle = format == "binary_little_endian";
    } else if (word == "element") {
      std::string name;
      words >> name;
      // Only the vertex element is read, and only when it comes first —
      // which is how every trainer writes it. Anything before it would need
      // its size worked out to be skipped.
      if (name == "vertex") {
        if (sawElement) vertexFirst = false;
        words >> vertices;
        inVertex = true;
      } else {
        inVertex = false;
      }
      sawElement = true;
    } else if (word == "property" && inVertex) {
      std::string type, name;
      words >> type;
      if (type == "list") {
        error = "a list property in the vertex element, which splats do not have";
        return false;
      }
      words >> name;
      Property p;
      p.name = name;
      p.size = sizeOf(type, p.kind);
      if (p.size == 0) {
        error = "a property of unknown type " + type;
        return false;
      }
      p.offset = stride;
      stride += p.size;
      properties.push_back(p);
    }
  }

  if (!binaryLittle) {
    error = "only binary_little_endian PLY is read";
    return false;
  }
  if (!vertexFirst) {
    error = "the vertex element has to come first";
    return false;
  }
  if (vertices == 0 || stride == 0) {
    error = "the PLY has no vertices";
    return false;
  }
  if (vertices > 50'000'000ull || body + vertices * stride > length) {
    error = "the PLY says " + std::to_string(vertices) +
            " vertices, more than the file holds";
    return false;
  }

  auto find = [&](const char *name) -> const Property * {
    for (const auto &p : properties) {
      if (p.name == name) return &p;
    }
    return nullptr;
  };

  const char *required[] = {"x", "y", "z", "f_dc_0", "f_dc_1", "f_dc_2",
                            "opacity", "scale_0", "scale_1", "scale_2",
                            "rot_0", "rot_1", "rot_2", "rot_3"};
  const Property *p[14];
  for (int i = 0; i < 14; i++) {
    p[i] = find(required[i]);
    if (p[i] == nullptr) {
      error = std::string("the PLY has no ") + required[i] +
              ", so it is not a Gaussian splat capture";
      return false;
    }
  }

  // The bands above the flat one, if the file has them and the caller asked
  // for them.
  //
  // f_rest_* is channel-major: every coefficient of red, then every one of
  // green, then blue. That is what the reference trainer writes when it
  // flattens its (splat, coefficient, channel) tensor with the last two
  // transposed, so coefficient k of channel c is property c * perChannel + k.
  // How many there are says which degree the capture was trained to: three a
  // channel is one band, eight is two, fifteen is three, and anything else is
  // a layout this does not know how to take apart.
  uint32_t stored = 0;
  while (find(("f_rest_" + std::to_string(stored)).c_str()) != nullptr) stored++;
  uint32_t fileDegree = 0;
  for (uint32_t d = 1; d <= kSplatMaxHarmonicDegree; d++) {
    if (stored == kSplatHarmonicCoefficients[d] * 3) fileDegree = d;
  }
  const uint32_t degree =
      std::min(fileDegree, std::min(maxDegree, kSplatMaxHarmonicDegree));

  std::vector<const Property *> rest;
  if (degree > 0) {
    const uint32_t keep = kSplatHarmonicCoefficients[degree];
    const uint32_t perChannel = stored / 3;
    rest.resize(size_t(keep) * 3);
    for (uint32_t c = 0; c < 3; c++) {
      for (uint32_t k = 0; k < keep; k++) {
        rest[size_t(c) * keep + k] =
            find(("f_rest_" + std::to_string(c * perChannel + k)).c_str());
      }
    }
  }

  begin(into, uint32_t(vertices));
  // Said when the picture is missing something the file had: bands above the
  // degree asked for, or a count of f_rest properties that is none of the
  // three a trainer writes.
  into.droppedHigherBands =
      fileDegree > degree || (stored > 0 && fileDegree == 0);

  for (uint32_t i = 0; i < uint32_t(vertices); i++) {
    const uint8_t *v = data + body + size_t(i) * stride;
    const float position[3] = {readAs(v + p[0]->offset, *p[0]),
                               readAs(v + p[1]->offset, *p[1]),
                               readAs(v + p[2]->offset, *p[2])};
    // The flat part of the colour, from the degree-zero coefficient. What the
    // higher bands add is read below and evaluated in the shader, where the
    // direction to the camera is known.
    const float r = 0.5f + kShC0 * readAs(v + p[3]->offset, *p[3]);
    const float g = 0.5f + kShC0 * readAs(v + p[4]->offset, *p[4]);
    const float b = 0.5f + kShC0 * readAs(v + p[5]->offset, *p[5]);
    // Stored as a logit, so it can be trained without a clamp.
    const float opacity =
        1.0f / (1.0f + std::exp(-readAs(v + p[6]->offset, *p[6])));
    // Stored as logs, for the same reason.
    const float scale[3] = {std::exp(readAs(v + p[7]->offset, *p[7])),
                            std::exp(readAs(v + p[8]->offset, *p[8])),
                            std::exp(readAs(v + p[9]->offset, *p[9]))};
    const float rotation[4] = {readAs(v + p[10]->offset, *p[10]),
                               readAs(v + p[11]->offset, *p[11]),
                               readAs(v + p[12]->offset, *p[12]),
                               readAs(v + p[13]->offset, *p[13])};
    const uint32_t colour = uint32_t(toByte(r)) | (uint32_t(toByte(g)) << 8) |
                            (uint32_t(toByte(b)) << 16) |
                            (uint32_t(toByte(opacity)) << 24);
    put(into, i, position, scale, rotation, colour);
  }
  readHarmonics(data + body, vertices, stride, rest, degree, into);
  finish(into);
  return true;
}

bool loadSplatFile(const std::string &path, uint32_t maxDegree,
                   SplatCloud &into, std::string &error) {
  std::ifstream file(path, std::ios::binary | std::ios::ate);
  if (!file) {
    error = "cannot open " + path;
    return false;
  }
  const std::streamsize size = file.tellg();
  file.seekg(0);
  std::vector<uint8_t> bytes(size_t(std::max<std::streamsize>(size, 0)));
  if (size > 0 && !file.read(reinterpret_cast<char *>(bytes.data()), size)) {
    error = "cannot read " + path;
    return false;
  }

  std::string lower = path;
  std::transform(lower.begin(), lower.end(), lower.begin(),
                 [](unsigned char c) { return char(std::tolower(c)); });
  const bool ply = lower.size() >= 4 && lower.compare(lower.size() - 4, 4, ".ply") == 0;
  return ply ? readSplatPly(bytes.data(), bytes.size(), maxDegree, into, error)
             : readSplatRecords(bytes.data(), bytes.size(), into, error);
}

void packSplatTexels(const SplatCloud &cloud, std::vector<uint32_t> &texels) {
  const size_t used = size_t(cloud.count) * kSplatTexelsPerSplat;
  const size_t rows = std::max<size_t>(1, (used + kSplatTextureWidth - 1) /
                                              kSplatTextureWidth);
  texels.assign(rows * kSplatTextureWidth * 4, 0u);

  auto bits = [](float value) {
    uint32_t out;
    std::memcpy(&out, &value, 4);
    return out;
  };

  for (uint32_t i = 0; i < cloud.count; i++) {
    const float *p = &cloud.positions[size_t(i) * 3];
    const float *c = &cloud.covariances[size_t(i) * 6];
    uint32_t *t = &texels[size_t(i) * kSplatTexelsPerSplat * 4];
    t[0] = bits(p[0]);
    t[1] = bits(p[1]);
    t[2] = bits(p[2]);
    t[3] = bits(c[0]);
    t[4] = bits(c[1]);
    t[5] = bits(c[2]);
    t[6] = bits(c[3]);
    t[7] = bits(c[4]);
    t[8] = bits(c[5]);
    t[9] = cloud.colours[i];
  }
}

void packSplatHarmonicTexels(const SplatCloud &cloud,
                             std::vector<uint32_t> &texels) {
  const uint32_t perSplat = splatHarmonicTexels(cloud.harmonicDegree);
  const uint32_t bytes = splatHarmonicBytes(cloud.harmonicDegree);
  if (cloud.count == 0 || perSplat == 0 ||
      cloud.harmonics.size() < size_t(cloud.count) * bytes) {
    texels.clear();
    return;
  }

  const size_t used = size_t(cloud.count) * perSplat;
  const size_t rows = std::max<size_t>(1, (used + kSplatTextureWidth - 1) /
                                              kSplatTextureWidth);
  // Filled with 128s, which is a coefficient of nought. Nothing reads the
  // few bytes left over at the end of a splat's texels or the end of the
  // last row, and if anything ever does it reads no colour rather than a
  // coefficient of minus one.
  texels.assign(rows * kSplatTextureWidth * 4, 0x80808080u);

  for (uint32_t i = 0; i < cloud.count; i++) {
    const uint8_t *from = &cloud.harmonics[size_t(i) * bytes];
    uint32_t *to = &texels[size_t(i) * perSplat * 4];
    for (uint32_t b = 0; b < bytes; b++) {
      // Placed by shifting rather than by copying the bytes across, so the
      // byte a coefficient lands in is the one splat.mat shifts back out of
      // it whatever order this processor stores an integer in.
      const uint32_t within = (b % 4) * 8;
      uint32_t &word = to[b / 4];
      word = (word & ~(0xffu << within)) | (uint32_t(from[b]) << within);
    }
  }
}

void sortSplatsBackToFront(const float *positions, uint32_t count,
                           const float direction[3],
                           std::vector<uint32_t> &order,
                           std::vector<uint32_t> &scratch) {
  order.resize(count);
  if (count == 0) return;

  // Keys and indices side by side, ping-ponged between two halves of one
  // buffer: [keys | indices] in scratch, the same in a second block.
  scratch.resize(size_t(count) * 4);
  uint32_t *keys = scratch.data();
  uint32_t *ids = keys + count;
  uint32_t *keysOut = ids + count;
  uint32_t *idsOut = keysOut + count;

  // All four byte histograms in the one pass that makes the keys.
  uint32_t counts[4][256] = {};
  const float dx = direction[0], dy = direction[1], dz = direction[2];
  for (uint32_t i = 0; i < count; i++) {
    const float *p = positions + size_t(i) * 3;
    const float depth = p[0] * dx + p[1] * dy + p[2] * dz;
    // Inverted, so that ascending is farthest first.
    const uint32_t key = ~sortableBits(depth);
    keys[i] = key;
    ids[i] = i;
    counts[0][key & 0xff]++;
    counts[1][(key >> 8) & 0xff]++;
    counts[2][(key >> 16) & 0xff]++;
    counts[3][key >> 24]++;
  }

  for (int pass = 0; pass < 4; pass++) {
    const int shift = pass * 8;
    uint32_t *histogram = counts[pass];
    // Every key agrees on this byte, so the pass would move nothing.
    if (histogram[(keys[0] >> shift) & 0xff] == count) continue;

    uint32_t offsets[256];
    uint32_t total = 0;
    for (int b = 0; b < 256; b++) {
      offsets[b] = total;
      total += histogram[b];
    }
    for (uint32_t i = 0; i < count; i++) {
      const uint32_t at = offsets[(keys[i] >> shift) & 0xff]++;
      keysOut[at] = keys[i];
      idsOut[at] = ids[i];
    }
    std::swap(keys, keysOut);
    std::swap(ids, idsOut);
  }

  std::memcpy(order.data(), ids, sizeof(uint32_t) * count);
}

SplatSorter::SplatSorter(std::shared_ptr<const std::vector<float>> positions,
                         uint32_t count)
    : _positions(std::move(positions)), _count(count) {
  _worker = std::thread([this] { run(); });
}

SplatSorter::~SplatSorter() {
  {
    std::lock_guard<std::mutex> guard(_lock);
    _stopping = true;
  }
  _wake.notify_all();
  if (_worker.joinable()) _worker.join();
}

void SplatSorter::request(const float direction[3]) {
  {
    std::lock_guard<std::mutex> guard(_lock);
    std::memcpy(_direction, direction, sizeof(_direction));
    _pending = true;
  }
  _wake.notify_one();
}

bool SplatSorter::busy() {
  std::lock_guard<std::mutex> guard(_lock);
  return _pending || _working;
}

bool SplatSorter::take(std::vector<uint32_t> &order, double &milliseconds) {
  std::lock_guard<std::mutex> guard(_lock);
  if (!_ready) return false;
  order.swap(_result);
  milliseconds = _milliseconds;
  _ready = false;
  return true;
}

void SplatSorter::run() {
  std::vector<uint32_t> order;
  std::vector<uint32_t> scratch;
  for (;;) {
    float direction[3];
    {
      std::unique_lock<std::mutex> guard(_lock);
      _wake.wait(guard, [this] { return _stopping || _pending; });
      if (_stopping) return;
      std::memcpy(direction, _direction, sizeof(direction));
      _pending = false;
      _working = true;
    }

    const auto from = std::chrono::steady_clock::now();
    sortSplatsBackToFront(_positions->data(), _count, direction, order,
                          scratch);
    const double took = std::chrono::duration<double, std::milli>(
                            std::chrono::steady_clock::now() - from)
                            .count();

    {
      std::lock_guard<std::mutex> guard(_lock);
      _result.swap(order);
      _milliseconds = took;
      _ready = true;
      _working = false;
    }
  }
}

}  // namespace orbis
