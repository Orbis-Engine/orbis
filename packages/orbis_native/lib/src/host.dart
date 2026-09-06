import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:orbis_core/native.dart' as core;
import 'package:orbis_core/orbis_core.dart';

/// What a script may call back into, laid out exactly as `orbis_script.h`
/// declares it.
///
/// Order and type are the contract. Every member here has a counterpart in the
/// header, and the two are checked against each other by a test that compiles
/// a script asserting the struct's size — a member added on one side and
/// forgotten on the other is otherwise a silent call through the wrong slot.
final class OrbisScriptHost extends Struct {
  @Uint32()
  external int abi;

  external Pointer<core.OrbisWorldStruct> world;

  external Pointer<NativeFunction<Void Function(Pointer<Char>)>> log;

  external Pointer<
      NativeFunction<
          Uint32 Function(Pointer<core.OrbisWorldStruct>, Pointer<Char>,
              Uint32, Uint32)>> componentRegister;
  external Pointer<
      NativeFunction<
          Uint32 Function(Pointer<core.OrbisWorldStruct>,
              Pointer<Char>)>> componentLookup;

  external Pointer<
      NativeFunction<Uint64 Function(Pointer<core.OrbisWorldStruct>)>>
      entityCreate;
  external Pointer<
          NativeFunction<Void Function(Pointer<core.OrbisWorldStruct>, Uint64)>>
      entityDestroy;
  external Pointer<
          NativeFunction<Bool Function(Pointer<core.OrbisWorldStruct>, Uint64)>>
      entityAlive;
  external Pointer<
      NativeFunction<Uint32 Function(Pointer<core.OrbisWorldStruct>)>>
      entityCount;
  external Pointer<
      NativeFunction<
          Bool Function(Pointer<core.OrbisWorldStruct>, Uint64, Uint32,
              Pointer<Void>)>> entityAdd;
  external Pointer<
      NativeFunction<
          Bool Function(Pointer<core.OrbisWorldStruct>, Uint64,
              Uint32)>> entityRemove;
  external Pointer<
      NativeFunction<
          Bool Function(Pointer<core.OrbisWorldStruct>, Uint64,
              Uint32)>> entityHas;
  external Pointer<
      NativeFunction<
          Pointer<Void> Function(Pointer<core.OrbisWorldStruct>, Uint64,
              Uint32)>> entityGet;

  external Pointer<
      NativeFunction<
          Pointer<core.OrbisQueryStruct> Function(
              Pointer<core.OrbisWorldStruct>, Pointer<Uint32>,
              Uint32)>> queryCreate;
  external Pointer<
          NativeFunction<Void Function(Pointer<core.OrbisQueryStruct>)>>
      queryDestroy;
  external Pointer<
          NativeFunction<Uint32 Function(Pointer<core.OrbisQueryStruct>)>>
      queryChunkCount;
  external Pointer<
      NativeFunction<
          Uint32 Function(Pointer<core.OrbisQueryStruct>,
              Uint32)>> queryChunkLength;
  external Pointer<
      NativeFunction<
          Pointer<Void> Function(Pointer<core.OrbisQueryStruct>, Uint32,
              Uint32)>> queryChunkColumn;
  external Pointer<
      NativeFunction<
          Pointer<Uint64> Function(Pointer<core.OrbisQueryStruct>,
              Uint32)>> queryChunkEntities;

  external Pointer<
      NativeFunction<
          core.OrbisTransformsStruct Function(
              Pointer<core.OrbisWorldStruct>)>> transformRegister;

  external Pointer<
      NativeFunction<
          Double Function(Pointer<Char>, Pointer<Char>,
              Double)>> dataNumber;
  external Pointer<
          NativeFunction<Bool Function(Pointer<Char>, Pointer<Char>, Bool)>>
      dataToggle;
  external Pointer<
          NativeFunction<Pointer<Char> Function(Pointer<Char>, Pointer<Char>)>>
      dataText;
}

/// Where a script's values come from.
///
/// Supplied by whatever is embedding the engine — the editor reads a `.odata`
/// file, a test answers from a map, a shipped game reads whatever it packed.
/// The script does not know or care which, and that is the point: the same
/// script runs in the editor and in the game.
abstract interface class ScriptValues {
  double number(String asset, String key, double fallback);

  bool toggle(String asset, String key, bool fallback);

  /// Null when there is no such value, which the script sees as a null
  /// pointer.
  String? text(String asset, String key);
}

/// Nothing to read. What a script gets when the embedder supplies no values.
class NoValues implements ScriptValues {
  const NoValues();

  @override
  double number(String asset, String key, double fallback) => fallback;

  @override
  bool toggle(String asset, String key, bool fallback) => fallback;

  @override
  String? text(String asset, String key) => null;
}

/// The host table, alive for as long as the scripts using it.
///
/// One per world rather than one per script: the table holds no per-script
/// state, and forty scripts each allocating their own copy of the same
/// function pointers would be forty allocations saying the same thing.
class ScriptHost {
  ScriptHost(this.world, {ScriptValues values = const NoValues(), void Function(String)? onLog})
      : _values = values,
        _onLog = onLog {
    _fill();
  }

  /// The version this host was built to. A script reporting anything else is
  /// refused rather than called.
  static const int abi = 1;

  final World world;
  final ScriptValues _values;
  final void Function(String)? _onLog;

  final Pointer<OrbisScriptHost> _table = calloc<OrbisScriptHost>();

  /// The text handed back by the last [ScriptValues.text].
  ///
  /// One buffer, freed when the next call replaces it, which is what the
  /// header promises: a script that needs the string to outlive the line that
  /// read it copies it. Handing out a fresh allocation per call and never
  /// freeing it would leak once a frame.
  Pointer<Char> _lastText = nullptr;

  late final NativeCallable<Void Function(Pointer<Char>)> _log;
  late final NativeCallable<Double Function(Pointer<Char>, Pointer<Char>, Double)>
      _number;
  late final NativeCallable<Bool Function(Pointer<Char>, Pointer<Char>, Bool)>
      _toggle;
  late final NativeCallable<Pointer<Char> Function(Pointer<Char>, Pointer<Char>)>
      _text;

  bool _disposed = false;

  Pointer<OrbisScriptHost> get pointer {
    if (_disposed) throw StateError('This ScriptHost has been disposed.');
    return _table;
  }

  void _fill() {
    _log = NativeCallable<Void Function(Pointer<Char>)>.isolateLocal(
      (Pointer<Char> message) {
        final said = message == nullptr ? '' : message.cast<Utf8>().toDartString();
        (_onLog ?? print)(said);
      },
    );
    _number = NativeCallable<
        Double Function(Pointer<Char>, Pointer<Char>, Double)>.isolateLocal(
      (Pointer<Char> asset, Pointer<Char> key, double fallback) =>
          _values.number(_read(asset), _read(key), fallback),
      exceptionalReturn: 0.0,
    );
    _toggle =
        NativeCallable<Bool Function(Pointer<Char>, Pointer<Char>, Bool)>
            .isolateLocal(
      (Pointer<Char> asset, Pointer<Char> key, bool fallback) =>
          _values.toggle(_read(asset), _read(key), fallback),
      exceptionalReturn: false,
    );
    _text = NativeCallable<
        Pointer<Char> Function(Pointer<Char>, Pointer<Char>)>.isolateLocal(
      (Pointer<Char> asset, Pointer<Char> key) {
        final said = _values.text(_read(asset), _read(key));
        if (_lastText != nullptr) calloc.free(_lastText);
        _lastText =
            said == null ? nullptr : said.toNativeUtf8().cast<Char>();
        return _lastText;
      },
    );

    final table = _table.ref;
    table
      ..abi = abi
      ..world = world.nativeHandle
      ..log = _log.nativeFunction
      // Taken from the same declarations Dart binds the core with, so there is
      // no second description of the core's API here to drift from the first.
      ..componentRegister = Native.addressOf(core.componentRegister)
      ..componentLookup = Native.addressOf(core.componentLookup)
      ..entityCreate = Native.addressOf(core.entityCreate)
      ..entityDestroy = Native.addressOf(core.entityDestroy)
      ..entityAlive = Native.addressOf(core.entityAlive)
      ..entityCount = Native.addressOf(core.entityCount)
      ..entityAdd = Native.addressOf(core.entityAdd)
      ..entityRemove = Native.addressOf(core.entityRemove)
      ..entityHas = Native.addressOf(core.entityHas)
      ..entityGet = Native.addressOf(core.entityGet)
      ..queryCreate = Native.addressOf(core.queryCreate)
      ..queryDestroy = Native.addressOf(core.queryDestroy)
      ..queryChunkCount = Native.addressOf(core.queryChunkCount)
      ..queryChunkLength = Native.addressOf(core.queryChunkLength)
      ..queryChunkColumn = Native.addressOf(core.queryChunkColumn)
      ..queryChunkEntities = Native.addressOf(core.queryChunkEntities)
      ..transformRegister = Native.addressOf(core.transformRegister)
      ..dataNumber = _number.nativeFunction
      ..dataToggle = _toggle.nativeFunction
      ..dataText = _text.nativeFunction;
  }

  static String _read(Pointer<Char> text) =>
      text == nullptr ? '' : text.cast<Utf8>().toDartString();

  /// Frees the table and the callbacks.
  ///
  /// Every script using it must have been stopped first: a script holding this
  /// pointer after this is holding freed memory, and the header says the host
  /// outlives the call rather than the frame.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _log.close();
    _number.close();
    _toggle.close();
    _text.close();
    if (_lastText != nullptr) calloc.free(_lastText);
    calloc.free(_table);
  }
}
