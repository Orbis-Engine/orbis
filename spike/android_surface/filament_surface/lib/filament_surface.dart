import 'package:flutter/services.dart';

/// Which Filament backend to start the native engine with.
enum FilamentBackend {
  openGL,
  vulkan;

  String get wireName => this == FilamentBackend.vulkan ? 'vulkan' : 'opengl';
}

/// Thin Dart wrapper over the `filament_surface` method channel.
///
/// Deliberately not the federated plugin_platform_interface shape: this spike
/// has exactly one platform, so the indirection a multi-platform plugin needs
/// would be ceremony with nothing on the other side of it. A real Orbis
/// plugin serving iOS, Android, Linux and Windows from one Dart API is where
/// that pattern earns its keep.
///
/// One session at a time, matching the native side -- see
/// FilamentSurfaceSession.kt. No per-frame call crosses this channel; the
/// render loop is entirely native, driven by Choreographer. What crosses here
/// is control (start/stop/resize/recreateSurface) and polled diagnostics
/// (describe/stats), both cheap and infrequent.
class FilamentSurface {
  FilamentSurface._();

  static const MethodChannel _channel = MethodChannel('filament_surface');

  /// Starts a session on [backend] at [width]x[height] texture pixels.
  /// Stops any session already running first -- see the plugin's `start`.
  ///
  /// Returns what `describe()` would: textureId and the rest. Throws
  /// [PlatformException] if Filament would not start on this backend at all
  /// (no engine), which is a different failure from a black texture.
  static Future<Map<String, Object?>> start({
    required FilamentBackend backend,
    int width = 720,
    int height = 720,
  }) async {
    final result = await _channel.invokeMapMethod<String, Object?>('start', {
      'backend': backend.wireName,
      'width': width,
      'height': height,
    });
    return result ?? const {};
  }

  static Future<void> stop() => _channel.invokeMethod<void>('stop');

  static Future<Map<String, Object?>> resize(int width, int height) async {
    final result = await _channel.invokeMapMethod<String, Object?>('resize', {
      'width': width,
      'height': height,
    });
    return result ?? const {};
  }

  /// Forces the surface-loss-and-recreate path Android takes on
  /// backgrounding, on demand, so the lifecycle can be exercised from a
  /// button instead of only by backgrounding the app for real.
  static Future<Map<String, Object?>> recreateSurface() async {
    final result = await _channel.invokeMapMethod<String, Object?>('recreateSurface');
    return result ?? const {};
  }

  /// Backend, feature levels, size, and surface-lifecycle counters.
  static Future<Map<String, Object?>> describe() async {
    final result = await _channel.invokeMapMethod<String, Object?>('describe');
    return result ?? const {};
  }

  /// Rendered/skipped frame counts and interval timing.
  static Future<Map<String, Object?>> stats() async {
    final result = await _channel.invokeMapMethod<String, Object?>('stats');
    return result ?? const {};
  }
}
