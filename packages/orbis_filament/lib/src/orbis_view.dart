import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'graph.dart';
import 'scene.dart';
import 'web_view_type.dart';

/// A Filament-rendered surface, laid out and composited like any other widget.
///
/// The 3D content is a real Flutter texture, so it clips, scrolls, sits under
/// other widgets and takes part in layout the way a [Container] does. That is
/// the whole point of routing Filament through the texture registry rather
/// than a platform view.
class OrbisView extends StatefulWidget {
  const OrbisView({super.key, this.scene, this.onSceneNotes, this.onViewport});

  /// What to draw. While this is null the renderer shows its own placeholder,
  /// so an unconfigured view is visibly working rather than merely blank.
  final OrbisScene? scene;

  /// Called with anything the scene asked for that could not be given: a mesh
  /// file that would not load, a light the view has no room to shade. Subject
  /// to reason, so a host can say which rather than that something went
  /// wrong.
  final ValueChanged<Map<String, String>>? onSceneNotes;

  /// Called once with this view's own number, when the renderer has one.
  ///
  /// What it is for is asking after the view later — [gpuMilliseconds] wants
  /// to know which viewport is being asked about, and only the view knows.
  final ValueChanged<int>? onViewport;

  /// What a frame usually costs the GPU in this viewport, in milliseconds.
  ///
  /// Zero until the backend has reported any, which takes a few frames. The
  /// median of the last handful rather than the mean, because a mean is
  /// dragged about by the one frame in thirty that hits a hitch, and what
  /// anybody wants to know is what a frame usually costs.
  ///
  /// This rather than a frame rate: how often a frame is presented is the
  /// display's business, and a renderer with twice the headroom it needs looks
  /// exactly the same there.
  static Future<double> gpuMilliseconds(int textureId) async {
    final stats = await _OrbisViewState._channel
        .invokeMapMethod<String, Object?>('stats', {'textureId': textureId});
    final cost = stats?['gpuMilliseconds'];
    return cost is num ? cost.toDouble() : 0;
  }

  /// What each pass of the last frame cost, in the order they ran.
  ///
  /// The point of declaring passes rather than hard-coding them: which passes
  /// ran, in what order, and what each cost are the three questions asked of a
  /// renderer that is too slow, and a fixed pipeline cannot answer any of them
  /// without being instrumented by hand every time somebody asks.
  ///
  /// [passNames] is [OrbisScene.passNames] for the scene that was drawn. The
  /// names never cross the channel: they are already on this side, and sending
  /// the same strings sixty times a second to label numbers that arrive in a
  /// known order is work for nothing. A scene whose graph has changed since
  /// the last frame gets a capture labelled with the graph it asked about,
  /// which is why the names come from the caller rather than from a field.
  static Future<OrbisFrameCapture> capture(
    int textureId,
    List<String> passNames,
  ) async {
    final stats = await _OrbisViewState._channel
        .invokeMapMethod<String, Object?>('stats', {'textureId': textureId});

    final timings = stats?['passTimings'];
    if (timings is! List) return const OrbisFrameCapture();

    // Two numbers rather than one per pass, because batching is decided once
    // per publish and every pass then draws whatever that decision left it.
    // Absent from a renderer that has never heard of batching, which is why
    // they are read defensively rather than indexed.
    final batching = stats?['batching'];
    final batched = batching is List && batching.isNotEmpty
        ? batching.first
        : null;
    final groups = batching is List && batching.length > 1 ? batching[1] : null;

    return OrbisFrameCapture.from(
      Float32List.fromList([
        for (final value in timings)
          if (value is num) value.toDouble(),
      ]),
      passNames,
      batchedObjects: batched is num ? batched.toInt() : 0,
      batchGroups: groups is num ? groups.toInt() : 0,
    );
  }

  @override
  State<OrbisView> createState() => _OrbisViewState();
}

class _OrbisViewState extends State<OrbisView> {
  static const MethodChannel _channel = MethodChannel('orbis_filament');

  int? _textureId;
  Size? _surfaceSize;
  bool _creating = false;
  Object? _error;
  OrbisScene? _sentScene;

  @override
  void didUpdateWidget(OrbisView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.scene, _sentScene)) _sendScene();
  }

  /// Pushes the current scene to the native surface, if there is one of each.
  /// Which revision of each population's buffers the renderer already holds.
  ///
  /// Kept here rather than on the scene because it is a fact about this
  /// renderer, not about the scene: two views of the same scene have had
  /// different things sent to them.
  final Map<int, int> _sentRevisions = {};

  /// The same, for splat clouds held in memory.
  final Map<int, int> _sentSplatRevisions = {};

  Duration _stamp = Duration.zero;

  /// This frame's moment, in seconds, on Flutter's own clock.
  ///
  /// The same clock a ticker hands out, which is the one anything animating —
  /// including the camera — was worked out on.
  ///
  /// Only asked for during a frame. Outside one there is no current frame and
  /// asking throws, which is worth being careful about: this is inside the
  /// send, the send is inside a try, and a throw here would quietly stop the
  /// scene being sent at all rather than showing up as anything. The last
  /// frame's answer is the right fallback — it means no motion was seen
  /// between two sends, which is true.
  double _frameSeconds() {
    final binding = SchedulerBinding.instance;
    if (binding.schedulerPhase != SchedulerPhase.idle) {
      _stamp = binding.currentFrameTimeStamp;
    }
    return _stamp.inMicroseconds / 1e6;
  }

  Future<void> _sendScene() async {
    final id = _textureId;
    final scene = widget.scene;
    if (id == null || scene == null || _error != null) return;
    _sentScene = scene;
    try {
      final notes = await _channel.invokeMapMethod<String, String>(
        'setScene',
        scene.toMessage(
          id,
          sentRevisions: _sentRevisions,
          sentSplatRevisions: _sentSplatRevisions,
          // The frame's own timestamp, which is the clock everything in the
          // frame was worked out on — including wherever the camera decided
          // to be.
          at: _frameSeconds(),
        ),
      );

      // Only after it has landed. A send that threw left the renderer with
      // whatever it had, and claiming otherwise would leave a population
      // frozen at an old shape with nothing to put it right.
      for (final population in scene.populations) {
        _sentRevisions[population.key] = population.revision;
      }
      _sentRevisions.removeWhere(
        (key, _) => !scene.populations.any((p) => p.key == key),
      );
      _sentSplatRevisions
        ..clear()
        ..addAll({
          for (final cloud in scene.splats)
            if (cloud.data != null) cloud.key: cloud.revision,
        });
      if (notes != null && notes.isNotEmpty) {
        widget.onSceneNotes?.call(notes);
      }
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  void dispose() {
    final id = _textureId;
    if (id != null) {
      // Fire and forget: the surface outlives this widget by a frame or two,
      // and there is nothing useful to do with a failure during teardown.
      _channel.invokeMethod<void>('dispose', {'textureId': id});
    }
    super.dispose();
  }

  /// Brings the native surface in line with the size Flutter just laid out.
  Future<void> _sync(Size pixels) async {
    if (_error != null || pixels.isEmpty) return;

    if (_textureId == null) {
      if (_creating) return;
      _creating = true;
      try {
        final id = await _channel.invokeMethod<int>('create', {
          'width': pixels.width.round(),
          'height': pixels.height.round(),
        });
        if (!mounted) {
          if (id != null) {
            await _channel.invokeMethod<void>('dispose', {'textureId': id});
          }
          return;
        }
        setState(() {
          _textureId = id;
          _surfaceSize = pixels;
        });
        if (id != null) widget.onViewport?.call(id);
        // The surface did not exist when the scene was first set, so it is
        // sent now rather than waiting for the next change — otherwise a
        // static scene would never appear at all.
        await _sendScene();
      } catch (error) {
        if (mounted) setState(() => _error = error);
      } finally {
        _creating = false;
      }
      return;
    }

    if (pixels != _surfaceSize) {
      _surfaceSize = pixels;
      await _channel.invokeMethod<void>('resize', {
        'textureId': _textureId,
        'width': pixels.width.round(),
        'height': pixels.height.round(),
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Where the renderer's native side exists. Both Apple platforms share
    // one implementation — the same Filament, the same Metal backend, the
    // same CVPixelBuffer handed to the texture registry — so this is a list
    // rather than a single platform, and the rest grows it as they land.
    // Android's implementation is the same renderer and the same channel
    // protocol behind a Kotlin/JNI plugin instead of Swift's, presenting
    // into a Flutter SurfaceProducer texture rather than a CVPixelBuffer —
    // see packages/orbis_filament/android/.
    // The web is asked about separately, and first, because
    // defaultTargetPlatform reports the *host* operating system in a browser:
    // Chrome on a Mac answers macOS, which would pass this set and then build
    // a Texture the web has no registry for. There the renderer is the same
    // core compiled to WebAssembly, drawing into its own canvas — see
    // lib/src/web/ and packages/orbis_filament/native/web/.
    const drawable = {
      TargetPlatform.macOS,
      TargetPlatform.iOS,
      TargetPlatform.android,
    };
    if (!kIsWeb && !drawable.contains(defaultTargetPlatform)) {
      return const _Notice(
        'Orbis renders on macOS, iOS, Android and the web so far.',
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // The surface is sized in physical pixels, so a 3D view on a Retina
        // display is not quietly rendered at half resolution and upscaled.
        final ratio = MediaQuery.devicePixelRatioOf(context);
        final pixels = Size(
          constraints.maxWidth * ratio,
          constraints.maxHeight * ratio,
        );

        // Layout is not the place to talk to the platform, so the reconcile
        // happens once this frame is on screen. It no-ops unless size moved.
        WidgetsBinding.instance.addPostFrameCallback((_) => _sync(pixels));

        final error = _error;
        if (error != null) return _Notice('$error');

        final id = _textureId;
        if (id == null) {
          return const ColoredBox(
            color: Color(0xFF1A1E28),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        // On the web the renderer owns a <canvas> and draws into it directly,
        // shown here as a platform view; there is no external texture for
        // Flutter to adopt. The id `create` answered with travels as the
        // view's creation params, which is how the factory in
        // lib/src/web/orbis_filament_web.dart finds the viewport it belongs
        // to — a platform view's own id is minted separately by Flutter and
        // never reaches the plugin.
        return kIsWeb
            ? HtmlElementView(viewType: orbisWebViewType, creationParams: id)
            : Texture(textureId: id);
      },
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF1A1E28),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFFE58A4B), fontSize: 13),
          ),
        ),
      ),
    );
  }
}
