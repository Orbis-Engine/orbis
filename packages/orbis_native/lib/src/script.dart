import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'host.dart';

/// Why a script would not load.
class ScriptError implements Exception {
  const ScriptError(this.message);

  final String message;

  @override
  String toString() => message;
}

typedef _AbiFn = Uint32 Function();
typedef _SizeFn = Uint32 Function();
typedef _StartFn = Void Function(Pointer<OrbisScriptHost>);
typedef _StepFn = Void Function(Double);
typedef _StopFn = Void Function();

/// The loader itself, reached directly rather than through DynamicLibrary.
///
/// `DynamicLibrary` can open a library and can never close one, so a rebuilt
/// script left the image it replaced in the process for as long as the process
/// lived — a leak per save, and on a long afternoon of editing a script, a
/// leak per save several hundred times over.
///
/// These are the same three calls `DynamicLibrary` makes. Making them here
/// costs nothing at runtime, because what comes back is the same function
/// address either way, and it means the fourth one exists.
final class _Loader {
  static final DynamicLibrary _process = DynamicLibrary.process();

  static final Pointer<Void> Function(Pointer<Char>, int) open = _process
      .lookupFunction<
        Pointer<Void> Function(Pointer<Char>, Int32),
        Pointer<Void> Function(Pointer<Char>, int)
      >('dlopen');

  static final Pointer<Void> Function(Pointer<Void>, Pointer<Char>) symbol =
      _process.lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Char>),
        Pointer<Void> Function(Pointer<Void>, Pointer<Char>)
      >('dlsym');

  static final int Function(Pointer<Void>) close = _process
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('dlclose');

  static final Pointer<Char> Function() error = _process
      .lookupFunction<Pointer<Char> Function(), Pointer<Char> Function()>(
        'dlerror',
      );

  /// RTLD_NOW | RTLD_LOCAL: every symbol resolved at load, and nothing put
  /// into the global namespace where two scripts could shadow each other.
  ///
  /// The constants are not the same on both systems, and the difference is
  /// vicious. RTLD_NOW is 2 everywhere. RTLD_LOCAL is 4 on macOS, and on
  /// glibc it is 0 — because local is already the default — while 4 there
  /// means RTLD_NOLOAD: *do not load this, only tell me whether it is
  /// already loaded*. Sending macOS's flags to Linux therefore asks for a
  /// handle to a library nobody has opened, gets null, and dlerror has
  /// nothing to report because nothing went wrong. Every script failed to
  /// load, and said "unknown" about it.
  static final int flags = Platform.isMacOS ? 2 | 4 : 2;

  static String lastError() {
    final said = error();
    return said == nullptr ? 'unknown' : said.cast<Utf8>().toDartString();
  }
}

/// The loader for Windows, which has none of `dlopen`'s family.
///
/// `LoadLibraryW` is `dlopen`, `GetProcAddress` is `dlsym` — close enough in
/// shape that it is the same call once the name is UTF-8 — and `FreeLibrary`
/// is `dlclose`. All three live in `kernel32.dll` rather than in the running
/// executable's own export table, which is what [DynamicLibrary.process]
/// would search: a script's symbols are found by opening *it*, not by asking
/// the process about itself, and on Windows the process handle simply does
/// not see into a DLL loaded after the fact the way `RTLD_DEFAULT` does on
/// macOS and Linux.
///
/// Kept beside `_Loader` rather than folded into it, because the one call
/// whose signature actually differs — opening the library, a wide string
/// here against a UTF-8 one and a flag `dlopen` takes that this has no
/// equivalent for — would otherwise hide behind a signature neither side
/// really has.
final class _WindowsLoader {
  static final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

  static final Pointer<Void> Function(Pointer<Utf16>) open = _kernel32
      .lookupFunction<
        Pointer<Void> Function(Pointer<Utf16>),
        Pointer<Void> Function(Pointer<Utf16>)
      >('LoadLibraryW');

  static final Pointer<Void> Function(Pointer<Void>, Pointer<Char>) symbol =
      _kernel32.lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Char>),
        Pointer<Void> Function(Pointer<Void>, Pointer<Char>)
      >('GetProcAddress');

  static final int Function(Pointer<Void>) close = _kernel32
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('FreeLibrary');

  static final int Function() lastError = _kernel32
      .lookupFunction<Uint32 Function(), int Function()>('GetLastError');
}

/// A compiled script, loaded and running.
///
/// The four questions and nothing else. What a script *is* — a `.cpp`, a
/// TypeScript module, a Dart file — stops mattering at this line: everything
/// above it sees start, step and stop.
class NativeScript {
  NativeScript._(
    this._handle,
    this._file,
    this._name,
    this._start,
    this._step,
    this._stop,
  );

  final Pointer<Void> _handle;
  final File _file;
  final String _name;

  final void Function(Pointer<OrbisScriptHost>) _start;
  final void Function(double) _step;
  final void Function() _stop;

  bool _started = false;
  bool _closed = false;

  /// What it is called, for a message about it.
  String get name => _name;

  bool get isRunning => _started;

  /// Opens a built library and checks it is one of ours.
  ///
  /// Throws rather than returning null, because every failure here has a
  /// different cause and a caller that only knows "it did not load" cannot say
  /// anything useful about any of them.
  static NativeScript open(File library) {
    if (!library.existsSync()) {
      throw ScriptError('${library.path} is not there.');
    }

    final handle = Platform.isWindows
        ? using(
            (arena) => _WindowsLoader.open(
              library.path.toNativeUtf16(allocator: arena),
            ),
          )
        : using(
            (arena) => _Loader.open(
              library.path.toNativeUtf8(allocator: arena).cast<Char>(),
              _Loader.flags,
            ),
          );
    if (handle == nullptr) {
      // GetLastError is a code, not a message — FormatMessage would spell it
      // out, but the number is enough to look up and this is already two
      // loaders for the sake of one platform.
      final why = Platform.isWindows
          ? 'Windows error ${_WindowsLoader.lastError()}'
          : _Loader.lastError();
      throw ScriptError('${_nameOf(library)} could not be loaded: $why');
    }

    Pointer<Void> find(String symbol) => using((arena) {
      final name = symbol.toNativeUtf8(allocator: arena).cast<Char>();
      return Platform.isWindows
          ? _WindowsLoader.symbol(handle, name)
          : _Loader.symbol(handle, name);
    });

    void refuse(String why) {
      if (Platform.isWindows) {
        _WindowsLoader.close(handle);
      } else {
        _Loader.close(handle);
      }
      throw ScriptError(why);
    }

    // The version first, before anything else is looked up: a library built
    // against a different contract has functions of these names that mean
    // something else, and calling one to find that out is a crash.
    final abi = find('orbis_script_abi');
    if (abi == nullptr) {
      refuse(
        '${_nameOf(library)} does not look like a script: it has no '
        'orbis_script_abi. Did it use the ORBIS_SCRIPT macro?',
      );
    }

    final version = abi
        .cast<NativeFunction<_AbiFn>>()
        .asFunction<int Function()>()();
    if (version != ScriptHost.abi) {
      refuse(
        '${_nameOf(library)} was built against contract $version and this '
        'engine speaks ${ScriptHost.abi}. Rebuild it.',
      );
    }

    // Then the table itself. Two builds can agree about the version and
    // disagree about the struct, because one was compiled against a header
    // somebody had edited, and the only way to catch that is to compare the
    // thing rather than the number beside it.
    final size = find('orbis_script_host_size');
    final theirs = size == nullptr
        ? 0
        : size.cast<NativeFunction<_SizeFn>>().asFunction<int Function()>()();
    if (theirs != sizeOf<OrbisScriptHost>()) {
      refuse(
        '${_nameOf(library)} was built against a host table of $theirs bytes '
        'and this engine passes ${sizeOf<OrbisScriptHost>()}. The header it '
        'was compiled with is not this one.',
      );
    }

    final entries = <String, Pointer<Void>>{};
    for (final wanted in const ['orbis_start', 'orbis_step', 'orbis_stop']) {
      final found = find(wanted);
      if (found == nullptr) refuse('${_nameOf(library)} has no $wanted.');
      entries[wanted] = found;
    }

    return NativeScript._(
      handle,
      library,
      _nameOf(library),
      entries['orbis_start']!
          .cast<NativeFunction<_StartFn>>()
          .asFunction<void Function(Pointer<OrbisScriptHost>)>(),
      entries['orbis_step']!
          .cast<NativeFunction<_StepFn>>()
          .asFunction<void Function(double)>(),
      entries['orbis_stop']!
          .cast<NativeFunction<_StopFn>>()
          .asFunction<void Function()>(),
    );
  }

  /// The file name without the revision or the extension, which is what
  /// somebody called the script.
  static String _nameOf(File library) =>
      library.uri.pathSegments.last.split('.').first;

  void start(ScriptHost host) {
    if (_started) return;
    _started = true;
    _start(host.pointer);
  }

  void step(double delta) {
    if (!_started) return;
    _step(delta);
  }

  void stop() {
    if (!_started) return;
    _started = false;
    _stop();
  }

  /// Stops it and unloads the library.
  ///
  /// The whole reason the loader is reached directly. Nothing may call into
  /// this script afterwards: its code is gone, and a held function pointer is
  /// an address in unmapped memory.
  ///
  /// The built file goes too. It was written for this load and there will be
  /// another for the next one, and a build folder that only grows is a build
  /// folder somebody eventually has to be told to empty.
  void close() {
    if (_closed) return;
    stop();
    _closed = true;
    if (Platform.isWindows) {
      _WindowsLoader.close(_handle);
    } else {
      _Loader.close(_handle);
    }
    try {
      if (_file.existsSync()) _file.deleteSync();
    } on FileSystemException {
      // Not worth failing a reload over: the next build writes its own file
      // and this one is only taking up space.
    }
  }
}
