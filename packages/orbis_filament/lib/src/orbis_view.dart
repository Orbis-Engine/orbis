import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'scene.dart';

/// A Filament-rendered surface, laid out and composited like any other widget.
///
/// The 3D content is a real Flutter texture, so it clips, scrolls, sits under
/// other widgets and takes part in layout the way a [Container] does. That is
/// the whole point of routing Filament through the texture registry rather
/// than a platform view.
class OrbisView extends StatefulWidget {
  const OrbisView({super.key, this.scene, this.onSceneNotes});

  /// What to draw. While this is null the renderer shows its own placeholder,
  /// so an unconfigured view is visibly working rather than merely blank.
  final OrbisScene? scene;

  /// Called with anything the scene asked for that could not be given: a mesh
  /// file that would not load, a light the view has no room to shade. Subject
  /// to reason, so a host can say which rather than that something went
  /// wrong.
  final ValueChanged<Map<String, String>>? onSceneNotes;

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
    if (defaultTargetPlatform != TargetPlatform.macOS) {
      return const _Notice('Orbis renders on macOS only so far.');
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
        return Texture(textureId: id);
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
