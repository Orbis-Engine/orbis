// Stand-ins for the handful of `dart:io` names the examples use, for the web.
//
// Only what those seven files actually touch, and each answers the way an
// empty filesystem would rather than throwing: a browser has no path to give
// the renderer, and an example whose texture is a file is expected to show
// its untextured self there, not to bring the gallery down.
//
// `Platform.environment` is the exception, and is not empty: the gallery
// carries its `ORBIS_*` switches in the query string on the web (see
// examples/gallery/lib/orbis_env_web.dart), so the four examples that read
// the environment directly — ORBIS_DETAIL, ORBIS_VIDEO, ORBIS_MESH,
// ORBIS_BISTRO — keep working from a URL exactly as they do from a shell.
library;

import 'dart:typed_data';

/// What a browser can say about its environment.
abstract final class Platform {
  /// The query string, as environment variables.
  ///
  /// `?ORBIS_EXAMPLE=Lights&ORBIS_DETAIL=high` is the web's spelling of
  /// `ORBIS_EXAMPLE=Lights ORBIS_DETAIL=high flutter run`.
  static Map<String, String> get environment => Uri.base.queryParameters;

  static bool get isWindows => false;
  static bool get isMacOS => false;
  static bool get isIOS => false;
  static bool get isAndroid => false;
  static bool get isLinux => false;
}

/// A file that is never there.
class File {
  File(this.path);

  final String path;

  /// Always false: there is no filesystem to look in. Every caller of this
  /// already has a "then there is no model/film/map" branch, because a path
  /// that does not exist is the ordinary case on the other platforms too.
  bool existsSync() => false;

  File get absolute => this;

  String readAsStringSync() => '';

  Future<File> writeAsBytes(
    List<int> bytes, {
    bool flush = false,
  }) async => this;

  Future<Uint8List> readAsBytes() async => Uint8List(0);
}

/// A directory that cannot be made.
class Directory {
  Directory(this.path);

  final String path;

  /// Somewhere to put a file that will not be written anyway.
  static Directory get systemTemp => Directory('/tmp');

  bool existsSync() => false;

  Future<Directory> create({bool recursive = false}) async => this;
}
