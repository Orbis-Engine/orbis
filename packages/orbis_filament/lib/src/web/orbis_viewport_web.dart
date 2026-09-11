// One renderer drawing into one <canvas> — the web's OrbisViewport.kt.
//
// The shape is forced by how a Flutter web platform view actually arrives,
// which is not how a texture does. On Apple and Android `create` can build the
// renderer there and then, because the texture registry hands out a surface
// synchronously. Here the canvas does not exist yet when `create` is answered:
// it is made later, by the view factory, when the widget carrying the
// `HtmlElementView` is built — and even then it is detached from the document,
// with no size, until Flutter has laid it out.
//
// So `create` mints an id and nothing else, and everything real happens once
// the canvas is both attached and measured. A scene that arrives before then
// is held (`_pending`) and applied the moment the renderer starts, which is
// what makes a static scene set before the first layout still appear — the
// same guarantee `_sync` gives on the other platforms by awaiting `create`.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'orbis_module.dart';
import 'orbis_scene_web.dart';

/// WebGL 2, which is the only backend this build's materials were compiled
/// for. `OrbisBackend` in orbis_renderer.h: 3 is OPENGL.
const int _backendOpenGl = 3;

/// One viewport: a canvas, a module instance, and the frame loop over them.
class OrbisWebViewport {
  OrbisWebViewport(this.id);

  /// This viewport's number — the "textureId" of the channel contract, minted
  /// by the plugin rather than by a texture registry.
  final int id;

  /// The element id the canvas is given, and the CSS selector the renderer is
  /// handed. `OrbisSurfaceWeb.cpp` keeps that selector for the swap chain's
  /// whole life and Filament's `PlatformWebGL` carries it as an opaque
  /// identity, so it has to stay unique per canvas and stay valid.
  String get elementId => 'orbis-filament-$id';

  web.HTMLCanvasElement? _canvas;
  OrbisModule? _module;
  int _renderer = 0;
  bool _starting = false;
  bool _disposed = false;

  /// The size the host last asked for, in physical pixels.
  int _width = 1;
  int _height = 1;

  /// What the canvas's backing store currently is, so the renderer is only
  /// told about a size that actually moved.
  int _backingWidth = 0;
  int _backingHeight = 0;

  double? _startedAt;

  /// A scene that arrived before the renderer existed, applied at start.
  OrbisSceneWeb? _pending;

  /// The notes from the last scene applied, as `setScene` answers with.
  Map<String, String> _notes = const {};

  bool get isRunning => _renderer != 0;

  /// Makes the canvas this viewport draws into. Called by the view factory,
  /// which runs inside the engine with the element still detached — so this
  /// only builds the element and starts watching for it to be laid out.
  web.HTMLCanvasElement createCanvas() {
    final canvas = web.document.createElement('canvas') as web.HTMLCanvasElement
      ..id = elementId;
    // Flutter sizes the platform view's box; the canvas fills it. Its
    // backing store is a separate matter entirely — see _fitBackingStore.
    canvas.style
      ..width = '100%'
      ..height = '100%'
      ..display = 'block';
    _canvas = canvas;
    _whenLaidOut();
    return canvas;
  }

  /// Polls with `requestAnimationFrame` until the canvas is actually in the
  /// document and has a size, then starts the renderer.
  ///
  /// A platform view's element is detached when the factory returns it, and
  /// `Engine::create` needs a canvas it can find by selector — the swap chain
  /// is built from `document.querySelector(selector)` on Filament's side. A
  /// renderer built against a detached or zero-sized canvas either fails to
  /// start or starts at the HTML default 300x150 and never corrects.
  void _whenLaidOut() {
    if (_disposed) return;
    final canvas = _canvas;
    if (canvas == null) return;
    if (canvas.isConnected && canvas.clientWidth > 0 && canvas.clientHeight > 0) {
      unawaited(_start());
      return;
    }
    web.window.requestAnimationFrame((JSNumber _) {
      _whenLaidOut();
    }.toJS);
  }

  Future<void> _start() async {
    if (_disposed || _starting || _renderer != 0) return;
    _starting = true;
    final canvas = _canvas;
    if (canvas == null) return;
    try {
      _fitBackingStore();
      // One module instance per canvas: Emscripten's GL emulation binds its
      // WebGL context to whatever `Module.canvas` was, so two viewports need
      // two instances rather than one shared one.
      final module = await loadOrbisModule(canvas);
      if (_disposed) return;
      _module = module;

      // Straight through orbis_web_create_on_canvas, which makes the WebGL 2
      // context current before calling the unmodified orbis_renderer_create —
      // nothing else in this build creates one (see orbis_web_host.cpp).
      final heap = OrbisHeap(module);
      try {
        _renderer = orbisCall(module, 'orbis_web_create_on_canvas', [
          _backendOpenGl,
          heap.string('#$elementId'),
          _backingWidth,
          _backingHeight,
        ]);
      } finally {
        heap.free();
      }
      if (_renderer == 0) {
        web.console.error(
          '[orbis] the renderer would not start on #$elementId — see the '
                  'console for what Filament refused and why.'
              .toJS,
        );
        return;
      }

      final pending = _pending;
      _pending = null;
      if (pending != null) applyScene(pending);

      web.window.requestAnimationFrame(_frame.toJS);
    } finally {
      _starting = false;
    }
  }

  /// Matches the canvas's backing store to its laid-out size.
  ///
  /// Flutter resizes the platform view's CSS box and never touches the
  /// element's `width`/`height` attributes, which are what WebGL actually
  /// draws into. Left alone they stay at the HTML default of 300x150 however
  /// large the view is on screen, so this is checked every frame rather than
  /// only when the host calls `resize`.
  bool _fitBackingStore() {
    final canvas = _canvas;
    if (canvas == null) return false;
    final ratio = web.window.devicePixelRatio;
    var width = (canvas.clientWidth * ratio).round();
    var height = (canvas.clientHeight * ratio).round();
    // Before layout there is nothing to measure; fall back to what the host
    // asked for rather than to the HTML default.
    if (width <= 0 || height <= 0) {
      width = _width;
      height = _height;
    }
    if (width == _backingWidth && height == _backingHeight) return false;
    _backingWidth = width;
    _backingHeight = height;
    canvas.width = width;
    canvas.height = height;
    return true;
  }

  void _frame(JSNumber timestamp) {
    if (_disposed || _renderer == 0) return;
    final module = _module;
    if (module == null) return;

    if (_fitBackingStore()) {
      orbisCall(module, 'orbis_renderer_resize', [
        _renderer,
        _backingWidth,
        _backingHeight,
      ]);
    }

    // Seconds since this viewport's first frame, the same quantity Android's
    // Choreographer delta and Apple's CFAbsoluteTimeGetCurrent offset are.
    // A scene's own animation rides on the camera's `at` instead.
    final now = timestamp.toDartDouble / 1000.0;
    _startedAt ??= now;
    orbisCall(module, 'orbis_renderer_draw', [_renderer, now - _startedAt!]);

    web.window.requestAnimationFrame(_frame.toJS);
  }

  /// The host's requested size, in physical pixels. The canvas's own laid-out
  /// size still wins each frame; this only matters before the first layout.
  void resize(int width, int height) {
    if (width <= 0 || height <= 0) return;
    _width = width;
    _height = height;
  }

  /// Applies a scene, or holds it until the renderer exists.
  Map<String, String> applyScene(OrbisSceneWeb scene) {
    final module = _module;
    if (_renderer == 0 || module == null) {
      _pending = scene;
      return const {};
    }
    scene.applyTo(module, _renderer);
    final was = _notes;
    _notes = _readNotes(module);
    // Only when they change. A scene is published on every frame of an
    // animation, and a note that is still true sixty times a second says
    // nothing the first one did not — it only buries everything else in the
    // console, including the refusals above.
    if (!_sameNotes(was, _notes)) {
      for (final note in _notes.entries) {
        // The same mechanism every other host reads a refusal through, said
        // where a browser capture records it beside the frame.
        web.console.warn('[orbis] [${note.key}] ${note.value}'.toJS);
      }
    }
    return _notes;
  }

  /// What the scene asked for that could not be given, through the same
  /// `orbis_renderer_notes`/`orbis_renderer_note` pair every other host reads
  /// it through.
  Map<String, String> _readNotes(OrbisModule module) {
    final count = orbisCall(module, 'orbis_renderer_notes', [_renderer]);
    if (count <= 0) return const {};
    final notes = <String, String>{};
    final heap = OrbisHeap(module);
    try {
      // Two `const char *` out-parameters, side by side.
      final out = heap.ints(const [0, 0]);
      for (var i = 0; i < count; i++) {
        final ok = orbisCall(module, 'orbis_renderer_note', [
          _renderer,
          i,
          out,
          out + 4,
        ]);
        if (ok != 0) continue;
        final heapU32 = module.HEAPU32.toDart;
        final about = module.UTF8ToString(heapU32[out >> 2]);
        final saying = module.UTF8ToString(heapU32[(out >> 2) + 1]);
        notes[about] = saying;
      }
    } finally {
      heap.free();
    }
    return notes;
  }

  /// Whether two snapshots of the notes say the same thing.
  static bool _sameNotes(Map<String, String> before, Map<String, String> now) {
    if (before.length != now.length) return false;
    for (final note in before.entries) {
      if (now[note.key] != note.value) return false;
    }
    return true;
  }

  /// The same three numbers `stats` answers with everywhere else.
  Map<String, Object?> stats() {
    final module = _module;
    if (_renderer == 0 || module == null) return const {};
    final heap = OrbisHeap(module);
    try {
      // orbis_stats: two doubles then three uint32s. Read through the heap
      // rather than by a per-field accessor, because the ABI hands the whole
      // struct back at once.
      final stats = heap.ints(const [0, 0, 0, 0, 0, 0, 0]);
      final ok = orbisCall(module, 'orbis_renderer_stats', [_renderer, stats]);
      if (ok != 0) return const {};
      final bytes = module.HEAPU8.toDart;
      final view = bytes.buffer.asByteData(bytes.offsetInBytes + stats);
      final gpu = view.getFloat64(0, Endian.little);
      final batched = view.getUint32(16, Endian.little);
      final groups = view.getUint32(20, Endian.little);
      final passCount = view.getUint32(24, Endian.little);

      final timings = <double>[];
      if (passCount > 0) {
        final milliseconds = heap.ints(List<int>.filled(passCount * 2, 0));
        final drawn = heap.ints(List<int>.filled(passCount, 0));
        final got = orbisCall(module, 'orbis_renderer_pass_timings', [
          _renderer,
          milliseconds,
          drawn,
          passCount,
        ]);
        final heapU8 = module.HEAPU8.toDart;
        final ms = heapU8.buffer.asByteData(heapU8.offsetInBytes + milliseconds);
        final dr = heapU8.buffer.asByteData(heapU8.offsetInBytes + drawn);
        for (var i = 0; i < got; i++) {
          timings
            ..add(ms.getFloat64(i * 8, Endian.little))
            ..add(dr.getInt32(i * 4, Endian.little).toDouble());
        }
      }

      return {
        'gpuMilliseconds': gpu,
        'passTimings': timings,
        'batching': [batched, groups],
      };
    } finally {
      heap.free();
    }
  }

  void dispose() {
    _disposed = true;
    final module = _module;
    if (module != null && _renderer != 0) {
      orbisCall(module, 'orbis_renderer_destroy', [_renderer]);
    }
    _renderer = 0;
    _module = null;
    // Flutter removes the platform view's own element; the canvas goes with
    // it. Dropping the reference is all this side owes.
    _canvas = null;
  }
}
