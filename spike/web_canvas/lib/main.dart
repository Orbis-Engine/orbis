// The spike's Flutter app: a Filament canvas as a platform view, ordinary
// Flutter widgets drawn over it, and a slider that drives the scene from Dart.
//
// What each part is there to prove:
//  - HtmlElementView puts Filament's <canvas> in the widget tree, and the
//    Flutter-drawn label and panel sit *over* it, so Flutter is compositing
//    its own painting with the platform view rather than one hiding the other.
//  - The slider sends a scene message from Dart through dart:js_interop,
//    which is the shape the real scene message will take.
//  - The readouts report what Filament says about the device it got, so a
//    screenshot is evidence rather than a picture of a cube.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'filament_canvas.dart';
import 'scene_message.dart';

/// The Orbis entity id of the one primitive in the scene, matching the CUBE
/// the JavaScript renderer knows.
const int cubeEntity = 1;

void main() {
  // Before runApp: the factory has to be registered before any widget can
  // ask for the view type.
  registerFilamentCanvas();
  runApp(const SpikeApp());
}

class SpikeApp extends StatelessWidget {
  const SpikeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Orbis web canvas spike',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4C7DF0),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0E1013),
      ),
      home: const SpikePage(),
    );
  }
}

class SpikePage extends StatefulWidget {
  const SpikePage({super.key});

  @override
  State<SpikePage> createState() => _SpikePageState();
}

class _SpikePageState extends State<SpikePage> {
  FilamentCanvas? _canvas;
  FilamentStats? _stats;
  Timer? _poll;
  Object? _error;

  /// Colour as a hue in degrees, and spin in radians a second. Both start at
  /// whatever the JavaScript renderer already set, so that until Dart sends
  /// something the cube is the renderer's own orange and the message count is
  /// zero: the difference a Dart message makes is then unambiguous.
  double _hue = 14;
  double _spin = 0.8;

  /// How many messages this widget has sent. Read back from the renderer's
  /// own count too, so the two agreeing shows the crossing really happened.
  int _sent = 0;

  /// Set from the query string when the headless capture asks for a
  /// particular colour and speed, so one shot can show a Dart-driven change
  /// without anyone touching the slider.
  bool _drivenFromQuery = false;

  @override
  void initState() {
    super.initState();
    final query = Uri.base.queryParameters;
    final hue = double.tryParse(query['hue'] ?? '');
    final spin = double.tryParse(query['spin'] ?? '');
    if (hue != null) {
      _hue = hue.clamp(0, 360);
      _drivenFromQuery = true;
    }
    if (spin != null) {
      _spin = spin.clamp(0, 8);
      _drivenFromQuery = true;
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _canvas?.dispose();
    super.dispose();
  }

  Future<void> _onViewCreated(int viewId) async {
    try {
      final canvas = await FilamentCanvas.forView(viewId);
      if (!mounted) {
        canvas.dispose();
        return;
      }
      setState(() => _canvas = canvas);
      // Anything the query string asked for is sent as soon as the renderer
      // exists, which is the capture's Dart-driven shot.
      if (_drivenFromQuery) _send();
      _poll = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (!mounted) return;
        setState(() => _stats = canvas.stats);
      });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  /// The whole Dart to JavaScript path in one place: build a scene message,
  /// hand it over as bytes. Nothing about Filament appears in Dart.
  void _send() {
    final canvas = _canvas;
    if (canvas == null) return;
    final colour = HSVColor.fromAHSV(1, _hue, 0.78, 0.92).toColor();
    canvas.send(
      SceneMessage()
        ..setBaseColour(
          cubeEntity,
          colour.r,
          colour.g,
          colour.b,
        )
        ..setSpin(cubeEntity, _spin),
    );
    _sent++;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _Header(),
              const SizedBox(height: 12),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // The platform view: Filament's <canvas>, drawn into by
                      // WebAssembly, sitting in the Flutter widget tree.
                      HtmlElementView(
                        viewType: filamentViewType,
                        onPlatformViewCreated: _onViewCreated,
                      ),
                      // Everything below this line is painted by Flutter, over
                      // the canvas. That it is legible over a rendered frame is
                      // the compositing proof.
                      const Positioned(
                        left: 16,
                        top: 16,
                        child: _CompositingLabel(),
                      ),
                      Positioned(
                        right: 16,
                        top: 16,
                        child: _StatsPanel(stats: _stats, error: _error),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _Controls(
                hue: _hue,
                spin: _spin,
                sent: _sent,
                enabled: _canvas != null,
                onHue: (value) => setState(() {
                  _hue = value;
                  _send();
                }),
                onSpin: (value) => setState(() {
                  _spin = value;
                  _send();
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.language, size: 20, color: Color(0xFF7FA8FF)),
        const SizedBox(width: 8),
        Text(
          'Orbis web spike',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            'Filament 1.76 (WebAssembly) drawing into a canvas in a Flutter web app',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.white54,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// A Flutter-painted label over the canvas. Deliberately a Flutter widget with
/// a Flutter font and a Flutter shadow: if this is readable on top of a
/// Filament frame, the two are composited.
class _CompositingLabel extends StatelessWidget {
  const _CompositingLabel();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white24),
      ),
      child: const Text(
        'Flutter widget, over the Filament canvas',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Color(0xFFEAF0FF),
        ),
      ),
    );
  }
}

/// What Filament reports about the device it actually got. On WebGL 2 the
/// feature level here is the number that decides whether Orbis's standard lit
/// surface can load at all, so it is on screen rather than in a log.
class _StatsPanel extends StatelessWidget {
  const _StatsPanel({required this.stats, required this.error});

  final FilamentStats? stats;
  final Object? error;

  @override
  Widget build(BuildContext context) {
    final s = stats;
    return Container(
      constraints: const BoxConstraints(maxWidth: 330),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white24),
      ),
      child: DefaultTextStyle(
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 11.5,
          height: 1.5,
          color: Color(0xFFB9E6C4),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (error != null)
              Text(
                'renderer failed:\n$error',
                style: const TextStyle(color: Color(0xFFFF9C9C), fontSize: 11.5),
              )
            else if (s == null)
              const Text('waiting for Filament…')
            else ...[
              _Row('backend', s.backend),
              _Row('feature level', '${s.activeFeatureLevel} of ${s.supportedFeatureLevel} supported'),
              _Row('GL', s.glVersion),
              _Row('device', s.glRenderer),
              _Row('drawing buffer', '${s.width} x ${s.height}'),
              _Row('frames drawn', '${s.frames}'),
              _Row('messages from Dart', '${s.messages}'),
            ],
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 118,
          child: Text('$label ', style: const TextStyle(color: Colors.white54)),
        ),
        Expanded(child: Text(value)),
      ],
    );
  }
}

/// The Dart-driven half: two sliders, each sending a scene message.
class _Controls extends StatelessWidget {
  const _Controls({
    required this.hue,
    required this.spin,
    required this.sent,
    required this.enabled,
    required this.onHue,
    required this.onSpin,
  });

  final double hue;
  final double spin;
  final int sent;
  final bool enabled;
  final ValueChanged<double> onHue;
  final ValueChanged<double> onSpin;

  @override
  Widget build(BuildContext context) {
    final colour = HSVColor.fromAHSV(1, hue, 0.78, 0.92).toColor();
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF171A1F),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: colour,
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: Colors.white24),
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'Driven from Dart',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'SceneMessage bytes over dart:js_interop  ·  $sent sent',
                  style: const TextStyle(fontSize: 12, color: Colors.white54),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: _Slider(
                  label: 'base colour',
                  value: hue,
                  min: 0,
                  max: 360,
                  display: '${hue.round()}°',
                  onChanged: enabled ? onHue : null,
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: _Slider(
                  label: 'spin',
                  value: spin,
                  min: 0,
                  max: 4,
                  display: '${spin.toStringAsFixed(2)} rad/s',
                  onChanged: enabled ? onSpin : null,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Slider extends StatelessWidget {
  const _Slider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.display,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String display;
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 82,
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, color: Colors.white70),
          ),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 78,
          child: Text(
            display,
            textAlign: TextAlign.right,
            style: const TextStyle(
              fontSize: 12,
              fontFamily: 'monospace',
              color: Colors.white70,
            ),
          ),
        ),
      ],
    );
  }
}
