import 'dart:io';

/// What happened when a script was compiled.
///
/// The output is kept whether it worked or not: a warning is worth showing on
/// a build that succeeded, and an error is the whole point of one that did
/// not. An editor puts this in a console; a test reads it.
class BuildResult {
  const BuildResult({
    required this.library,
    required this.output,
    required this.command,
  });

  /// The library that was built, or null when it was not.
  final File? library;

  /// Everything the compiler said, both streams, in the order it said it.
  final String output;

  /// The command that was run, so a build that fails in a way nobody expected
  /// can be reproduced in a terminal rather than guessed at.
  final String command;

  bool get ok => library != null;
}

/// A C++ compiler, and what to do with it.
///
/// Found rather than configured. Somebody who has written a `.cpp` has a
/// compiler, and asking them to say where it is before their script will run
/// is asking a question the machine can answer.
class Toolchain {
  const Toolchain({required this.compiler, required this.extraFlags});

  /// The compiler executable.
  final String compiler;

  /// Flags this particular compiler needs beyond the common ones.
  final List<String> extraFlags;

  /// The first compiler on the PATH, or null.
  ///
  /// clang first because it is what macOS ships and what the engine itself is
  /// built with, so a script and the core disagree about the C++ runtime as
  /// rarely as possible. On Windows that means `clang-cl` before plain
  /// `clang++`: `clang-cl` speaks MSVC's command line and finds an installed
  /// Visual Studio's headers and libraries the way `cl.exe` would, where
  /// `clang++` on Windows only links cleanly against a MinGW-style
  /// environment that a machine with Visual Studio alone does not have.
  /// `cl` itself is the last resort, for a machine with Visual Studio and no
  /// LLVM.
  static Toolchain? find({List<String>? candidates}) {
    final tried =
        candidates ??
        (Platform.isWindows
            ? const ['clang-cl', 'clang++', 'cl']
            : const ['clang++', 'c++', 'g++']);
    for (final candidate in tried) {
      if (!_onPath(candidate)) continue;
      // clang-cl and cl both take MSVC's command line; compile() spells the
      // arguments accordingly for either.
      final msvc = candidate == 'clang-cl' || candidate == 'cl';
      return Toolchain(
        compiler: candidate,
        extraFlags: msvc
            // /LD: build a DLL. There is no separate "undefined symbol"
            // stance to take here the way -undefined error takes one on
            // macOS — the MSVC linker already refuses an unresolved symbol
            // by default.
            ? const ['/LD']
            : Platform.isMacOS
            // A dylib, and one whose install name is its own path, so the
            // loader does not go looking for it beside the executable.
            ? const ['-dynamiclib', '-undefined', 'error']
            : const ['-shared', '-fPIC'],
      );
    }
    return null;
  }

  static bool _onPath(String command) {
    try {
      return Process.runSync(Platform.isWindows ? 'where' : 'which', [
            command,
          ]).exitCode ==
          0;
    } on ProcessException {
      return false;
    }
  }

  /// What a loadable library is called here.
  static String get librarySuffix =>
      Platform.isMacOS ? '.dylib' : (Platform.isWindows ? '.dll' : '.so');

  /// Compiles one source file into a loadable library.
  ///
  /// [into] is a *directory*, and the name is chosen here rather than by the
  /// caller. Every build goes to a file of its own: `dart:ffi` has no way to
  /// close a library, so opening the same path twice gives back the image
  /// already loaded and a rebuilt script would go on running the old code. A
  /// new path is the only reliable way to load new code, and it costs a file.
  BuildResult compile(
    File source, {
    required Directory into,
    required List<String> includes,
    int revision = 0,
    List<String> flags = const [],
  }) {
    final name = source.uri.pathSegments.last.split('.').first;
    final target = File(
      '${into.path}${Platform.pathSeparator}'
      '$name.$revision$librarySuffix',
    );

    // clang-cl and cl take MSVC's command line, not clang's own — a
    // different spelling for every flag below, not just the ones in
    // extraFlags.
    final msvc = compiler == 'clang-cl' || compiler == 'cl';
    final arguments = msvc
        ? <String>[
            // The banner clang-cl and cl both print unasked, which would
            // otherwise be the first line of "what the compiler said"
            // whether it had anything to say or not.
            '/nologo',
            ...extraFlags,
            '/std:c++17',
            // On by default: a script is somebody's gameplay loop, and the
            // point of writing it in C++ was that it is fast.
            '/O2',
            // The standard exception model. Without it a throw in a script
            // is undefined behaviour rather than a stack unwind.
            '/EHsc',
            for (final include in includes) '/I$include',
            ...flags,
            source.path,
            '/Fe:${target.path}',
            // Otherwise the object file lands beside the source — which may
            // be a project's asset folder, not somewhere this owns.
            '/Fo:${target.path}.obj',
          ]
        : <String>[
            ...extraFlags,
            '-std=c++17',
            // On by default: a script is somebody's gameplay loop, and the
            // point of writing it in C++ was that it is fast.
            '-O2',
            // Position-independent everywhere, which a loadable library must
            // be.
            '-fPIC',
            for (final include in includes) ...['-I', include],
            ...flags,
            source.path,
            '-o',
            target.path,
          ];

    into.createSync(recursive: true);

    final ProcessResult run;
    try {
      run = Process.runSync(compiler, arguments);
    } on ProcessException catch (error) {
      return BuildResult(
        library: null,
        output: 'Could not run $compiler: ${error.message}',
        command: '$compiler ${arguments.join(' ')}',
      );
    }

    final said = [
      if ('${run.stdout}'.trim().isNotEmpty) '${run.stdout}'.trim(),
      if ('${run.stderr}'.trim().isNotEmpty) '${run.stderr}'.trim(),
    ].join('\n');

    return BuildResult(
      // The exit code decides, not whether the file exists: a compiler that
      // failed part way can leave a truncated object behind, and loading one
      // of those is a crash rather than an error message.
      library: run.exitCode == 0 && target.existsSync() ? target : null,
      output: said,
      command: '$compiler ${arguments.join(' ')}',
    );
  }
}
