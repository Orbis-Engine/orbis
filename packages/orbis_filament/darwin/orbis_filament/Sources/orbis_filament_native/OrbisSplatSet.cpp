#include "OrbisSplatSet.h"

#include <filament/Box.h>
#include <filament/RenderableManager.h>
#include <filament/TextureSampler.h>
#include <filament/TransformManager.h>
#include <math/mat4.h>
#include <utils/EntityManager.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>

#include "generated/splat_material.h"

namespace orbis {

using namespace filament;
using filament::math::float3;
using filament::math::mat4f;

namespace {

/// Re-sort once the view has turned by more than this. The order only
/// depends on the direction the camera faces — moving it along that
/// direction adds the same amount to every depth — so this is the one thing
/// worth watching. A third of a degree is below what a slow orbit moves in a
/// frame and above what a hand resting on a trackpad does.
const float kResortCos = std::cos(0.3f * float(M_PI) / 180.0f);

uint32_t rowsFor(size_t texels) {
  return uint32_t(std::max<size_t>(
      1, (texels + kSplatTextureWidth - 1) / kSplatTextureWidth));
}

}  // namespace

SplatSet::SplatSet(Engine &engine, Scene &scene, Material &material,
                   SplatCloud &&cloud)
    : _engine(engine), _scene(scene), _count(cloud.count) {
  const uint32_t count = std::max<uint32_t>(_count, 1);

  // The splats themselves, as bits.
  std::vector<uint32_t> texels;
  packSplatTexels(cloud, texels);
  const uint32_t splatRows =
      rowsFor(size_t(count) * kSplatTexelsPerSplat);
  _splats = Texture::Builder()
                .width(kSplatTextureWidth)
                .height(splatRows)
                .levels(1)
                .sampler(Texture::Sampler::SAMPLER_2D)
                .format(Texture::InternalFormat::RGBA32UI)
                .build(engine);
  auto *splatBytes = new uint32_t[texels.size()];
  std::memcpy(splatBytes, texels.data(), texels.size() * sizeof(uint32_t));
  _splats->setImage(
      engine, 0,
      Texture::PixelBufferDescriptor(
          splatBytes, texels.size() * sizeof(uint32_t),
          Texture::PixelBufferDescriptor::PixelDataFormat::RGBA_INTEGER,
          Texture::PixelBufferDescriptor::PixelDataType::UINT,
          [](void *buffer, size_t, void *) {
            delete[] static_cast<uint32_t *>(buffer);
          }));

  _order = Texture::Builder()
               .width(kSplatTextureWidth)
               .height(rowsFor(count))
               .levels(1)
               .sampler(Texture::Sampler::SAMPLER_2D)
               .format(Texture::InternalFormat::R32UI)
               .build(engine);
  std::vector<uint32_t> given(_count);
  for (uint32_t i = 0; i < _count; i++) given[i] = i;
  uploadOrder(given);

  // The spherical-harmonic bands above the flat colour, when the cloud has
  // any.
  //
  // Their own texture rather than more texels on the end of the splat one,
  // for two reasons. A cloud without them — every `.splat`, every capture
  // trained to degree nought, and any capture read with them turned off —
  // pays one texel here and nothing else, and the splat texture it does read
  // is laid out to the byte as it was before there were any bands. And the
  // two are read at different rates: three texels a splat are fetched always,
  // these only when there is a degree to evaluate.
  std::vector<uint32_t> harmonics;
  packSplatHarmonicTexels(cloud, harmonics);
  const uint32_t degree = harmonics.empty() ? 0 : cloud.harmonicDegree;
  // A sampler a material declares has to be bound whether or not the shader
  // reads it, so degree nought still gets a texture: one texel, sixteen 128s,
  // which is a coefficient of nothing in every channel.
  if (degree == 0) harmonics.assign(4, 0x80808080u);
  _harmonics =
      Texture::Builder()
          .width(degree == 0 ? 1 : kSplatTextureWidth)
          .height(degree == 0
                      ? 1
                      : rowsFor(size_t(count) * splatHarmonicTexels(degree)))
          .levels(1)
          .sampler(Texture::Sampler::SAMPLER_2D)
          .format(Texture::InternalFormat::RGBA32UI)
          .build(engine);
  auto *harmonicBytes = new uint32_t[harmonics.size()];
  std::memcpy(harmonicBytes, harmonics.data(),
              harmonics.size() * sizeof(uint32_t));
  _harmonics->setImage(
      engine, 0,
      Texture::PixelBufferDescriptor(
          harmonicBytes, harmonics.size() * sizeof(uint32_t),
          Texture::PixelBufferDescriptor::PixelDataFormat::RGBA_INTEGER,
          Texture::PixelBufferDescriptor::PixelDataType::UINT,
          [](void *buffer, size_t, void *) {
            delete[] static_cast<uint32_t *>(buffer);
          }));
  if (degree > 0) {
    // What the bands cost, said out loud: a million splats at degree two is
    // another thirty-two megabytes on the card, and the number anybody
    // deciding whether to pay it wants is this one.
    std::fprintf(stderr,
                 "[orbis] splats: degree-%u colour on %u splats: %u bytes a "
                 "splat, %.1f MB, band scales %.3f %.3f %.3f\n",
                 degree, _count, splatHarmonicTexels(degree) * 16u,
                 double(harmonics.size() * sizeof(uint32_t)) / (1024 * 1024),
                 double(cloud.harmonicScale[0]), double(cloud.harmonicScale[1]),
                 double(cloud.harmonicScale[2]));
  }

  // Four corners a splat, each only saying which corner it is. The vertex's
  // own index says which splat, so these never change — a re-sort rewrites
  // the order texture and nothing else. Bytes, normalised, because ±1 and a
  // w of one is all there is to say.
  const size_t vertices = size_t(count) * 4;
  auto *corners = new int8_t[vertices * 4];
  static const int8_t kCorner[4][4] = {
      {-127, -127, 0, 127}, {127, -127, 0, 127},
      {127, 127, 0, 127},   {-127, 127, 0, 127}};
  for (size_t v = 0; v < vertices; v++) {
    std::memcpy(corners + v * 4, kCorner[v % 4], 4);
  }
  _corners = VertexBuffer::Builder()
                 .vertexCount(uint32_t(vertices))
                 .bufferCount(1)
                 .attribute(VertexAttribute::POSITION, 0,
                            VertexBuffer::AttributeType::BYTE4, 0, 4)
                 .normalized(VertexAttribute::POSITION)
                 .build(engine);
  _corners->setBufferAt(engine, 0,
                        VertexBuffer::BufferDescriptor(
                            corners, vertices * 4,
                            [](void *buffer, size_t, void *) {
                              delete[] static_cast<int8_t *>(buffer);
                            }));

  const size_t indexCount = size_t(count) * 6;
  auto *indices = new uint32_t[indexCount];
  for (uint32_t s = 0; s < count; s++) {
    const uint32_t base = s * 4;
    uint32_t *at = indices + size_t(s) * 6;
    at[0] = base;
    at[1] = base + 1;
    at[2] = base + 2;
    at[3] = base;
    at[4] = base + 2;
    at[5] = base + 3;
  }
  _indices = IndexBuffer::Builder()
                 .indexCount(uint32_t(indexCount))
                 .bufferType(IndexBuffer::IndexType::UINT)
                 .build(engine);
  _indices->setBuffer(engine,
                      IndexBuffer::BufferDescriptor(
                          indices, indexCount * sizeof(uint32_t),
                          [](void *buffer, size_t, void *) {
                            delete[] static_cast<uint32_t *>(buffer);
                          }));

  const TextureSampler nearest(TextureSampler::MinFilter::NEAREST,
                               TextureSampler::MagFilter::NEAREST);
  _instance = material.createInstance();
  _instance->setParameter("splats", _splats, nearest);
  _instance->setParameter("order", _order, nearest);
  _instance->setParameter("harmonics", _harmonics, nearest);
  _instance->setParameter("harmonicDegree", int32_t(degree));
  _instance->setParameter(
      "harmonicScale",
      float3{cloud.harmonicScale[0], cloud.harmonicScale[1],
             cloud.harmonicScale[2]});
  _instance->setParameter("opacity", 1.0f);
  _instance->setParameter("brightness", 1.0f);

  // Culled by the box round every splat out to three sigma, in the cloud's
  // own space; Filament carries it through the transform.
  const float3 least{cloud.minimum[0], cloud.minimum[1], cloud.minimum[2]};
  const float3 most{cloud.maximum[0], cloud.maximum[1], cloud.maximum[2]};
  _entity = utils::EntityManager::get().create();
  RenderableManager::Builder(1)
      .boundingBox(Box{(least + most) * 0.5f, (most - least) * 0.5f})
      .material(0, _instance)
      .geometry(0, RenderableManager::PrimitiveType::TRIANGLES, _corners,
                _indices, 0, indexCount)
      // A cloud has no surface to catch a shadow on and none of its splats
      // is solid enough to cast one.
      .castShadows(false)
      .receiveShadows(false)
      .build(engine, _entity);
  engine.getTransformManager().create(_entity);
  _scene.addEntity(_entity);

  // The positions go to the sorter and nowhere else. Shared, and never
  // written again, which is what lets the worker read them without a lock.
  auto positions =
      std::make_shared<const std::vector<float>>(std::move(cloud.positions));
  _sorter = std::make_unique<SplatSorter>(std::move(positions), _count);
}

SplatSet::~SplatSet() {
  // The worker first: it holds nothing of Filament's, but it is the one
  // thing here that runs on its own.
  _sorter.reset();

  // Renderable, then the instance it wears, then what the instance samples
  // and what the renderable draws from. Any other order trips a Filament
  // precondition, which aborts — see clearPopulation in the .mm.
  _scene.remove(_entity);
  _engine.getTransformManager().destroy(_entity);
  _engine.destroy(_entity);
  utils::EntityManager::get().destroy(_entity);
  _engine.destroy(_instance);
  _engine.destroy(_splats);
  _engine.destroy(_order);
  _engine.destroy(_harmonics);
  _engine.destroy(_corners);
  _engine.destroy(_indices);
}

void SplatSet::setTransform(const float matrix[16]) {
  if (std::memcmp(matrix, _matrix, sizeof(_matrix)) == 0) return;
  std::memcpy(_matrix, matrix, sizeof(_matrix));
  mat4f m;
  for (int column = 0; column < 4; column++) {
    for (int row = 0; row < 4; row++) m[column][row] = matrix[column * 4 + row];
  }
  auto &transforms = _engine.getTransformManager();
  transforms.setTransform(transforms.getInstance(_entity), m);
}

void SplatSet::setOpacity(float opacity) {
  _instance->setParameter("opacity", opacity);
}

void SplatSet::setBrightness(float brightness) {
  _instance->setParameter("brightness", brightness);
}

void SplatSet::setSorted(bool sorted) { _sorted = sorted; }

void SplatSet::update(const float3 &forward) {
  if (_count == 0) return;

  if (!_sorted) {
    if (!_showingGiven) {
      std::vector<uint32_t> given(_count);
      for (uint32_t i = 0; i < _count; i++) given[i] = i;
      uploadOrder(given);
      _showingGiven = true;
      _everSorted = false;
    }
    return;
  }

  std::vector<uint32_t> order;
  double took = 0;
  if (_sorter->take(order, took)) {
    uploadOrder(order);
    _lastSortMs = took;
    _showingGiven = false;
    // What a sort costs is the number anybody tuning this wants, and it is
    // off the render thread so the frame timings do not show it. The first
    // few and then one in fifty, so a camera that never stops turning does
    // not fill the log.
    _sortsLanded++;
    if (_sortsLanded <= 3 || _sortsLanded % 50 == 0) {
      std::fprintf(stderr,
                   "[orbis] splats: sort %u of %u splats took %.2f ms on the "
                   "sorting thread (first %u, middle %u)\n",
                   _sortsLanded, _count, took, order.empty() ? 0 : order[0],
                   order.empty() ? 0 : order[order.size() / 2]);
    }
  }

  // Depth along the camera's forward, in the cloud's own space: that is
  // the transpose of the model matrix's upper 3x3 applied to forward, so
  // one dot product a splat, and a cloud that is scaled or turned sorts
  // exactly as it is drawn.
  float3 along{
      _matrix[0] * forward.x + _matrix[1] * forward.y + _matrix[2] * forward.z,
      _matrix[4] * forward.x + _matrix[5] * forward.y + _matrix[6] * forward.z,
      _matrix[8] * forward.x + _matrix[9] * forward.y + _matrix[10] * forward.z};
  // Refused unless it is a real direction. A camera that has not settled
  // yet can hand back NaN, and a sort along NaN is worse than no sort: every
  // depth is NaN, every key the same, so the stable sort returns the splats
  // in the order they came — and then no later direction compares as
  // different from NaN, so it stays that way for good. That is what one run
  // of the example showed, identical to the pixel with the sort on and off.
  const float length = std::sqrt(dot(along, along));
  if (!(length > 0) || !std::isfinite(length)) {
    if (!_warnedDegenerate) {
      std::fprintf(stderr,
                   "[orbis] splats: camera forward is not a direction yet; "
                   "holding the sort until it is\n");
      _warnedDegenerate = true;
    }
    return;
  }
  along /= length;

  // Written so that anything that is not clearly the same direction —
  // including a comparison with NaN, which is false both ways — counts as
  // turned.
  const bool turned = !_everSorted || !(dot(along, _sortedAlong) >= kResortCos);
  // One in flight at a time. A camera that keeps turning gets a new sort
  // as soon as the last one lands, which is the most often it can have one.
  if (turned && !_sorter->busy()) {
    const float direction[3] = {along.x, along.y, along.z};
    _sorter->request(direction);
    _sortedAlong = along;
    _everSorted = true;
  }
}

void SplatSet::uploadOrder(const std::vector<uint32_t> &order) {
  const uint32_t rows = rowsFor(std::max<uint32_t>(_count, 1));
  const size_t texels = size_t(rows) * kSplatTextureWidth;
  auto *bytes = new uint32_t[texels];
  std::memcpy(bytes, order.data(),
              std::min(order.size(), texels) * sizeof(uint32_t));
  if (order.size() < texels) {
    std::fill(bytes + order.size(), bytes + texels, 0u);
  }
  _order->setImage(
      _engine, 0,
      Texture::PixelBufferDescriptor(
          bytes, texels * sizeof(uint32_t),
          Texture::PixelBufferDescriptor::PixelDataFormat::R_INTEGER,
          Texture::PixelBufferDescriptor::PixelDataType::UINT,
          [](void *buffer, size_t, void *) {
            delete[] static_cast<uint32_t *>(buffer);
          }));
}

SplatScene::SplatScene(Engine &engine, Scene &scene)
    : _engine(engine), _scene(scene) {}

SplatScene::~SplatScene() { clear(); }

void SplatScene::clear() {
  _sets.clear();
  if (_material != nullptr) {
    _engine.destroy(_material);
    _material = nullptr;
  }
}

void SplatScene::apply(const std::vector<SplatRequest> &requests,
                       std::vector<std::pair<std::string, std::string>> &notes) {
  const uint64_t generation = ++_generation;

  for (const SplatRequest &request : requests) {
    Kept &kept = _sets[request.key];
    kept.seen = generation;

    // A file is read when its path changes; a cloud sent in memory is
    // rebuilt when its data arrives, which is only when its revision moved.
    const bool fromFile = !request.path.empty();
    // Bit nought of the flags says whether the cloud is sorted; the two above
    // it say how many spherical-harmonic bands to read, which is a property
    // of the reading rather than of the drawing — so a cloud asked for at a
    // different degree is read again, because what was left out on the way in
    // is not on the card to be brought back.
    const uint32_t degree = std::min<uint32_t>(uint32_t((request.flags >> 1) & 3),
                                               kSplatMaxHarmonicDegree);
    const bool wanted = fromFile ? (!kept.set || kept.path != request.path ||
                                    kept.degree != degree)
                                 : (request.data != nullptr &&
                                    (!kept.set || kept.revision != request.revision));
    if (wanted) {
      SplatCloud cloud;
      std::string error;
      const bool read =
          fromFile ? loadSplatFile(request.path, degree, cloud, error)
                   : readSplatRecords(request.data, request.bytes, cloud, error);
      kept.set.reset();
      kept.path = request.path;
      kept.revision = request.revision;
      kept.degree = degree;
      if (!read) {
        notes.emplace_back(fromFile ? request.path
                                    : "splats " + std::to_string(request.key),
                           error);
        continue;
      }
      if (cloud.droppedHigherBands && fromFile) {
        notes.emplace_back(
            request.path,
            cloud.harmonicDegree == 0
                ? "drawn with degree-0 colour only; the file's higher "
                  "spherical-harmonic bands were not read"
                : "drawn to spherical-harmonic degree " +
                      std::to_string(cloud.harmonicDegree) +
                      "; the bands the file has above that were not read");
      }
      if (_material == nullptr) {
        _material = Material::Builder()
                        .package(ksplatMaterial, ksplatMaterial_len)
                        .build(_engine);
      }
      kept.set = std::make_unique<SplatSet>(_engine, _scene, *_material,
                                            std::move(cloud));
    }

    if (!kept.set) continue;
    kept.set->setTransform(request.params);
    kept.set->setOpacity(request.params[16]);
    kept.set->setBrightness(request.params[17]);
    kept.set->setSorted((request.flags & 1) != 0);
  }

  for (auto it = _sets.begin(); it != _sets.end();) {
    if (it->second.seen == generation) {
      ++it;
    } else {
      it = _sets.erase(it);
    }
  }
}

void SplatScene::update(const float3 &forward) {
  for (auto &pair : _sets) {
    if (pair.second.set) pair.second.set->update(forward);
  }
}

}  // namespace orbis
