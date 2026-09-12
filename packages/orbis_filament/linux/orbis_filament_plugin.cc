#include "include/orbis_filament/orbis_filament_plugin.h"

#include <map>
#include <memory>

#include "orbis_scene.h"
#include "orbis_viewport.h"

// Linux's `orbis_filament` plugin: the same channel, the same methods, the
// same wire shapes as OrbisFilamentPlugin.swift and OrbisFilamentPlugin.kt,
// so lib/src/orbis_view.dart and every other Dart caller work unchanged. One
// Viewport per `create`d texture, keyed by the id Flutter's texture registrar
// gave it -- `viewports` here is exactly `viewports` on the Kotlin side and
// `Viewport`'s dictionary on the Swift one.

// The plugin's own GObject. Declared here rather than in the public header
// because nothing outside this file names the type: the registrant Flutter
// generates calls one function, and that is the whole of what
// include/orbis_filament/orbis_filament_plugin.h has to offer.
G_DECLARE_FINAL_TYPE(OrbisFilamentPlugin,
                     orbis_filament_plugin,
                     ORBIS,
                     FILAMENT_PLUGIN,
                     GObject)

struct _OrbisFilamentPlugin {
  GObject parent_instance;
  FlMethodChannel* channel;
  FlTextureRegistrar* texture_registrar;  // borrowed from the registrar
  std::map<int64_t, std::unique_ptr<orbis_linux::Viewport>>* viewports;
};

G_DEFINE_TYPE(OrbisFilamentPlugin, orbis_filament_plugin, g_object_get_type())

namespace {

// The arguments of every method here are a map; these read one field out of
// it the way the Kotlin plugin's `as? Number)?.toInt()` does, answering
// "absent or the wrong type" rather than crashing on a hand-built message.
bool ReadInt(FlValue* args, const char* key, int64_t* out) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return false;
  }
  FlValue* value = fl_value_lookup_string(args, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_INT) {
    return false;
  }
  *out = fl_value_get_int(value);
  return true;
}

orbis_linux::Viewport* Find(OrbisFilamentPlugin* self, int64_t texture_id) {
  auto found = self->viewports->find(texture_id);
  return found == self->viewports->end() ? nullptr : found->second.get();
}

FlMethodResponse* Create(OrbisFilamentPlugin* self, FlValue* args) {
  int64_t width = 0;
  int64_t height = 0;
  if (!ReadInt(args, "width", &width) || !ReadInt(args, "height", &height) ||
      width <= 0 || height <= 0) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "bad-args", "create needs a positive width and height", nullptr));
  }
  if (self->texture_registrar == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "no-registry", "No FlTextureRegistrar", nullptr));
  }

  std::unique_ptr<orbis_linux::Viewport> viewport =
      orbis_linux::Viewport::Start(self->texture_registrar, uint32_t(width),
                                   uint32_t(height));
  if (viewport == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "no-renderer",
        "Filament could not start. No backend (Vulkan, then OpenGL) was "
        "available.",
        nullptr));
  }

  const int64_t texture_id = viewport->texture_id();
  (*self->viewports)[texture_id] = std::move(viewport);
  g_autoptr(FlValue) result = fl_value_new_int(texture_id);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

FlMethodResponse* Resize(OrbisFilamentPlugin* self, FlValue* args) {
  int64_t texture_id = 0;
  int64_t width = 0;
  int64_t height = 0;
  if (!ReadInt(args, "textureId", &texture_id) ||
      !ReadInt(args, "width", &width) || !ReadInt(args, "height", &height)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "bad-args", "resize needs textureId, width, height", nullptr));
  }
  orbis_linux::Viewport* viewport = Find(self, texture_id);
  if (viewport != nullptr) {
    viewport->Resize(uint32_t(width), uint32_t(height));
  }
  g_autoptr(FlValue) result = fl_value_new_null();
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

FlMethodResponse* SetScene(OrbisFilamentPlugin* self, FlValue* args) {
  int64_t texture_id = 0;
  if (!ReadInt(args, "textureId", &texture_id)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "bad-args", "setScene needs a textureId", nullptr));
  }
  std::unique_ptr<orbis_linux::Scene> scene = orbis_linux::Scene::From(args);
  if (scene == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "bad-scene",
        "setScene needs keys, float32 transforms (16 each), colours (3 "
        "each), flags, lights (16 floats each), fog (10 floats) and a "
        "camera.",
        nullptr));
  }

  orbis_linux::Viewport* viewport = Find(self, texture_id);
  if (viewport == nullptr) {
    g_autoptr(FlValue) nothing = fl_value_new_null();
    return FL_METHOD_RESPONSE(fl_method_success_response_new(nothing));
  }
  viewport->ApplyScene(*scene);

  // Answered once the scene is actually in, as both other plugins do.
  g_autoptr(FlValue) notes = fl_value_new_map();
  for (const auto& note : viewport->Notes()) {
    fl_value_set_string_take(notes, note.first.c_str(),
                             fl_value_new_string(note.second.c_str()));
  }
  return FL_METHOD_RESPONSE(fl_method_success_response_new(notes));
}

FlMethodResponse* Stats(OrbisFilamentPlugin* self, FlValue* args) {
  int64_t texture_id = 0;
  orbis_linux::Viewport* viewport =
      ReadInt(args, "textureId", &texture_id) ? Find(self, texture_id)
                                              : nullptr;
  if (viewport == nullptr) {
    g_autoptr(FlValue) nothing = fl_value_new_null();
    return FL_METHOD_RESPONSE(fl_method_success_response_new(nothing));
  }

  g_autoptr(FlValue) stats = fl_value_new_map();
  fl_value_set_string_take(stats, "gpuMilliseconds",
                           fl_value_new_float(viewport->GpuMilliseconds()));
  const std::vector<double> timings = viewport->PassTimings();
  fl_value_set_string_take(
      stats, "passTimings",
      fl_value_new_float_list(timings.data(), timings.size()));
  const std::vector<int32_t> batching = viewport->Batching();
  fl_value_set_string_take(
      stats, "batching",
      fl_value_new_int32_list(batching.data(), batching.size()));
  return FL_METHOD_RESPONSE(fl_method_success_response_new(stats));
}

FlMethodResponse* Dispose(OrbisFilamentPlugin* self, FlValue* args) {
  int64_t texture_id = 0;
  if (!ReadInt(args, "textureId", &texture_id)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "bad-args", "dispose needs textureId", nullptr));
  }
  self->viewports->erase(texture_id);
  g_autoptr(FlValue) result = fl_value_new_null();
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

void MethodCall(FlMethodChannel* channel, FlMethodCall* method_call,
                gpointer user_data) {
  auto* self = ORBIS_FILAMENT_PLUGIN(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(method, "create") == 0) {
    response = Create(self, args);
  } else if (g_strcmp0(method, "resize") == 0) {
    response = Resize(self, args);
  } else if (g_strcmp0(method, "setScene") == 0) {
    response = SetScene(self, args);
  } else if (g_strcmp0(method, "stats") == 0) {
    response = Stats(self, args);
  } else if (g_strcmp0(method, "dispose") == 0) {
    response = Dispose(self, args);
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("orbis_filament: failed to respond to %s: %s", method,
              error->message);
  }
}

}  // namespace

static void orbis_filament_plugin_dispose(GObject* object) {
  auto* self = ORBIS_FILAMENT_PLUGIN(object);
  // The viewports first: each stops its frame loop and unregisters its
  // texture, which must happen while the registrar is still alive.
  if (self->viewports != nullptr) {
    delete self->viewports;
    self->viewports = nullptr;
  }
  g_clear_object(&self->channel);
  self->texture_registrar = nullptr;
  G_OBJECT_CLASS(orbis_filament_plugin_parent_class)->dispose(object);
}

static void orbis_filament_plugin_class_init(OrbisFilamentPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = orbis_filament_plugin_dispose;
}

static void orbis_filament_plugin_init(OrbisFilamentPlugin* self) {
  self->viewports =
      new std::map<int64_t, std::unique_ptr<orbis_linux::Viewport>>();
}

void orbis_filament_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  auto* plugin = ORBIS_FILAMENT_PLUGIN(
      g_object_new(orbis_filament_plugin_get_type(), nullptr));

  plugin->texture_registrar = fl_plugin_registrar_get_texture_registrar(registrar);

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  plugin->channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), "orbis_filament",
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      plugin->channel, MethodCall, g_object_ref(plugin), g_object_unref);

  g_object_unref(plugin);
}
