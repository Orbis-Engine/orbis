#include "orbis_scene.h"

namespace orbis_windows {
namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

// ---- Reading one field out of the message ------------------------------
//
// Every one of these answers "absent, or present as the wrong type" the same
// way: the empty value. That is deliberate and is what the other plugins
// do -- Swift's Scene.init, Kotlin's `as? FloatArray ?: FloatArray(0)` and
// the GTK one's borrowers -- because an optional part of a scene is far more
// often simply not there than it is malformed, and the ABI already reads
// (nullptr, 0) as "this part of the scene has nothing to say". What is *not*
// optional is checked once, by name, in Scene::From.

const EncodableValue* Lookup(const EncodableMap* map, const char* key) {
  if (map == nullptr) return nullptr;
  const auto found = map->find(EncodableValue(std::string(key)));
  return found == map->end() ? nullptr : &found->second;
}

// The typed lists, borrowed straight out of the codec's own vectors. The
// standard codec decodes a Dart Float32List to std::vector<float>, an
// Int32List to std::vector<int32_t> and so on, so each of these is one
// std::get_if against the variant rather than a type tag and an accessor.
template <typename T>
List<T> ReadList(const EncodableMap* map, const char* key) {
  const EncodableValue* value = Lookup(map, key);
  if (value == nullptr) return {};
  const auto* found = std::get_if<std::vector<T>>(value);
  if (found == nullptr || found->empty()) return {};
  return {found->data(), found->size()};
}

Floats ReadFloats(const EncodableMap* map, const char* key) {
  return ReadList<float>(map, key);
}

Ints ReadInts(const EncodableMap* map, const char* key) {
  return ReadList<int32_t>(map, key);
}

Longs ReadLongs(const EncodableMap* map, const char* key) {
  return ReadList<int64_t>(map, key);
}

Bytes ReadBytes(const EncodableMap* map, const char* key) {
  return ReadList<uint8_t>(map, key);
}

Strings ReadStrings(const EncodableMap* map, const char* key) {
  Strings out;
  const EncodableValue* value = Lookup(map, key);
  if (value == nullptr) return out;
  const auto* list = std::get_if<flutter::EncodableList>(value);
  if (list == nullptr) return out;
  out.owned.reserve(list->size());
  for (const EncodableValue& element : *list) {
    // An element that is not a string becomes an empty one rather than
    // shifting every index after it, which is what Kotlin's `it as? String
    // ?: ""` does and what keeps a mesh index pointing at the same entry.
    const auto* text = std::get_if<std::string>(&element);
    out.owned.emplace_back(text != nullptr ? *text : std::string());
  }
  out.pointers.reserve(out.owned.size());
  for (const std::string& one : out.owned) out.pointers.push_back(one.c_str());
  return out;
}

std::string ReadString(const EncodableMap* map, const char* key) {
  const EncodableValue* value = Lookup(map, key);
  if (value == nullptr) return {};
  const auto* text = std::get_if<std::string>(value);
  return text != nullptr ? *text : std::string();
}

bool ReadBool(const EncodableMap* map, const char* key) {
  const EncodableValue* value = Lookup(map, key);
  if (value == nullptr) return false;
  const auto* found = std::get_if<bool>(value);
  return found != nullptr && *found;
}

// A number, however Dart happened to send it. `fieldOfView: 45.0` arrives as
// a double and `viewHeight: 1` -- a whole number Dart stored in a double --
// can arrive as an int, and the standard codec picks the narrowest integer
// that fits, so a small one is an int32_t and a large one an int64_t.
// Reading only one of the three would silently take the default for the
// others. Kotlin's `as? Number)?.toDouble()` covers the same ground in one
// cast.
double ReadNumber(const EncodableMap* map, const char* key, double fallback) {
  const EncodableValue* value = Lookup(map, key);
  if (value == nullptr) return fallback;
  // `narrow` and `wide`, not `small` and `large`: <windows.h> reaches this
  // translation unit through orbis_viewport.h in the same target and drags in
  // rpcndr.h, which defines `small` as a macro for `char`.
  if (const auto* real = std::get_if<double>(value)) return *real;
  if (const auto* narrow = std::get_if<int32_t>(value)) {
    return static_cast<double>(*narrow);
  }
  if (const auto* wide = std::get_if<int64_t>(value)) {
    return static_cast<double>(*wide);
  }
  return fallback;
}

// The ints a scene may leave out, which default to something other than
// empty: one entry per row, filled with `fill`.
std::vector<int32_t> ReadIntsOr(const EncodableMap* map, const char* key,
                                size_t rows, int32_t fill) {
  const Ints found = ReadInts(map, key);
  if (found.count() > 0) {
    return std::vector<int32_t>(found.ptr(), found.ptr() + found.count());
  }
  return std::vector<int32_t>(rows, fill);
}

// Whether a required field is there and is the list the renderer will walk.
template <typename T>
bool Holds(const EncodableMap* map, const char* key) {
  const EncodableValue* value = Lookup(map, key);
  return value != nullptr && std::get_if<std::vector<T>>(value) != nullptr;
}

}  // namespace

std::unique_ptr<Scene> Scene::From(const flutter::EncodableValue* args) {
  if (args == nullptr) return nullptr;
  const auto* map = std::get_if<EncodableMap>(args);
  if (map == nullptr) return nullptr;

  // What every scene must carry, checked by type before anything is read.
  // The same seven Kotlin's `from` insists on.
  if (!Holds<int64_t>(map, "objectKeys") || !Holds<float>(map, "transforms") ||
      !Holds<float>(map, "colours") || !Holds<int32_t>(map, "meshes") ||
      !Holds<int32_t>(map, "objectFlags") ||
      !Holds<float>(map, "cameraPosition") ||
      !Holds<float>(map, "cameraTarget")) {
    return nullptr;
  }

  std::unique_ptr<Scene> scene(new Scene());

  scene->transforms_ = ReadFloats(map, "transforms");
  scene->count_ = static_cast<uint32_t>(scene->transforms_.count() / 16);
  const size_t count = scene->count_;

  scene->keys_ = ReadLongs(map, "objectKeys");
  scene->colours_ = ReadFloats(map, "colours");
  scene->meshes_ = ReadInts(map, "meshes");
  scene->flags_ = ReadInts(map, "objectFlags");
  scene->paths_ = ReadStrings(map, "meshPaths");
  scene->object_materials_ = ReadIntsOr(map, "objectMaterials", count, -1);
  scene->object_morph_counts_ = ReadIntsOr(map, "objectMorphCounts", count, 0);
  scene->object_morph_weights_ = ReadFloats(map, "objectMorphWeights");

  scene->camera_position_ = ReadFloats(map, "cameraPosition");
  scene->camera_target_ = ReadFloats(map, "cameraTarget");

  // The shapes the renderer walks without re-checking. A short array here is
  // a read past its end two layers down, which is the one failure this whole
  // class exists to turn into a channel error.
  if (scene->keys_.count() != count || scene->meshes_.count() != count ||
      scene->flags_.count() != count || scene->colours_.count() != count * 3 ||
      scene->camera_position_.count() != 3 ||
      scene->camera_target_.count() != 3) {
    return nullptr;
  }

  scene->material_keys_ = ReadLongs(map, "materialKeys");
  scene->material_flags_ = ReadInts(map, "materialFlags");
  scene->material_params_ = ReadFloats(map, "materialParams");
  scene->material_maps_ = ReadInts(map, "materialMaps");
  scene->texture_paths_ = ReadStrings(map, "texturePaths");
  scene->texture_srgb_ = ReadInts(map, "textureSrgb");
  scene->material_videos_ =
      ReadIntsOr(map, "materialVideos", scene->material_keys_.count(), -1);

  scene->video_keys_ = ReadLongs(map, "videoKeys");
  scene->video_flags_ = ReadInts(map, "videoFlags");
  scene->video_params_ = ReadFloats(map, "videoParams");
  scene->video_paths_ = ReadStrings(map, "videoPaths");

  scene->light_keys_ = ReadLongs(map, "lightKeys");
  scene->light_kinds_ = ReadInts(map, "lightKinds");
  scene->light_flags_ = ReadInts(map, "lightFlags");
  scene->light_params_ = ReadFloats(map, "lightParams");

  scene->probe_keys_ = ReadLongs(map, "probeKeys");
  scene->probe_params_ = ReadFloats(map, "probeParams");

  scene->field_params_ = ReadFloats(map, "fieldParams");
  scene->field_from_ = ReadString(map, "fieldFrom");

  scene->field_of_view_ =
      static_cast<float>(ReadNumber(map, "fieldOfView", 45.0));
  scene->aperture_ = static_cast<float>(ReadNumber(map, "aperture", 16.0));
  scene->shutter_speed_ =
      static_cast<float>(ReadNumber(map, "shutterSpeed", 1.0 / 125.0));
  scene->sensitivity_ =
      static_cast<float>(ReadNumber(map, "sensitivity", 100.0));
  scene->orthographic_ = ReadBool(map, "orthographic");
  scene->view_height_ = static_cast<float>(ReadNumber(map, "viewHeight", 1.0));
  scene->at_ = ReadNumber(map, "at", 0.0);

  scene->sky_colour_ = ReadFloats(map, "skyColour");
  scene->ambient_ = static_cast<float>(ReadNumber(map, "ambient", 0.0));
  scene->show_body_ = ReadBool(map, "showBody");

  scene->fog_enabled_ = ReadBool(map, "fogEnabled");
  scene->fog_params_ = ReadFloats(map, "fogParams");
  scene->precipitation_enabled_ = ReadBool(map, "precipitationEnabled");
  scene->precipitation_params_ = ReadFloats(map, "precipitationParams");
  scene->sky_enabled_ = ReadBool(map, "skyEnabled");
  scene->sky_params_ = ReadFloats(map, "skyParams");
  scene->batching_ = ReadBool(map, "batching");

  scene->post_params_ = ReadFloats(map, "postParams");
  scene->pipeline_params_ = ReadFloats(map, "pipelineParams");

  scene->environment_radiance_ = ReadString(map, "environmentRadiance");
  scene->environment_skybox_ = ReadString(map, "environmentSkybox");
  scene->environment_params_ = ReadFloats(map, "environmentParams");

  scene->graph_passes_ = ReadFloats(map, "graphPasses");
  scene->graph_targets_ = ReadFloats(map, "graphTargets");
  scene->graph_target_names_ = ReadStrings(map, "graphTargetNames");

  scene->outline_keys_ = ReadLongs(map, "outlineKeys");
  scene->outline_params_ = ReadFloats(map, "outlineParams");
  scene->god_ray_params_ = ReadFloats(map, "godRayParams");
  scene->distortion_params_ = ReadFloats(map, "distortionParams");

  scene->population_keys_ = ReadInts(map, "populationKeys");
  scene->population_counts_ = ReadInts(map, "populationCounts");
  scene->population_meshes_ = ReadInts(map, "populationMeshes");
  scene->population_flags_ = ReadInts(map, "populationFlags");
  scene->population_revisions_ = ReadInts(map, "populationRevisions");
  scene->population_ranges_ = ReadFloats(map, "populationRanges");
  scene->population_bounds_ = ReadFloats(map, "populationBounds");
  scene->population_paths_ = ReadStrings(map, "populationPaths");
  scene->population_changed_ = ReadInts(map, "populationChanged");
  scene->population_transforms_ = ReadFloats(map, "populationTransforms");
  scene->population_colours_ = ReadFloats(map, "populationColours");

  scene->decal_params_ = ReadFloats(map, "decalParams");
  scene->decal_images_ = ReadInts(map, "decalImages");
  scene->decal_paths_ = ReadStrings(map, "decalPaths");

  scene->splat_keys_ = ReadInts(map, "splatKeys");
  scene->splat_flags_ = ReadInts(map, "splatFlags");
  scene->splat_revisions_ = ReadInts(map, "splatRevisions");
  scene->splat_params_ = ReadFloats(map, "splatParams");
  scene->splat_paths_ = ReadStrings(map, "splatPaths");
  scene->splat_changed_ = ReadInts(map, "splatChanged");
  scene->splat_changed_counts_ = ReadInts(map, "splatChangedCounts");
  scene->splat_data_ = ReadBytes(map, "splatData");

  return scene;
}

void Scene::ApplyTo(orbis_renderer* renderer) const {
  orbis_renderer_set_environment(renderer, environment_radiance_.c_str(),
                                 environment_skybox_.c_str(),
                                 environment_params_.ptr(),
                                 environment_params_.count());

  // Strides are the ABI's own, so the counts are derived here rather than
  // sent -- the same arithmetic orbis_jni.cpp does, for the same reason.
  const uint32_t pass_stride = orbis_renderer_stride(ORBIS_STRIDE_PASS);
  const uint32_t target_stride = orbis_renderer_stride(ORBIS_STRIDE_TARGET);
  const uint32_t pass_count =
      pass_stride > 0 ? graph_passes_.count32() / pass_stride : 0;
  const uint32_t target_count =
      target_stride > 0 ? graph_targets_.count32() / target_stride : 0;
  orbis_renderer_set_render_graph(
      renderer, pass_count, graph_passes_.ptr(), graph_passes_.count(),
      target_count, graph_targets_.ptr(), graph_targets_.count(),
      graph_target_names_.ptr(), graph_target_names_.count());

  orbis_renderer_set_batching(renderer, batching_ ? 1 : 0);
  orbis_renderer_set_god_rays(renderer, god_ray_params_.ptr(),
                              god_ray_params_.count(), distortion_params_.ptr(),
                              distortion_params_.count());

  orbis_renderer_apply_videos(renderer, video_keys_.count32(),
                              video_keys_.ptr(), video_flags_.ptr(),
                              video_params_.ptr(), video_params_.count(),
                              video_paths_.ptr(), video_paths_.count());

  orbis_renderer_apply_materials(
      renderer, material_keys_.count32(), material_keys_.ptr(),
      material_flags_.ptr(), material_params_.ptr(), material_params_.count(),
      material_maps_.ptr(), material_maps_.count(), texture_paths_.ptr(),
      texture_srgb_.ptr(), texture_paths_.count(), material_videos_.data());

  orbis_renderer_apply_objects(
      renderer, count_, keys_.ptr(), transforms_.ptr(), transforms_.count(),
      colours_.ptr(), colours_.count(), meshes_.ptr(), flags_.ptr(),
      object_materials_.data(), object_morph_counts_.data(),
      object_morph_weights_.ptr(), object_morph_weights_.count(), paths_.ptr(),
      paths_.count());

  if (population_keys_.count() > 0) {
    orbis_renderer_apply_populations(
        renderer, population_keys_.count32(), population_keys_.ptr(),
        population_counts_.ptr(), population_meshes_.ptr(),
        population_flags_.ptr(), population_revisions_.ptr(),
        population_ranges_.ptr(), population_bounds_.ptr(),
        population_bounds_.count(), population_paths_.ptr(),
        population_paths_.count(), population_changed_.ptr(),
        population_changed_.count32(), population_transforms_.ptr(),
        population_transforms_.count(), population_colours_.ptr(),
        population_colours_.count());
  }

  orbis_renderer_apply_splats(
      renderer, splat_keys_.count32(), splat_keys_.ptr(), splat_flags_.ptr(),
      splat_revisions_.ptr(), splat_params_.ptr(), splat_params_.count(),
      splat_paths_.ptr(), splat_paths_.count(), splat_changed_.ptr(),
      splat_changed_counts_.ptr(), splat_changed_.count32(),
      splat_data_.ptr(), splat_data_.count());

  orbis_renderer_apply_lights(renderer, light_keys_.count32(),
                              light_keys_.ptr(), light_kinds_.ptr(),
                              light_flags_.ptr(), light_params_.ptr(),
                              light_params_.count());

  // Decals are counted by their images, as the JNI bridge counts them: one
  // image index per decal, whether or not it names a picture.
  orbis_renderer_apply_decals(renderer, decal_images_.count32(),
                              decal_params_.ptr(), decal_params_.count(),
                              decal_images_.ptr(), decal_paths_.ptr(),
                              decal_paths_.count());

  orbis_renderer_apply_probes(renderer, probe_keys_.count32(),
                              probe_keys_.ptr(), probe_params_.ptr(),
                              probe_params_.count());

  if (field_params_.count() > 0) {
    orbis_renderer_apply_field(renderer, field_params_.ptr(),
                               field_params_.count(), field_from_.c_str());
  }

  if (sky_colour_.count() >= 3) {
    orbis_renderer_set_sky_colour(renderer, sky_colour_.ptr(), ambient_,
                                  show_body_ ? 1 : 0);
  }
  orbis_renderer_set_fog(renderer, fog_enabled_ ? 1 : 0, fog_params_.ptr(),
                         fog_params_.count());
  if (post_params_.count() > 0) {
    orbis_renderer_set_post_process(renderer, post_params_.ptr(),
                                    post_params_.count());
  }
  if (pipeline_params_.count() > 0) {
    orbis_renderer_set_pipeline(renderer, pipeline_params_.ptr(),
                                pipeline_params_.count());
  }
  orbis_renderer_set_precipitation(renderer, precipitation_enabled_ ? 1 : 0,
                                   precipitation_params_.ptr(),
                                   precipitation_params_.count());
  orbis_renderer_set_sky(renderer, sky_enabled_ ? 1 : 0, sky_params_.ptr(),
                         sky_params_.count());

  orbis_renderer_set_camera(renderer, camera_position_.ptr(),
                            camera_target_.ptr(), field_of_view_,
                            orthographic_ ? 1 : 0, view_height_, at_);
  orbis_renderer_set_exposure(renderer, aperture_, shutter_speed_,
                              sensitivity_);

  orbis_renderer_set_outline(renderer, outline_keys_.ptr(),
                             outline_keys_.count32(), outline_params_.ptr(),
                             outline_params_.count());
}

}  // namespace orbis_windows
