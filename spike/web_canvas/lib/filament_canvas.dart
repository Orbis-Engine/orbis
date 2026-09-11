// The Dart half of the canvas: puts a <canvas> into the widget tree as a
// platform view, and talks to the JavaScript renderer that draws into it with
// Filament (web/orbis_filament_view.js).
//
// Everything that crosses goes through dart:js_interop, and the scene crosses
// as bytes (scene_message.dart); Dart never holds a Filament object. That
// keeps the boundary the shape the native renderer already has, where Dart
// hands C++ a scene message over the C ABI, so this side would stay the same
// whichever web route README.md settles on.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:web/web.dart' as web;

import 'scene_message.dart';

/// The platform view type the canvas is registered under.
const String filamentViewType = 'orbis-filament-canvas';

@JS('orbisWeb.mount')
external JSPromise<_JsRenderer> _mount(web.HTMLCanvasElement canvas);

/// What orbisWeb.mount resolves to: one renderer per canvas.
extension type _JsRenderer._(JSObject _) implements JSObject {
  external void apply(JSUint8Array message);
  external _JsStats stats();
  external void destroy();
}

extension type _JsStats._(JSObject _) implements JSObject {
  external int get frames;
  external int get messages;
  external String get backend;
  external int get activeFeatureLevel;
  external int get supportedFeatureLevel;
  external String get glVersion;
  external String get glRenderer;
  external int get width;
  external int get height;
}

/// Canvases being mounted, by platform view id. The factory runs inside the
/// engine, away from any widget, so the widget collects its canvas here.
final Map<int, Completer<FilamentCanvas>> _mounting = {};

/// Registers the canvas factory with the engine's platform view registry.
/// Call once, before runApp.
void registerFilamentCanvas() {
  ui_web.platformViewRegistry.registerViewFactory(filamentViewType, (
    int viewId,
  ) {
    final canvas = web.HTMLCanvasElement()..id = 'orbis-filament-$viewId';
    // Flutter sizes the platform view's box; the canvas fills it, and the
    // renderer matches its drawing buffer to that size each frame.
    canvas.style
      ..width = '100%'
      ..height = '100%'
      ..display = 'block';
    final mounted = _mounting.putIfAbsent(viewId, Completer.new);
    _mount(canvas).toDart.then(
      (renderer) => mounted.complete(FilamentCanvas._(viewId, renderer)),
      onError: mounted.completeError,
    );
    return canvas;
  });
}

/// What the renderer reports back: read by polling, for the on-screen stats.
typedef FilamentStats = ({
  int frames,
  int messages,
  String backend,
  int activeFeatureLevel,
  int supportedFeatureLevel,
  String glVersion,
  String glRenderer,
  int width,
  int height,
});

/// A mounted canvas: the Dart handle on one JavaScript renderer.
class FilamentCanvas {
  FilamentCanvas._(this._viewId, this._renderer);

  final int _viewId;
  final _JsRenderer _renderer;

  /// Completes when the canvas behind platform view [viewId] is drawing.
  static Future<FilamentCanvas> forView(int viewId) =>
      _mounting.putIfAbsent(viewId, Completer.new).future;

  /// Sends one scene message. Compiled to JavaScript (the default build) the
  /// bytes cross without a copy, a Dart Uint8List being a JavaScript
  /// Uint8Array; compiled to WebAssembly (--wasm), toJS copies them.
  void send(SceneMessage message) => _renderer.apply(message.encode().toJS);

  FilamentStats get stats {
    final s = _renderer.stats();
    return (
      frames: s.frames,
      messages: s.messages,
      backend: s.backend,
      activeFeatureLevel: s.activeFeatureLevel,
      supportedFeatureLevel: s.supportedFeatureLevel,
      glVersion: s.glVersion,
      glRenderer: s.glRenderer,
      width: s.width,
      height: s.height,
    );
  }

  /// Tears the Filament side down. Flutter does not tell a platform view's
  /// element that it has left the page, so the widget that owns the canvas
  /// has to say so.
  void dispose() {
    _mounting.remove(_viewId);
    _renderer.destroy();
  }
}
