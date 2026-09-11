// Key arrays where `Int64List` exists: every platform but the web.
//
// The default half of the conditional export in key_list.dart. Returning the
// concrete `Int64List` is what keeps the channel message identical to what it
// has always been — the standard codec writes it with the int64 type tag, and
// OrbisFilamentPlugin.swift's `int64s` and OrbisScene.kt's `LongArray` cast
// both insist on exactly that tag.
library;

import 'dart:typed_data';

/// A key array of [length] keys, all zero.
List<int> makeKeyList(int length) => Int64List(length);

/// A key array holding [keys].
List<int> keyListFrom(Iterable<int> keys) => Int64List.fromList(keys.toList());
