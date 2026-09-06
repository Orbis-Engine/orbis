import 'dart:ffi';
import 'dart:io';

import 'host.dart';

/// Why a script would not load.
class ScriptError implements Exception {
  const ScriptError(this.message);

  final String message;

  @override
  String toString() => message;
}

typedef _AbiFn = Uint32 Function();
typedef _StartFn = Void Function(Pointer<OrbisScriptHost>);
typedef _StepFn = Void Function(Double);
typedef _StopFn = Void Function();

/// A compiled script, loaded and running.
///
/// The four questions and nothing else. What a script *is* — a `.cpp`, a
/// TypeScript module, a Dart file — stops mattering at this line: everything
/// above it sees start, step and stop.
class NativeScript {
  NativeScript._(this._name, this._start, this._step, this._stop);

  final String _name;

  final void Function(Pointer<OrbisScriptHost>) _start;
  final void Function(double) _step;
  final void Function() _stop;

  bool _started = false;

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

    final DynamicLibrary opened;
    try {
      opened = DynamicLibrary.open(library.path);
    } on ArgumentError catch (error) {
      throw ScriptError('${library.path} could not be loaded: ${error.message}');
    }

    // The version first, before anything else is looked up: a library built
    // against a different contract has functions of these names that mean
    // something else, and calling one to find that out is a crash.
    final int Function() abi;
    try {
      abi = opened.lookupFunction<_AbiFn, int Function()>('orbis_script_abi');
    } on ArgumentError {
      throw ScriptError(
        '${_nameOf(library)} does not look like a script: it has no '
        'orbis_script_abi. Did it use the ORBIS_SCRIPT macro?',
      );
    }

    final version = abi();
    if (version != ScriptHost.abi) {
      throw ScriptError(
        '${_nameOf(library)} was built against contract $version and this '
        'engine speaks ${ScriptHost.abi}. Rebuild it.',
      );
    }

    for (final wanted in const ['orbis_start', 'orbis_step', 'orbis_stop']) {
      if (!opened.providesSymbol(wanted)) {
        throw ScriptError('${_nameOf(library)} has no $wanted.');
      }
    }

    return NativeScript._(
      _nameOf(library),
      opened.lookupFunction<_StartFn, void Function(Pointer<OrbisScriptHost>)>(
        'orbis_start',
      ),
      opened.lookupFunction<_StepFn, void Function(double)>('orbis_step'),
      opened.lookupFunction<_StopFn, void Function()>('orbis_stop'),
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

}
