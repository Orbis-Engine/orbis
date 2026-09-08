import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:orbis_core/orbis_core.dart';

import 'host.dart';
import 'script.dart';
import 'toolchain.dart';

/// What a script is doing.
class ScriptStatus {
  const ScriptStatus({
    required this.name,
    required this.source,
    required this.running,
    required this.output,
    this.revision = 0,
  });

  final String name;
  final File source;

  /// False when the last build failed. The script stays listed either way: a
  /// script that vanished from the list because it did not compile is a script
  /// somebody has to remember they were writing.
  final bool running;

  /// What the compiler last said about it.
  final String output;

  /// How many times it has been built. Every build goes to a library of its
  /// own, so this is also part of the file name.
  final int revision;
}

/// The C++ scripts a world is running.
///
/// Compiles, loads, steps and rebuilds. Everything above this sees start, step
/// and stop; what is underneath is a compiler and a dynamic library, and the
/// same interface has a QuickJS implementation and would have a Dart one.
///
/// **Reloading replaces, it does not resume.** `dart:ffi` cannot close a
/// library, so a rebuilt script is a second library loaded beside the first,
/// and the old one's state goes when it is stopped. That is not a limitation
/// to work around: state a script wants to keep across a rebuild belongs in
/// the world, where the rest of the engine can see it, and a script that kept
/// it in a static would lose it on a scene load anyway.
class ScriptRunner {
  ScriptRunner({
    required this.world,
    required this.build,
    ScriptValues values = const NoValues(),
    Toolchain? toolchain,
    List<String>? includes,
    void Function(String)? onLog,
  }) : toolchain = toolchain ?? Toolchain.find(),
       includes = includes ?? engineIncludes(),
       _onLog = onLog,
       _host = ScriptHost(world, values: values, onLog: onLog);

  final World world;

  /// Where built libraries go. Somewhere disposable — nothing here is a build
  /// artefact worth keeping, and every rebuild leaves the last one behind.
  final Directory build;

  /// Null when nothing on this machine can compile C++, which is a thing to
  /// say plainly rather than to fail at the first script.
  final Toolchain? toolchain;

  final List<String> includes;
  final void Function(String)? _onLog;
  final ScriptHost _host;

  final Map<String, _Loaded> _scripts = {};
  final List<StreamSubscription<FileSystemEvent>> _watches = [];

  bool get canCompile => toolchain != null;

  List<ScriptStatus> get scripts => [
    for (final loaded in _scripts.values)
      ScriptStatus(
        name: loaded.name,
        source: loaded.source,
        running: loaded.script?.isRunning ?? false,
        output: loaded.output,
        revision: loaded.revision,
      ),
  ];

  /// The headers a script is compiled against.
  ///
  /// Resolved from the packages themselves rather than configured, so a script
  /// compiles without anybody being asked where the engine is. This needs a
  /// package config, which an editor and a test have and a shipped game does
  /// not — a shipped game runs scripts that were compiled before it shipped.
  static List<String> engineIncludes() {
    final said = Platform.environment['ORBIS_INCLUDE'];
    if (said != null && said.isNotEmpty) {
      return said.split(Platform.isWindows ? ';' : ':');
    }

    final fromConfig = _fromPackageConfig();
    if (fromConfig.isNotEmpty) return fromConfig;

    return _fromIsolate();
  }

  /// The packages whose `include` folders a script is compiled against.
  static const _packages = ['orbis_native', 'orbis_core'];

  /// Read out of the running build's own package config.
  ///
  /// Walked up from the working directory, which is the package root when
  /// anything is run from source and under test. This is first because it is
  /// the one that works everywhere the other does not: Flutter's isolate does
  /// not implement resolvePackageUriSync at all.
  static List<String> _fromPackageConfig() {
    File? config;
    for (var at = Directory.current; ; at = at.parent) {
      final candidate = File(
        '${at.path}${Platform.pathSeparator}.dart_tool'
        '${Platform.pathSeparator}package_config.json',
      );
      if (candidate.existsSync()) {
        config = candidate;
        break;
      }
      if (at.parent.path == at.path) break;
    }
    if (config == null) return const [];

    final Object? parsed;
    try {
      parsed = jsonDecode(config.readAsStringSync());
    } on Object {
      return const [];
    }
    if (parsed is! Map<String, Object?>) return const [];

    final listed = parsed['packages'];
    if (listed is! List) return const [];

    final found = <String>[];
    for (final entry in listed) {
      if (entry is! Map<String, Object?>) continue;
      if (!_packages.contains(entry['name'])) continue;

      final root = entry['rootUri'];
      if (root is! String) continue;

      final resolved = config.uri.resolve(root.endsWith('/') ? root : '$root/');
      final include = resolved.resolve('include/');
      if (Directory.fromUri(include).existsSync()) {
        found.add(include.toFilePath());
      }
    }
    return found;
  }

  static List<String> _fromIsolate() {
    try {
      return [
        for (final package in _packages)
          if (Isolate.resolvePackageUriSync(
                Uri.parse('package:$package/$package.dart'),
              )
              case final resolved?)
            resolved.resolve('../include/').toFilePath(),
      ];
    } on Object {
      // Not supported under Flutter, and a shipped app has no package config
      // either. ORBIS_INCLUDE is the answer for both.
      return const [];
    }
  }

  /// Builds a source file, loads what comes out, and starts it.
  ///
  /// Returns what the compiler said. A script already loaded under the same
  /// name is replaced, which is what a rebuild is.
  BuildResult add(File source) {
    final tools = toolchain;
    if (tools == null) {
      return BuildResult(
        library: null,
        output:
            'No C++ compiler found. Install the Xcode command line tools, '
            'or clang, or gcc.',
        command: '',
      );
    }

    final name = source.uri.pathSegments.last.split('.').first;
    final existing = _scripts[name];
    final revision = (existing?.revision ?? -1) + 1;

    final built = tools.compile(
      source,
      into: build,
      includes: includes,
      revision: revision,
    );

    // Kept listed with the compiler's complaint against it. Dropping it would
    // lose the one thing somebody needs to fix it.
    if (!built.ok) {
      _scripts[name] = _Loaded(
        name: name,
        source: source,
        script: existing?.script,
        revision: revision,
        output: built.output,
      );
      return built;
    }

    final NativeScript loaded;
    try {
      loaded = NativeScript.open(built.library!);
    } on ScriptError catch (error) {
      _scripts[name] = _Loaded(
        name: name,
        source: source,
        script: existing?.script,
        revision: revision,
        output: error.message,
      );
      return BuildResult(
        library: null,
        output: error.message,
        command: built.command,
      );
    }

    // The old one goes only once the new one has loaded, so a script that
    // fails to load leaves the working version running rather than leaving
    // nothing running. Closed rather than stopped: its code is unloaded and
    // its file deleted, or an afternoon of saving leaks a library a save.
    existing?.script?.close();

    loaded.start(_host);
    _scripts[name] = _Loaded(
      name: name,
      source: source,
      script: loaded,
      revision: revision,
      output: built.output,
    );
    return built;
  }

  /// Steps every script that is running.
  ///
  /// In the order they were added. A script that throws is not something C++
  /// can tell us about, so there is nothing to catch here — what a script does
  /// to the process is the script's own business, and that is the trade for
  /// running native code.
  void step(double delta) {
    // Once a frame, and only when something has actually changed: a script
    // reading a value through its address needs the address to hold the
    // current value, and this is the one place that can be true without a
    // call per read.
    _host.refresh();

    for (final loaded in _scripts.values) {
      loaded.script?.step(delta);
    }
  }

  /// Stops one, unloads it and forgets it.
  void remove(String name) {
    _scripts.remove(name)?.script?.close();
  }

  /// Rebuilds a script whenever its source is written.
  ///
  /// Coalesced: a save from an editor is often several events, and building
  /// three times for one save is three seconds of somebody's attention.
  void watch(File source, {void Function(BuildResult)? onBuilt}) {
    Timer? settle;
    final watch = source.parent.watch().listen((event) {
      if (!_sameFile(event.path, source.path)) return;
      settle?.cancel();
      settle = Timer(const Duration(milliseconds: 150), () {
        if (!source.existsSync()) return;
        final built = add(source);
        _onLog?.call(
          built.ok
              ? 'Rebuilt ${source.uri.pathSegments.last}.'
              : 'Could not build ${source.uri.pathSegments.last}:\n'
                    '${built.output}',
        );
        onBuilt?.call(built);
      });
    });
    _watches.add(watch);
  }

  static bool _sameFile(String a, String b) =>
      a == b ||
      a.split(Platform.pathSeparator).last ==
          b.split(Platform.pathSeparator).last;

  /// Stops everything and frees the table.
  void dispose() {
    for (final watch in _watches) {
      watch.cancel();
    }
    _watches.clear();
    for (final loaded in _scripts.values) {
      loaded.script?.close();
    }
    _scripts.clear();
    // After every script has stopped: the table is what they were holding.
    _host.dispose();
  }
}

class _Loaded {
  _Loaded({
    required this.name,
    required this.source,
    required this.script,
    required this.revision,
    required this.output,
  });

  final String name;
  final File source;
  final NativeScript? script;
  final int revision;
  final String output;
}
