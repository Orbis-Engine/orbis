// The ORBIS_* switches, wherever this gallery is running.
//
// Every example in the gallery is driven by environment variables — which
// example to show, which light, how many trees, what the shutter is. Reading
// them takes `dart:io` and, on the iOS simulator, `dart:ffi` as well (see
// orbis_env_native.dart for why), and neither exists for a web target.
//
// So the reading moves behind this one line. The native half is the code that
// was in main.dart, moved rather than changed, so every platform that already
// worked reads exactly what it read before; the web half takes the same
// switches from the query string.
export 'orbis_env_native.dart'
    if (dart.library.js_interop) 'orbis_env_web.dart';
