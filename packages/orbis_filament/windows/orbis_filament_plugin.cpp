#include "include/orbis_filament/orbis_filament_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <map>
#include <memory>

#include "orbis_scene.h"
#include "orbis_viewport.h"

// Windows's `orbis_filament` plugin: the same channel, the same methods, the
// same wire shapes as OrbisFilamentPlugin.swift, OrbisFilamentPlugin.kt and
// ../linux/orbis_filament_plugin.cc, so lib/src/orbis_view.dart and every
// other Dart caller work unchanged. One Viewport per `create`d texture, keyed
// by the id Flutter's texture registrar gave it -- `viewports_` here is
// exactly `viewports` on the Kotlin and GTK sides and `Viewport`'s dictionary
// on the Swift one.

namespace orbis_windows {
namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using MethodResultValue = flutter::MethodResult<EncodableValue>;

// The arguments of every method here are a map; this reads one field out of
// it the way the Kotlin plugin's `as? Number)?.toInt()` does, answering
// "absent or the wrong type" rather than crashing on a hand-built message.
// Both integer widths, because the standard codec picks the narrowest that
// fits and a texture id will outgrow an int32 long before a width does.
bool ReadInt(const EncodableValue* args, const char* key, int64_t* out) {
  if (args == nullptr) return false;
  const auto* map = std::get_if<EncodableMap>(args);
  if (map == nullptr) return false;
  const auto found = map->find(EncodableValue(std::string(key)));
  if (found == map->end()) return false;
  // `narrow` and `wide`, not `small` and `large`: <windows.h> drags in
  // rpcndr.h, which defines `small` as a macro for `char`. A local of that
  // name compiles on every other platform and turns into `const auto* char`
  // here, which is exactly as confusing to read as it sounds.
  if (const auto* narrow = std::get_if<int32_t>(&found->second)) {
    *out = *narrow;
    return true;
  }
  if (const auto* wide = std::get_if<int64_t>(&found->second)) {
    *out = *wide;
    return true;
  }
  return false;
}

}  // namespace

class OrbisFilamentPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  explicit OrbisFilamentPlugin(flutter::TextureRegistrar* textures)
      : textures_(textures) {}

  ~OrbisFilamentPlugin() override = default;

  OrbisFilamentPlugin(const OrbisFilamentPlugin&) = delete;
  OrbisFilamentPlugin& operator=(const OrbisFilamentPlugin&) = delete;

 private:
  void HandleMethodCall(const flutter::MethodCall<EncodableValue>& call,
                        std::unique_ptr<MethodResultValue> result);

  Viewport* Find(int64_t texture_id) {
    const auto found = viewports_.find(texture_id);
    return found == viewports_.end() ? nullptr : found->second.get();
  }

  void Create(const EncodableValue* args,
              std::unique_ptr<MethodResultValue> result);
  void Resize(const EncodableValue* args,
              std::unique_ptr<MethodResultValue> result);
  void SetScene(const EncodableValue* args,
                std::unique_ptr<MethodResultValue> result);
  void Stats(const EncodableValue* args,
             std::unique_ptr<MethodResultValue> result);
  void Dispose(const EncodableValue* args,
               std::unique_ptr<MethodResultValue> result);

  flutter::TextureRegistrar* textures_ = nullptr;  // borrowed
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel_;
  std::map<int64_t, std::unique_ptr<Viewport>> viewports_;
};

void OrbisFilamentPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      registrar->messenger(), "orbis_filament",
      &flutter::StandardMethodCodec::GetInstance());

  auto plugin =
      std::make_unique<OrbisFilamentPlugin>(registrar->texture_registrar());

  channel->SetMethodCallHandler(
      [raw = plugin.get()](const auto& call, auto result) {
        raw->HandleMethodCall(call, std::move(result));
      });

  // The channel is kept by the plugin, and the plugin by the registrar, so
  // the handler above outlives neither.
  plugin->channel_ = std::move(channel);
  registrar->AddPlugin(std::move(plugin));
}

void OrbisFilamentPlugin::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<MethodResultValue> result) {
  const std::string& method = call.method_name();
  const EncodableValue* args = call.arguments();

  if (method == "create") {
    Create(args, std::move(result));
  } else if (method == "resize") {
    Resize(args, std::move(result));
  } else if (method == "setScene") {
    SetScene(args, std::move(result));
  } else if (method == "stats") {
    Stats(args, std::move(result));
  } else if (method == "dispose") {
    Dispose(args, std::move(result));
  } else {
    result->NotImplemented();
  }
}

void OrbisFilamentPlugin::Create(const EncodableValue* args,
                                 std::unique_ptr<MethodResultValue> result) {
  int64_t width = 0;
  int64_t height = 0;
  if (!ReadInt(args, "width", &width) || !ReadInt(args, "height", &height) ||
      width <= 0 || height <= 0) {
    result->Error("bad-args", "create needs a positive width and height");
    return;
  }
  if (textures_ == nullptr) {
    result->Error("no-registry", "No TextureRegistrar");
    return;
  }

  std::unique_ptr<Viewport> viewport =
      Viewport::Start(textures_, uint32_t(width), uint32_t(height));
  if (viewport == nullptr) {
    result->Error("no-renderer",
                  "Filament could not start. No backend (Vulkan, then OpenGL) "
                  "was available.");
    return;
  }

  const int64_t texture_id = viewport->texture_id();
  viewports_[texture_id] = std::move(viewport);
  result->Success(EncodableValue(texture_id));
}

void OrbisFilamentPlugin::Resize(const EncodableValue* args,
                                 std::unique_ptr<MethodResultValue> result) {
  int64_t texture_id = 0;
  int64_t width = 0;
  int64_t height = 0;
  if (!ReadInt(args, "textureId", &texture_id) ||
      !ReadInt(args, "width", &width) || !ReadInt(args, "height", &height)) {
    result->Error("bad-args", "resize needs textureId, width, height");
    return;
  }
  if (Viewport* viewport = Find(texture_id)) {
    viewport->Resize(uint32_t(width), uint32_t(height));
  }
  result->Success();
}

void OrbisFilamentPlugin::SetScene(const EncodableValue* args,
                                   std::unique_ptr<MethodResultValue> result) {
  int64_t texture_id = 0;
  if (!ReadInt(args, "textureId", &texture_id)) {
    result->Error("bad-args", "setScene needs a textureId");
    return;
  }
  std::unique_ptr<Scene> scene = Scene::From(args);
  if (scene == nullptr) {
    result->Error("bad-scene",
                  "setScene needs keys, float32 transforms (16 each), colours "
                  "(3 each), flags, lights (16 floats each), fog (10 floats) "
                  "and a camera.");
    return;
  }

  Viewport* viewport = Find(texture_id);
  if (viewport == nullptr) {
    result->Success();
    return;
  }
  viewport->ApplyScene(*scene);

  // Answered once the scene is actually in, as every other plugin does.
  EncodableMap notes;
  for (const auto& note : viewport->Notes()) {
    notes[EncodableValue(note.first)] = EncodableValue(note.second);
  }
  result->Success(EncodableValue(notes));
}

void OrbisFilamentPlugin::Stats(const EncodableValue* args,
                                std::unique_ptr<MethodResultValue> result) {
  int64_t texture_id = 0;
  Viewport* viewport =
      ReadInt(args, "textureId", &texture_id) ? Find(texture_id) : nullptr;
  if (viewport == nullptr) {
    result->Success();
    return;
  }

  EncodableMap stats;
  stats[EncodableValue("gpuMilliseconds")] =
      EncodableValue(viewport->GpuMilliseconds());
  stats[EncodableValue("passTimings")] = EncodableValue(viewport->PassTimings());
  stats[EncodableValue("batching")] = EncodableValue(viewport->Batching());
  result->Success(EncodableValue(stats));
}

void OrbisFilamentPlugin::Dispose(const EncodableValue* args,
                                  std::unique_ptr<MethodResultValue> result) {
  int64_t texture_id = 0;
  if (!ReadInt(args, "textureId", &texture_id)) {
    result->Error("bad-args", "dispose needs textureId");
    return;
  }
  viewports_.erase(texture_id);
  result->Success();
}

}  // namespace orbis_windows

void OrbisFilamentPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  orbis_windows::OrbisFilamentPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
