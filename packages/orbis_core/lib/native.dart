/// The core's C ABI, exactly as `orbis_core.h` declares it.
///
/// Dart is not the only thing that binds to this core: a native script is
/// handed these same function addresses in a table, and a console shell with
/// no Dart in it calls them directly. That is why this is public — a front end
/// onto the core needs the raw entry points, and a front end that had to go
/// through `World` would be a front end onto Dart rather than onto the engine.
///
/// Ordinary use wants `World` instead. Nothing here checks a handle, owns a
/// lifetime, or interprets a result.
library;

export 'src/bindings.dart';
