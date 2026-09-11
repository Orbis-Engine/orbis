// Key arrays on the web, where `Int64List` does not exist.
//
// The `dart.library.js_interop` half of the conditional export in
// key_list.dart. A plain fixed-length `List<int>` instead: the standard codec
// writes it as a generic list, and the only reader is this package's own web
// plugin, which copies it into the wasm heap as int64 pairs
// (lib/src/web/orbis_module.dart's `OrbisHeap.int64s`). No Swift or Kotlin
// plugin ever sees this shape.
//
// Keys stay exact as long as they fit in 2^53, which is every key this
// package mints and the widest a JavaScript number can hold anyway.
library;

/// A key array of [length] keys, all zero.
List<int> makeKeyList(int length) => List<int>.filled(length, 0);

/// A key array holding [keys].
List<int> keyListFrom(Iterable<int> keys) => List<int>.of(keys);
