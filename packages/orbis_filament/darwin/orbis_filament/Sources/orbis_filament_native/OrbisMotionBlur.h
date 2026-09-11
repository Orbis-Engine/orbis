// Motion blur: what the renderer remembers between frames, and the passes
// that turn it into a streak.
//
// Plain C++ against Filament's public API and nothing else — no Objective-C,
// nothing from Apple — so that it moves with the renderer when the renderer
// stops being an Objective-C++ file. The renderer calls it from a handful of
// places, each marked "motion blur hook" where it does.
//
// Kept next to OrbisRenderer.mm rather than in include/, because include/ is
// the module Swift imports and has to stay free of C++.
#pragma once

#include <filament/Camera.h>
#include <filament/Engine.h>
#include <filament/MaterialInstance.h>
#include <filament/Renderer.h>
#include <filament/Texture.h>
#include <math/mat4.h>
#include <utils/Entity.h>

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <unordered_map>
#include <vector>

namespace filament {
class IndexBuffer;
class Material;
class RenderTarget;
class Scene;
class VertexBuffer;
class View;
}  // namespace filament

namespace orbis {

/// Motion blur for one renderer.
///
/// Two halves. The first is memory: where the camera stood last frame, and
/// where every object stood in the scene published before this one, kept here
/// so that a host which simply republishes its scene gets motion blur without
/// tracking anything itself. The second is four passes run inside the
/// graph's one motion blur pass: moving objects drawn again as velocity, that
/// merged with the camera's motion rebuilt from depth, the largest motion per
/// tile, and the gather itself (the pass's own material, which the renderer
/// draws like any other effect so that the frame's tone mapping still applies).
///
/// Everything happens on the engine's thread — the scene is applied there and
/// the frame is drawn there, one block at a time — so nothing here locks.
///
/// Free when off: nothing is allocated until a graph asks for the effect, and
/// the scene hooks return at once while none does.
class MotionBlur {
 public:
  explicit MotionBlur(filament::Engine &engine);
  ~MotionBlur();

  MotionBlur(const MotionBlur &) = delete;
  MotionBlur &operator=(const MotionBlur &) = delete;

  /// The compiled gather material, which the renderer builds the effect
  /// pass's own instance from. Here rather than there because a material's
  /// bytes are a symbol, and only one file may define it.
  static const uint8_t *gatherPackage();
  static size_t gatherPackageSize();

  /// Whether the current graph has a motion blur pass, and whether that pass
  /// blurs objects by their own motion. While nothing wants it, the scene
  /// hooks do nothing and whatever was remembered is forgotten.
  void setWanted(bool wanted, bool objects);
  bool wanted() const { return wanted_; }

  /// A scene is being applied. Called before the first `place`.
  void beginPublish();

  /// One object as this publish states it: the transform its host gave it,
  /// the entity that transform is written to, and the entities it draws with.
  void place(int64_t key, const filament::math::mat4f &transform,
             utils::Entity root, const utils::Entity *entities, size_t count);

  /// The moment the publish describes, on the application's own clock. This
  /// is what turns two transforms into a speed, so it is what commits them.
  void stamp(double at);

  /// A frame is about to be drawn and the camera has been placed for it.
  void frameBegan(const filament::Camera &camera);

  /// Runs the velocity, resolve and tile passes for one motion blur pass and
  /// dresses its gather material. Always leaves the gather able to draw: when
  /// there is nothing to blur, or no depth to rebuild the camera from, it is
  /// told to copy the picture through.
  ///
  /// `dials` are the pass's four numbers: the shutter in seconds (nought for
  /// the camera's own), the longest streak in pixels, whether objects blur by
  /// their own motion (negative for camera only), and how many taps the
  /// gather takes.
  void prepare(filament::Renderer &renderer, const filament::Camera &camera,
               filament::Texture *colour, filament::Texture *depth,
               uint32_t width, uint32_t height, const float dials[4],
               filament::MaterialInstance &gather);

  /// Gives everything back to the engine. Idempotent.
  void release();

 private:
  /// One object as it stood in the last two publishes.
  struct Record {
    filament::math::mat4f now;
    filament::math::mat4f was;
    filament::math::mat4f pending;
    utils::Entity root;
    std::vector<utils::Entity> entities;
    uint64_t seen = 0;
    bool fresh = true;
  };

  /// One full-screen triangle and the view that draws it into a target.
  struct Screen {
    filament::MaterialInstance *instance = nullptr;
    utils::Entity entity;
    filament::Scene *scene = nullptr;
    filament::View *view = nullptr;
    filament::Camera *camera = nullptr;
    utils::Entity cameraEntity;
  };

  /// A lent material instance, and what to give back afterwards.
  struct Lent {
    utils::Entity entity;
    size_t primitive;
    const filament::MaterialInstance *own;
  };

  void commit(double at, bool newMoment);
  bool build();
  void buildScreen(Screen &screen, filament::Material *material,
                   uint8_t channel);
  void releaseScreen(Screen &screen);
  void size(uint32_t width, uint32_t height, uint32_t tile);
  void releaseTargets();
  bool drawObjects(filament::Renderer &renderer, const filament::Camera &camera,
                   float shutter);

  filament::Engine &engine_;

  bool wanted_ = false;
  bool objects_ = false;

  // What the scene hooks remember.
  std::unordered_map<int64_t, Record> records_;
  uint64_t publish_ = 0;
  bool committed_ = true;
  double at_ = 0;
  double atWas_ = 0;
  bool haveAt_ = false;
  std::chrono::steady_clock::time_point arrived_;

  // What the frame hook remembers.
  filament::math::mat4 viewProjection_;
  filament::math::mat4 viewProjectionWas_;
  std::chrono::steady_clock::time_point frameAt_;
  double frameGap_ = 0;
  int frames_ = 0;

  // The passes, built on first use.
  bool built_ = false;
  filament::Material *velocity_ = nullptr;
  filament::Material *blank_ = nullptr;
  filament::Material *resolve_ = nullptr;
  filament::Material *tiles_ = nullptr;
  filament::VertexBuffer *corners_ = nullptr;
  filament::IndexBuffer *order_ = nullptr;

  Screen objectScreen_;  // the blank, under the moving objects
  Screen resolveScreen_;
  Screen tileScreen_;
  std::vector<filament::MaterialInstance *> lent_;
  std::vector<utils::Entity> drawnObjects_;

  // The targets, rebuilt when the picture or the tile changes size.
  filament::Texture *objectColour_ = nullptr;
  filament::Texture *objectDepth_ = nullptr;
  filament::RenderTarget *objectTarget_ = nullptr;
  filament::Texture *resolved_ = nullptr;
  filament::RenderTarget *resolvedTarget_ = nullptr;
  filament::Texture *tileMax_ = nullptr;
  filament::RenderTarget *tileTarget_ = nullptr;
  uint32_t width_ = 0;
  uint32_t height_ = 0;
  uint32_t tile_ = 0;
};

}  // namespace orbis
