// The web's `orbis_filament` plugin: the same channel, the same methods, the
// same wire shapes as OrbisFilamentPlugin.swift and OrbisFilamentPlugin.kt, so
// `lib/src/orbis_view.dart` and every other Dart caller work unchanged.
//
// One [OrbisWebViewport] per `create`d id, keyed by that id — `_viewports`
// here is exactly `viewports` on the other two sides. What differs is where
// the id comes from and what it means: there is no texture registry on the
// web and no external texture for Flutter to composite, so the id is minted
// here and names a `<canvas>` shown through an `HtmlElementView` instead.
//
// Registered by Flutter's own web plugin mechanism — `pubspec.yaml`'s
// `platforms: web: pluginClass: OrbisFilamentWeb` makes the generated
// registrant call [registerWith] before `runApp`.
library;

import 'package:flutter/services.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'dart:ui_web' as ui_web;

import '../web_view_type.dart';
import 'orbis_module.dart';
import 'orbis_scene_web.dart';
import 'orbis_viewport_web.dart';

/// The web implementation of the `orbis_filament` plugin.
class OrbisFilamentWeb {
  OrbisFilamentWeb._();

  static final OrbisFilamentWeb _instance = OrbisFilamentWeb._();

  final Map<int, OrbisWebViewport> _viewports = {};

  /// Ids are minted here rather than by a texture registry. Starting above
  /// zero keeps "no viewport" spellable as 0, as it is on the other sides.
  int _nextId = 1;

  /// Called by Flutter's generated web registrant before `runApp`.
  static void registerWith(Registrar registrar) {
    final channel = MethodChannel(
      'orbis_filament',
      const StandardMethodCodec(),
      registrar,
    );
    channel.setMethodCallHandler(_instance._handle);

    // One factory for every viewport. Which viewport a canvas belongs to
    // arrives as the view's creation params — the id `create` answered with
    // — rather than as the platform view's own id, which Flutter mints
    // separately and this side never sees.
    ui_web.platformViewRegistry.registerViewFactory(orbisWebViewType, (
      int viewId, {
      Object? params,
    }) {
      final id = params is int ? params : -1;
      final viewport = _instance._viewports[id];
      if (viewport == null) {
        // A view built for a viewport that has already gone. An empty canvas
        // is the honest answer: the widget is about to be taken down anyway,
        // and returning nothing at all would fail the platform view instead.
        return OrbisWebViewport(-1).createCanvas();
      }
      return viewport.createCanvas();
    });
  }

  Future<Object?> _handle(MethodCall call) async {
    switch (call.method) {
      case 'create':
        final args = call.arguments as Map?;
        final width = (args?['width'] as num?)?.round();
        final height = (args?['height'] as num?)?.round();
        if (width == null || height == null) {
          throw PlatformException(
            code: 'bad-args',
            message: 'create needs width and height',
          );
        }
        if (!orbisRendererScriptLoaded) {
          throw PlatformException(
            code: 'no-renderer',
            message:
                'orbis_renderer.js is not loaded. Add '
                '<script src="orbis_renderer.js"></script> to web/index.html '
                'and copy orbis_renderer.js and orbis_renderer.wasm into the '
                "app's web/ directory — see "
                'packages/orbis_filament/native/web/README.md.',
          );
        }
        // The renderer itself cannot start yet: its canvas does not exist
        // until the widget carrying this id builds its HtmlElementView, and
        // is not laid out until a frame after that. See OrbisWebViewport.
        final id = _nextId++;
        _viewports[id] = OrbisWebViewport(id)..resize(width, height);
        return id;

      case 'resize':
        final args = call.arguments as Map?;
        final id = (args?['textureId'] as num?)?.toInt();
        final width = (args?['width'] as num?)?.round();
        final height = (args?['height'] as num?)?.round();
        if (id == null || width == null || height == null) {
          throw PlatformException(
            code: 'bad-args',
            message: 'resize needs textureId, width, height',
          );
        }
        _viewports[id]?.resize(width, height);
        return null;

      case 'setScene':
        final args = call.arguments as Map?;
        final id = (args?['textureId'] as num?)?.toInt();
        if (args == null || id == null) {
          throw PlatformException(
            code: 'bad-args',
            message: 'setScene needs a textureId',
          );
        }
        final scene = OrbisSceneWeb.from(args);
        if (scene == null) {
          throw PlatformException(
            code: 'bad-scene',
            message:
                'setScene needs keys, float32 transforms (16 each), colours '
                '(3 each), flags, lights (16 floats each), fog (10 floats) '
                'and a camera.',
          );
        }
        final viewport = _viewports[id];
        if (viewport == null) return null;
        return viewport.applyScene(scene);

      case 'stats':
        final args = call.arguments as Map?;
        final id = (args?['textureId'] as num?)?.toInt();
        final viewport = id == null ? null : _viewports[id];
        if (viewport == null) return null;
        return viewport.stats();

      case 'dispose':
        final args = call.arguments as Map?;
        final id = (args?['textureId'] as num?)?.toInt();
        if (id == null) {
          throw PlatformException(
            code: 'bad-args',
            message: 'dispose needs textureId',
          );
        }
        _viewports.remove(id)?.dispose();
        return null;

      default:
        throw PlatformException(
          code: 'not-implemented',
          message: 'orbis_filament has no web implementation of ${call.method}',
        );
    }
  }
}
