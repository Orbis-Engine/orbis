// The selection outline: an edge drawn round the silhouettes of chosen
// objects, over the finished frame.
//
// Plain C++ against Filament's public API and nothing else — no Objective-C,
// no Apple frameworks — so it goes with the renderer to every platform it is
// ported to. The Objective-C++ renderer owns one of these, tells it which
// entities are highlighted, and asks it to draw after everything else.
#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

#include <utils/Entity.h>

namespace filament {
class Camera;
class Engine;
class IndexBuffer;
class Material;
class MaterialInstance;
class RenderTarget;
class Renderer;
class Scene;
class Texture;
class VertexBuffer;
class View;
}  // namespace filament

namespace orbis {

/// How many floats an outline's settings take on the wire. Agrees by hand
/// with OrbisOutline.stride in Dart and outlineStride in the plugin; the
/// native contract test reads all three.
constexpr size_t kOutlineParams = 14;

/// What becomes of the parts of a highlighted object something else hides.
///
/// Numbered as OrbisOccluded is in Dart.
enum class Occluded : int {
  /// Drawn exactly like the visible parts. Also the cheapest, because nothing
  /// has to know what is in front of what.
  shown = 0,
  /// Drawn, but fainter.
  faint = 1,
  /// Fainter, and broken into dashes.
  dashed = 2,
  /// Not drawn at all.
  hidden = 3,
};

/// Everything about how the outline looks, as the host last said it.
struct OutlineStyle {
  /// Display colours with straight alpha, nought to one: the active object's
  /// and everything else selected. Display rather than linear because the
  /// outline is drawn after tone mapping, so these land on screen as given.
  float primaryColour[4] = {1.0f, 0.667f, 0.251f, 1.0f};
  float colour[4] = {0.945f, 0.345f, 0.0f, 1.0f};

  /// In pixels of the frame.
  float width = 2.0f;

  Occluded occluded = Occluded::dashed;

  /// How much of a hidden edge survives, for the faint and dashed styles.
  float occludedOpacity = 0.4f;

  /// The length of one dash, in pixels.
  float dash = 6.0f;

  /// Reads the settings out of the wire's row of [kOutlineParams] floats,
  /// clamping anything that would ask a shader for the impossible.
  static OutlineStyle from(const float *params);

  bool operator==(const OutlineStyle &other) const;
  bool operator!=(const OutlineStyle &other) const { return !(*this == other); }
};

/// The widest outline drawn, in pixels. Both passes search a fixed distance
/// in the worst case, so this bounds what an outline can cost.
constexpr float kMostOutlineWidth = 16.0f;

/// Draws the outline.
///
/// Four renders when something is highlighted, and none when nothing is:
///
/// 1. the active object's depth, alone, into a target of its own;
/// 2. the rest of the selection's depth, likewise;
/// 3. the whole scene's depth, so the parts of a highlighted object that are
///    hidden can be told from the parts that are not — skipped when hidden
///    parts are drawn like visible ones, because then nobody needs to know;
/// 4. two screen passes: the distance to the nearest silhouette along each
///    row, then down each column, composited over the frame.
///
/// Silhouettes come from depth rather than from a mask colour because the
/// objects are drawn wearing their own materials: every entity in a glTF
/// keeps its geometry and skinning, and nothing has to be copied or swapped
/// for the outline to follow it. Whatever wrote depth there is the shape.
class Outline {
 public:
  explicit Outline(filament::Engine &engine);
  ~Outline();

  Outline(const Outline &) = delete;
  Outline &operator=(const Outline &) = delete;

  void setStyle(const OutlineStyle &style) { mStyle = style; }
  const OutlineStyle &style() const { return mStyle; }

  /// The renderables to outline — every entity of every highlighted object,
  /// the active one's apart. Cheap to call every frame with the same lists;
  /// the scenes are only rebuilt when they change.
  void setEntities(const std::vector<utils::Entity> &primary,
                   const std::vector<utils::Entity> &others);

  /// Whether there is anything to draw. False is the promise that a frame
  /// with nothing highlighted costs nothing.
  bool active() const { return !mPrimary.empty() || !mOthers.empty(); }

  /// Draws the outline over whatever the swap chain already holds.
  ///
  /// Call inside the frame, after everything else has been rendered into
  /// the swap chain. `world` and `camera` are the scene and camera the frame
  /// was drawn with; `layers` is which of the scene's layers count.
  void render(filament::Renderer &renderer, filament::Scene &world,
              filament::Camera &camera, uint32_t width, uint32_t height,
              uint8_t layers);

  /// What the last render did, for the renderer's own timing report: how many
  /// views it rendered.
  int lastRenders() const { return mLastRenders; }

 private:
  /// One depth-only image of some part of the scene.
  struct Mask {
    filament::Texture *depth = nullptr;
    filament::RenderTarget *target = nullptr;
    filament::View *view = nullptr;
  };

  /// One triangle over the screen and the material it wears.
  struct Screen {
    filament::View *view = nullptr;
    filament::Scene *scene = nullptr;
    utils::Entity entity;
    filament::MaterialInstance *instance = nullptr;
  };

  bool build();
  void buildScreen(Screen &screen, filament::Material *material);
  void prepareTargets(uint32_t width, uint32_t height);
  void releaseTargets();
  void releaseScreen(Screen &screen);
  static void fill(filament::Scene *scene,
                   const std::vector<utils::Entity> &entities);

  filament::Engine &mEngine;
  OutlineStyle mStyle;

  std::vector<utils::Entity> mPrimary;
  std::vector<utils::Entity> mOthers;

  bool mBuilt = false;
  filament::Material *mRowsMaterial = nullptr;
  filament::Material *mCompositeMaterial = nullptr;
  filament::VertexBuffer *mTriangle = nullptr;
  filament::IndexBuffer *mTriangleOrder = nullptr;

  /// The scenes the two selection masks are drawn from. The entities in them
  /// are the scene's own, shared rather than copied: Filament lets an entity
  /// belong to several scenes, and each view draws the one it is given.
  filament::Scene *mPrimaryScene = nullptr;
  filament::Scene *mOthersScene = nullptr;

  Mask mMasks[3];  // active, others, world
  filament::Texture *mRows = nullptr;
  filament::RenderTarget *mRowsTarget = nullptr;
  uint32_t mBuiltWidth = 0;
  uint32_t mBuiltHeight = 0;

  Screen mRowsPass;
  Screen mComposite;

  /// The camera the two screen passes draw through. Its projection does not
  /// matter — the triangle is already in clip space — but its exposure does.
  filament::Camera *mScreenCamera = nullptr;
  utils::Entity mScreenCameraEntity;

  int mLastRenders = 0;
};

}  // namespace orbis
