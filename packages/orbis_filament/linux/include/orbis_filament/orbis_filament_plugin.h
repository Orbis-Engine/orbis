#ifndef ORBIS_FILAMENT_PLUGIN_H_
#define ORBIS_FILAMENT_PLUGIN_H_

// The plugin's whole public surface: one function, called once, by the
// registrant Flutter generates into the application.
//
// This header exists because of how Flutter's Linux tooling wires a plugin
// up. `pluginClass: OrbisFilamentPlugin` in pubspec.yaml makes the tool
// write, into the runner's generated_plugin_registrant.cc,
//
//     #include <orbis_filament/orbis_filament_plugin.h>
//     orbis_filament_plugin_register_with_registrar(registrar);
//
// so the include path and the function name are both derived from that one
// line and neither is ours to choose. Everything else the plugin does is
// private to linux/ and reached through the `orbis_filament` method channel,
// exactly as on the other three platforms.

#include <flutter_linux/flutter_linux.h>

// Set by the plugin's own build (see CMakeLists.txt) and not by whoever
// includes this, which is how the registrant gets the import side of the
// visibility attribute rather than the export side.
#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __attribute__((visibility("default")))
#else
#define FLUTTER_PLUGIN_EXPORT
#endif

G_BEGIN_DECLS

FLUTTER_PLUGIN_EXPORT void orbis_filament_plugin_register_with_registrar(
    FlPluginRegistrar* registrar);

G_END_DECLS

#endif  // ORBIS_FILAMENT_PLUGIN_H_
