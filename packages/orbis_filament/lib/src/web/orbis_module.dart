// The Emscripten module, as Dart sees it.
//
// `native/web/build.sh` links the renderer core and its C ABI into
// `orbis_renderer.js` + `orbis_renderer.wasm` with `-sMODULARIZE=1
// -sEXPORT_NAME=OrbisRendererModule`, exporting every `orbis_renderer_*`
// function orbis_renderer.h names plus `_malloc`, `_free` and
// `_orbis_web_create_on_canvas`. This file is the Dart half of what
// `native/web/host/main.js` does in plain JavaScript: `ccall` for the calls,
// and hand-marshalled typed arrays for everything that is not a scalar,
// because `ccall` marshals numbers and strings but never arrays.
//
// Nothing here knows what a scene is; see orbis_scene_web.dart for that.
library;

import 'dart:js_interop';
// `has`, `[]` and `setProperty` on a plain JSObject: reaching a global by
// name, and building the settings object Emscripten's factory takes, are both
// untyped lookups by definition — there is no static interface to declare for
// "whatever the page loaded".
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

/// The name `orbis_renderer.js` defines on `globalThis`, from build.sh's
/// `-sEXPORT_NAME=OrbisRendererModule`.
const String _factoryName = 'OrbisRendererModule';

/// Whether `orbis_renderer.js` has been loaded into the page at all.
///
/// Asked of the global object rather than declared as an `external` getter,
/// which would throw a ReferenceError instead of answering false when the
/// script is missing. The script is a plain `<script src="...">` in the
/// host's `web/index.html`, so a page that forgot it fails here, once, with
/// something to read, rather than at the first `ccall` with "undefined is not
/// a function".
bool get orbisRendererScriptLoaded => globalContext.has(_factoryName);

/// What `OrbisRendererModule({canvas})` resolves to.
///
/// Only the members `build.sh` actually exported are declared: the heap views,
/// the allocator, `ccall`, and `UTF8ToString`. `EXPORTED_RUNTIME_METHODS` in
/// that script is the authority on this list — adding a member here that is
/// not in it compiles and then fails at runtime as `undefined`.
extension type OrbisModule._(JSObject _) implements JSObject {
  // Renamed rather than spelled with the leading underscore Emscripten uses:
  // a Dart member called `_malloc` would be library-private and would not be
  // looked up on the JavaScript object at all.
  @JS('_malloc')
  external JSNumber malloc(int bytes);

  @JS('_free')
  external void free(int pointer);

  /// The wasm heap, as typed views. These are invalidated whenever the heap
  /// grows (`-sALLOW_MEMORY_GROWTH=1` is linked), so they are read fresh from
  /// the module on every use rather than cached in a Dart field.
  external JSUint8Array get HEAPU8;
  external JSInt32Array get HEAP32;
  external JSUint32Array get HEAPU32;
  external JSFloat32Array get HEAPF32;

  external JSAny? ccall(
    String name,
    String? returnType,
    JSArray<JSString> argTypes,
    JSArray<JSAny?> args,
  );

  external String UTF8ToString(int pointer);
}

/// Loads one instance of the module, drawing into [canvas].
///
/// Emscripten's `MODULARIZE` factory takes the settings object the runtime
/// would otherwise read off a global `Module`, and `canvas` is the one that
/// matters: Emscripten's GL emulation binds its WebGL context to it. One
/// module instance per canvas, so two `OrbisView`s on a page are two
/// independent engines — see orbis_filament_web.dart for what that costs.
Future<OrbisModule> loadOrbisModule(JSObject canvas) async {
  if (!orbisRendererScriptLoaded) {
    throw StateError(
      'orbis_renderer.js is not loaded. Add '
      '<script src="orbis_renderer.js"></script> to web/index.html, and copy '
      'orbis_renderer.js and orbis_renderer.wasm into the app\'s web/ '
      'directory (see packages/orbis_filament/native/web/README.md).',
    );
  }
  final factory = globalContext[_factoryName] as JSFunction;
  final settings = JSObject();
  settings.setProperty('canvas'.toJS, canvas);
  final promise = factory.callAsFunction(null, settings) as JSPromise<JSObject>;
  return OrbisModule._(await promise.toDart);
}

/// A scratch allocation in the wasm heap, freed as a group.
///
/// Every array a scene call takes has to exist as a pointer into the module's
/// own memory for the length of that one call — the C ABI reads it and keeps
/// nothing — so allocations are made per call and released together
/// afterwards. The same shape as `main.js`'s `toFree`/`freeAll`, which is
/// there for the same reason.
class OrbisHeap {
  OrbisHeap(this._module);

  final OrbisModule _module;
  final List<int> _allocations = [];

  /// Emscripten's `malloc` aligns to at least eight bytes, which is enough
  /// for the `int64` pairs below; nothing this ABI takes is wider.
  int _alloc(int bytes) {
    // A zero-byte malloc may legitimately return a pointer that is never
    // read, but the ABI reads "count 0" as "nothing here" and never
    // dereferences it, so a one-byte floor keeps every pointer non-null
    // rather than making callers special-case an empty array.
    final pointer = _module.malloc(bytes < 1 ? 1 : bytes).toDartInt;
    _allocations.add(pointer);
    return pointer;
  }

  /// Copies [values] into the heap as 32-bit floats. Returns the pointer.
  int floats(List<double> values) {
    final pointer = _alloc(values.length * 4);
    final heap = _module.HEAPF32.toDart;
    final at = pointer >> 2;
    for (var i = 0; i < values.length; i++) {
      heap[at + i] = values[i];
    }
    return pointer;
  }

  /// Copies [values] into the heap as 32-bit signed integers.
  int ints(List<int> values) {
    final pointer = _alloc(values.length * 4);
    final heap = _module.HEAP32.toDart;
    final at = pointer >> 2;
    for (var i = 0; i < values.length; i++) {
      heap[at + i] = values[i];
    }
    return pointer;
  }

  /// Copies [values] into the heap as 64-bit signed integers.
  ///
  /// Written as little-endian low/high 32-bit pairs, exactly as `main.js`'s
  /// `allocI64` does. Dart compiled to JavaScript has no 64-bit integer — a
  /// number is a double — so the high word is derived rather than shifted:
  /// `>>> 32` on a JavaScript number is defined to operate on the low 32 bits
  /// only and would silently give the wrong answer for a key above 2^31.
  int int64s(List<int> values) {
    final pointer = _alloc(values.length * 8);
    final heap = _module.HEAP32.toDart;
    final at = pointer >> 2;
    for (var i = 0; i < values.length; i++) {
      final value = values[i];
      final low = value % 4294967296;
      heap[at + i * 2] = low >= 2147483648 ? low - 4294967296 : low;
      heap[at + i * 2 + 1] = (value - low) ~/ 4294967296;
    }
    return pointer;
  }

  /// Copies [bytes] into the heap verbatim.
  int uint8s(Uint8List bytes) {
    final pointer = _alloc(bytes.length);
    final heap = _module.HEAPU8.toDart;
    heap.setRange(pointer, pointer + bytes.length, bytes);
    return pointer;
  }

  /// A NUL-terminated UTF-8 copy of [value].
  int string(String value) {
    final utf8 = <int>[];
    for (final unit in value.runes) {
      if (unit < 0x80) {
        utf8.add(unit);
      } else if (unit < 0x800) {
        utf8..add(0xC0 | (unit >> 6))..add(0x80 | (unit & 0x3F));
      } else if (unit < 0x10000) {
        utf8
          ..add(0xE0 | (unit >> 12))
          ..add(0x80 | ((unit >> 6) & 0x3F))
          ..add(0x80 | (unit & 0x3F));
      } else {
        utf8
          ..add(0xF0 | (unit >> 18))
          ..add(0x80 | ((unit >> 12) & 0x3F))
          ..add(0x80 | ((unit >> 6) & 0x3F))
          ..add(0x80 | (unit & 0x3F));
      }
    }
    final pointer = _alloc(utf8.length + 1);
    final heap = _module.HEAPU8.toDart;
    heap.setRange(pointer, pointer + utf8.length, utf8);
    heap[pointer + utf8.length] = 0;
    return pointer;
  }

  /// An array of `const char *`, as the ABI's `paths`/`names` arguments take:
  /// each string copied into the heap, then a block of pointers to them.
  int strings(List<String> values) {
    final pointers = [for (final value in values) string(value)];
    return ints(pointers);
  }

  /// Releases everything allocated through this heap.
  void free() {
    for (final pointer in _allocations) {
      _module.free(pointer);
    }
    _allocations.clear();
  }
}

/// Calls an exported C function, with every argument already a number.
///
/// `ccall`'s `'number'` covers both an `int` and a pointer, which is all this
/// ABI takes once arrays have been copied in by [OrbisHeap]; `'string'` is
/// used only where a call takes a plain `const char *` that is not part of an
/// array, and `'boolean'` never — the ABI spells its flags as `int`.
int orbisCall(OrbisModule module, String name, List<Object?> args) {
  final types = <JSString>[];
  final values = <JSAny?>[];
  for (final arg in args) {
    switch (arg) {
      case final int value:
        types.add('number'.toJS);
        values.add(value.toJS);
      case final double value:
        types.add('number'.toJS);
        values.add(value.toJS);
      case final String value:
        types.add('string'.toJS);
        values.add(value.toJS);
      case null:
        types.add('number'.toJS);
        values.add(0.toJS);
      default:
        throw ArgumentError('orbisCall($name): cannot marshal $arg');
    }
  }
  final result = module.ccall(
    name,
    'number',
    types.toJS,
    values.toJS,
  );
  return (result as JSNumber?)?.toDartInt ?? 0;
}
