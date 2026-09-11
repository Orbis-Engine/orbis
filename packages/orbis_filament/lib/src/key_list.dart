// A scene's key arrays, which are Int64 everywhere except the web.
//
// `orbis_renderer.h` takes object, material, video, light, probe and outline
// keys as `int64_t`, and every host but this one hands them across as an
// `Int64List` — the standard codec turns that into a Swift `[Int64]` and a
// Kotlin `LongArray` with no conversion at either end.
//
// Dart compiled to JavaScript has no `Int64List` at all: constructing one
// throws `Unsupported operation: Int64List not supported on the web`, because
// a JavaScript number is a double and there is nothing to lay the list over.
// So the web half below builds an ordinary `List<int>` instead, and
// `lib/src/web/orbis_scene_web.dart` writes those out as little-endian
// low/high 32-bit pairs when it copies them into the wasm heap — the same
// thing `native/web/host/main.js`'s `allocI64` does.
//
// The static type is `List<int>` so that both halves satisfy it. On every
// platform that has `Int64List` the runtime type is still exactly that, so
// what reaches Swift and Kotlin is byte-for-byte what it was before.
export 'key_list_native.dart'
    if (dart.library.js_interop) 'key_list_web.dart';
