/// C++ scripts, compiled and loaded.
///
/// A script is a file that answers four questions — what contract it was built
/// against, what to do when it starts, what to do each frame, and what to do
/// when it stops — and is handed a table of everything it may call back into.
/// The same four questions have a TypeScript implementation through QuickJS
/// and would have a Dart one; this is the C++ front end onto that boundary,
/// not a second engine.
///
/// The contract itself is `include/orbis_script.h`, which is the file worth
/// reading first.
library;

export 'src/host.dart' show NoValues, ScriptHost, ScriptValues;
export 'src/runner.dart' show ScriptRunner, ScriptStatus;
export 'src/script.dart' show NativeScript, ScriptError;
export 'src/toolchain.dart' show BuildResult, Toolchain;
