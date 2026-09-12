#pragma once

// A scene as it arrives over the `orbis_filament` channel's `setScene` call,
// parsed once so a malformed message is a channel error with something to
// read rather than an out-of-bounds read inside the renderer.
//
// The Windows counterpart to ../linux/orbis_scene.h and
// ../android/.../OrbisScene.kt, which mirror OrbisFilamentPlugin.swift's
// private `Scene` struct -- same fields, same order, same optionality, so a
// change made to one is easy to find in the others. Like theirs, this checks
// that the arrays a call reads are the *shape* the renderer needs (present
// when required, parallel arrays the same length) and trusts the indices
// inside them, because the one place these numbers come from is Dart's own
// OrbisScene.toMessage().
//
// What differs from the GTK one is only how a field is borrowed. Flutter's
// Windows embedder decodes the standard codec into an `EncodableValue` -- a
// std::variant -- so a Float32List arrives already as a `std::vector<float>`
// and is reached with std::get_if rather than through FlValue's accessors.
// That makes the borrowing simpler than Linux's, not harder: each reader
// below answers "absent, or the wrong type" with an empty array, which is
// exactly what the ABI's "a null pointer and a count of nought" means for an
// optional field.

#include <flutter/encodable_value.h>

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "orbis_renderer.h"

namespace orbis_windows {

// A borrowed typed list: the codec's own storage, which outlives this object
// because the EncodableValue passed to a method-call handler is alive for the
// whole of that call and the scene is applied inside it. Empty is
// (nullptr, 0), which is what every optional ABI array takes for "nothing to
// say".
template <typename T>
struct List {
  const T* data = nullptr;
  size_t length = 0;

  const T* ptr() const { return data; }
  size_t count() const { return length; }
  uint32_t count32() const { return static_cast<uint32_t>(length); }
};

using Floats = List<float>;
using Ints = List<int32_t>;
using Longs = List<int64_t>;
using Bytes = List<uint8_t>;

// A list of strings, kept two ways: the copies that own the characters, and
// the `const char* const*` the ABI reads. Both are needed -- the ABI wants
// the pointer array, and something has to keep the strings alive under it.
struct Strings {
  std::vector<std::string> owned;
  std::vector<const char*> pointers;

  const char* const* ptr() const {
    return pointers.empty() ? nullptr : pointers.data();
  }
  uint32_t count() const { return static_cast<uint32_t>(owned.size()); }
};

class Scene {
 public:
  // Null for a message missing what every scene must carry: the object
  // arrays and a camera, or object arrays that disagree on length -- which
  // the ABI would otherwise read as a short array past its end. Everything
  // else is optional in the way Swift's, Kotlin's and the GTK one's treat it:
  // absent decodes to "this part of the scene has nothing to say".
  static std::unique_ptr<Scene> From(const flutter::EncodableValue* args);

  // Applies every part of the scene, in the order Viewport.write(scene:)
  // does on the Swift side and OrbisScene.applyTo does on the Kotlin one.
  void ApplyTo(orbis_renderer* renderer) const;

 private:
  Scene() = default;

  uint32_t count_ = 0;

  Longs keys_;
  Floats transforms_;
  Floats colours_;
  Ints meshes_;
  Ints flags_;
  Strings paths_;
  // Owned rather than borrowed, because Dart may leave them out and the
  // default is not "empty" but "one -1 per object" -- the same defaults
  // OrbisScene.kt fills in.
  std::vector<int32_t> object_materials_;
  std::vector<int32_t> object_morph_counts_;
  Floats object_morph_weights_;

  Longs material_keys_;
  Ints material_flags_;
  Floats material_params_;
  Ints material_maps_;
  Strings texture_paths_;
  Ints texture_srgb_;
  std::vector<int32_t> material_videos_;

  Longs video_keys_;
  Ints video_flags_;
  Floats video_params_;
  Strings video_paths_;

  Longs light_keys_;
  Ints light_kinds_;
  Ints light_flags_;
  Floats light_params_;

  Longs probe_keys_;
  Floats probe_params_;

  Floats field_params_;
  std::string field_from_;

  Floats camera_position_;
  Floats camera_target_;
  float field_of_view_ = 45.0f;
  float aperture_ = 16.0f;
  float shutter_speed_ = 1.0f / 125.0f;
  float sensitivity_ = 100.0f;
  bool orthographic_ = false;
  float view_height_ = 1.0f;
  double at_ = 0.0;

  Floats sky_colour_;
  float ambient_ = 0.0f;
  bool show_body_ = false;

  bool fog_enabled_ = false;
  Floats fog_params_;
  bool precipitation_enabled_ = false;
  Floats precipitation_params_;
  bool sky_enabled_ = false;
  Floats sky_params_;
  bool batching_ = false;

  Floats post_params_;
  Floats pipeline_params_;

  std::string environment_radiance_;
  std::string environment_skybox_;
  Floats environment_params_;

  Floats graph_passes_;
  Floats graph_targets_;
  Strings graph_target_names_;

  Longs outline_keys_;
  Floats outline_params_;
  Floats god_ray_params_;
  Floats distortion_params_;

  Ints population_keys_;
  Ints population_counts_;
  Ints population_meshes_;
  Ints population_flags_;
  Ints population_revisions_;
  Floats population_ranges_;
  Floats population_bounds_;
  Strings population_paths_;
  Ints population_changed_;
  Floats population_transforms_;
  Floats population_colours_;

  Floats decal_params_;
  Ints decal_images_;
  Strings decal_paths_;

  Ints splat_keys_;
  Ints splat_flags_;
  Ints splat_revisions_;
  Floats splat_params_;
  Strings splat_paths_;
  Ints splat_changed_;
  Ints splat_changed_counts_;
  Bytes splat_data_;
};

}  // namespace orbis_windows
