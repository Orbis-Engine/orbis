#include "orbis_scene.h"

#include <cstring>

namespace orbis_linux {
namespace {

// ---- Reading one field out of the message ------------------------------
//
// Every one of these answers "absent, or present as the wrong type" the same
// way: the empty value. That is deliberate and is what the other two plugins
// do -- Swift's Scene.init and Kotlin's `as? FloatArray ?: FloatArray(0)` --
// because an optional part of a scene is far more often simply not there
// than it is malformed, and the ABI already reads (nullptr, 0) as "this part
// of the scene has nothing to say". What is *not* optional is checked once,
// by name, in Scene::From.

FlValue* Lookup(FlValue* map, const char* key) {
  if (map == nullptr) return nullptr;
  return fl_value_lookup_string(map, key);
}

bool Holds(FlValue* value, FlValueType type) {
  return value != nullptr && fl_value_get_type(value) == type;
}

Floats ReadFloats(FlValue* map, const char* key) {
  FlValue* value = Lookup(map, key);
  if (!Holds(value, FL_VALUE_TYPE_FLOAT32_LIST)) return {};
  return {fl_value_get_float32_list(value), fl_value_get_length(value)};
}

Ints ReadInts(FlValue* map, const char* key) {
  FlValue* value = Lookup(map, key);
  if (!Holds(value, FL_VALUE_TYPE_INT32_LIST)) return {};
  return {fl_value_get_int32_list(value), fl_value_get_length(value)};
}

Longs ReadLongs(FlValue* map, const char* key) {
  FlValue* value = Lookup(map, key);
  if (!Holds(value, FL_VALUE_TYPE_INT64_LIST)) return {};
  return {fl_value_get_int64_list(value), fl_value_get_length(value)};
}

Bytes ReadBytes(FlValue* map, const char* key) {
  FlValue* value = Lookup(map, key);
  if (!Holds(value, FL_VALUE_TYPE_UINT8_LIST)) return {};
  return {fl_value_get_uint8_list(value), fl_value_get_length(value)};
}

Strings ReadStrings(FlValue* map, const char* key) {
  Strings out;
  FlValue* value = Lookup(map, key);
  if (!Holds(value, FL_VALUE_TYPE_LIST)) return out;
  const size_t length = fl_value_get_length(value);
  out.owned.reserve(length);
  for (size_t i = 0; i < length; i++) {
    FlValue* element = fl_value_get_list_value(value, i);
    // An element that is not a string becomes an empty one rather than
    // shifting every index after it, which is what Kotlin's `it as? String
    // ?: ""` does and what keeps a mesh index pointing at the same entry.
    out.owned.emplace_back(Holds(element, FL_VALUE_TYPE_STRING)
                               ? fl_value_get_string(element)
                               : "");
  }
  out.pointers.reserve(out.owned.size());
  for (const std::string& one : out.owned) out.pointers.push_back(one.c_str());
  return out;
}

std::string ReadString(FlValue* map, const char* key) {
  FlValue* value = Lookup(map, key);
  if (!Holds(value, FL_VALUE_TYPE_STRING)) return {};
  return fl_value_get_string(value);
}

bool ReadBool(FlValue* map, const char* key) {
  FlValue* value = Lookup(map, key);
  return Holds(value, FL_VALUE_TYPE_BOOL) && fl_value_get_bool(value);
}

// A number, however Dart happened to send it. `fieldOfView: 45.0` arrives as
// a float and `viewHeight: 1` -- a whole number Dart stored in a double --
// can arrive as an int, so reading only one of the two would silently take
// the default for the other. Kotlin's `as? Number)?.toDouble()` covers the
// same ground in one cast.
double ReadNumber(FlValue* map, const char* key, double fallback) {
  FlValue* value = Lookup(map, key);
  if (Holds(value, FL_VALUE_TYPE_FLOAT)) return fl_value_get_float(value);
  if (Holds(value, FL_VALUE_TYPE_INT)) {
    return static_cast<double>(fl_value_get_int(value));
  }
  return fallback;
}

// The ints a scene may leave out, which default to something other than
// empty: one entry per row, filled with `fill`.
std::vector<int32_t> ReadIntsOr(FlValue* map, const char* key, size_t rows,
                                int32_t fill) {
  const Ints found = ReadInts(map, key);
  if (found.count() > 0) {
    return std::vector<int32_t>(found.ptr(), found.ptr() + found.count());
  }
  return std::vector<int32_t>(rows, fill);
}

}  // namespace

std::unique_ptr<Scene> Scene::From(FlValue* args) {
  if (!Holds(args, FL_VALUE_TYPE_MAP)) return nullptr;

  // What every scene must carry, checked by type before anything is read.
  // The same seven Kotlin's `from` insists on.
  if (!Holds(Lookup(args, "objectKeys"), FL_VALUE_TYPE_INT64_LIST) ||
      !Holds(Lookup(args, "transforms"), FL_VALUE_TYPE_FLOAT32_LIST) ||
      !Holds(Lookup(args, "colours"), FL_VALUE_TYPE_FLOAT32_LIST) ||
      !Holds(Lookup(args, "meshes"), FL_VALUE_TYPE_INT32_LIST) ||
      !Holds(Lookup(args, "objectFlags"), FL_VALUE_TYPE_INT32_LIST) ||
      !Holds(Lookup(args, "cameraPosition"), FL_VALUE_TYPE_FLOAT32_LIST) ||
      !Holds(Lookup(args, "cameraTarget"), FL_VALUE_TYPE_FLOAT32_LIST)) {
    return nullptr;
  }

  std::unique_ptr<Scene> scene(new Scene());

  scene->transforms_ = ReadFloats(args, "transforms");
  scene->count_ = static_cast<uint32_t>(scene->transforms_.count() / 16);
  const size_t count = scene->count_;

  scene->keys_ = ReadLongs(args, "objectKeys");
  scene->colours_ = ReadFloats(args, "colours");
  scene->meshes_ = ReadInts(args, "meshes");
  scene->flags_ = ReadInts(args, "objectFlags");
  scene->paths_ = ReadStrings(args, "meshPaths");
  scene->object_materials_ = ReadIntsOr(args, "objectMaterials", count, -1);
  scene->object_morph_counts_ = ReadIntsOr(args, "objectMorphCounts", count, 0);
  scene->object_morph_weights_ = ReadFloats(args, "objectMorphWeights");

  scene->camera_position_ = ReadFloats(args, "cameraPosition");
  scene->camera_target_ = ReadFloats(args, "cameraTarget");

  // The shapes the renderer walks without re-checking. A short array here is
  // a read past its end two layers down, which is the one failure this whole
  // class exists to turn into a channel error.
  if (scene->keys_.count() != count || scene->meshes_.count() != count ||
      scene->flags_.count() != count || scene->colours_.count() != count * 3 ||
      scene->camera_position_.count() != 3 ||
      scene->camera_target_.count() != 3) {
    return nullptr;
  }

  scene->material_keys_ = ReadLongs(args, "materialKeys");
  scene->material_flags_ = ReadInts(args, "materialFlags");
  scene->material_params_ = ReadFloats(args, "materialParams");
  scene->material_maps_ = ReadInts(args, "materialMaps");
  scene->texture_paths_ = ReadStrings(args, "texturePaths");
  scene->texture_srgb_ = ReadInts(args, "textureSrgb");
  scene->material_videos_ = ReadIntsOr(args, "materialVideos",
                                       scene->material_keys_.count(), -1);

  scene->video_keys_ = ReadLongs(args, "videoKeys");
  scene->video_flags_ = ReadInts(args, "videoFlags");
  scene->video_params_ = ReadFloats(args, "videoParams");
  scene->video_paths_ = ReadStrings(args, "videoPaths");

  scene->light_keys_ = ReadLongs(args, "lightKeys");
  scene->light_kinds_ = ReadInts(args, "lightKinds");
  scene->light_flags_ = ReadInts(args, "lightFlags");
  scene->light_params_ = ReadFloats(args, "lightParams");

  scene->probe_keys_ = ReadLongs(args, "probeKeys");
  scene->probe_params_ = ReadFloats(args, "probeParams");

  scene->field_params_ = ReadFloats(args, "fieldParams");
  scene->field_from_ = ReadString(args, "fieldFrom");

  scene->field_of_view_ = static_cast<float>(ReadNumber(args, "fieldOfView", 45.0));
  scene->aperture_ = static_cast<float>(ReadNumber(args, "aperture", 16.0));
  scene->shutter_speed_ =
      static_cast<float>(ReadNumber(args, "shutterSpeed", 1.0 / 125.0));
  scene->sensitivity_ = static_cast<float>(ReadNumber(args, "sensitivity", 100.0));
  scene->orthographic_ = ReadBool(args, "orthographic");
  scene->view_height_ = static_cast<float>(ReadNumber(args, "viewHeight", 1.0));
  scene->at_ = ReadNumber(args, "at", 0.0);

  scene->sky_colour_ = ReadFloats(args, "skyColour");
  scene->ambient_ = static_cast<float>(ReadNumber(args, "ambient", 0.0));
  scene->show_body_ = ReadBool(args, "showBody");

  scene->fog_enabled_ = ReadBool(args, "fogEnabled");
  scene->fog_params_ = ReadFloats(args, "fogParams");
  scene->precipitation_enabled_ = ReadBool(args, "precipitationEnabled");
  scene->precipitation_params_ = ReadFloats(args, "precipitationParams");
  scene->sky_enabled_ = ReadBool(args, "skyEnabled");
  scene->sky_params_ = ReadFloats(args, "skyParams");
  scene->batching_ = ReadBool(args, "batching");

  scene->post_params_ = ReadFloats(args, "postParams");
  scene->pipeline_params_ = ReadFloats(args, "pipelineParams");

  scene->environment_radiance_ = ReadString(args, "environmentRadiance");
  scene->environment_skybox_ = ReadString(args, "environmentSkybox");
  scene->environment_params_ = ReadFloats(args, "environmentParams");

  scene->graph_passes_ = ReadFloats(args, "graphPasses");
  scene->graph_targets_ = ReadFloats(args, "graphTargets");
  scene->graph_target_names_ = ReadStrings(args, "graphTargetNames");

  scene->outline_keys_ = ReadLongs(args, "outlineKeys");
  scene->outline_params_ = ReadFloats(args, "outlineParams");
  scene->god_ray_params_ = ReadFloats(args, "godRayParams");
  scene->distortion_params_ = ReadFloats(args, "distortionParams");

  scene->population_keys_ = ReadInts(args, "populationKeys");
  scene->population_counts_ = ReadInts(args, "populationCounts");
  scene->population_meshes_ = ReadInts(args, "populationMeshes");
  scene->population_flags_ = ReadInts(args, "populationFlags");
  scene->population_revisions_ = ReadInts(args, "populationRevisions");
  scene->population_ranges_ = ReadFloats(args, "populationRanges");
  scene->population_bounds_ = ReadFloats(args, "populationBounds");
  scene->population_paths_ = ReadStrings(args, "populationPaths");
  scene->population_changed_ = ReadInts(args, "populationChanged");
  scene->population_transforms_ = ReadFloats(args, "populationTransforms");
  scene->population_colours_ = ReadFloats(args, "populationColours");

  scene->decal_params_ = ReadFloats(args, "decalParams");
  scene->decal_images_ = ReadInts(args, "decalImages");
  scene->decal_paths_ = ReadStrings(args, "decalPaths");

  scene->splat_keys_ = ReadInts(args, "splatKeys");
  scene->splat_flags_ = ReadInts(args, "splatFlags");
  scene->splat_revisions_ = ReadInts(args, "splatRevisions");
  scene->splat_params_ = ReadFloats(args, "splatParams");
  scene->splat_paths_ = ReadStrings(args, "splatPaths");
  scene->splat_changed_ = ReadInts(args, "splatChanged");
  scene->splat_changed_counts_ = ReadInts(args, "splatChangedCounts");
  scene->splat_data_ = ReadBytes(args, "splatData");

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

}  // namespace orbis_linux
