// Orbis Android spike: a picker for the backend, then Filament's output in a
// Texture widget with an ordinary Flutter label drawn over it. The label is
// the proof that matters as much as the cube -- it shows the compositor is
// treating the texture as one layer among others, not the whole screen.
import 'dart:async';

import 'package:flutter/material.dart';

import 'package:filament_surface/filament_surface.dart';

void main() {
  runApp(const SpikeApp());
}

class SpikeApp extends StatelessWidget {
  const SpikeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Orbis Android Spike',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      debugShowCheckedModeBanner: false,
      home: const SpikeHome(),
    );
  }
}

class SpikeHome extends StatefulWidget {
  const SpikeHome({super.key});

  @override
  State<SpikeHome> createState() => _SpikeHomeState();
}

class _SpikeHomeState extends State<SpikeHome> {
  FilamentBackend? _backend;
  int? _textureId;
  Map<String, Object?> _info = const {};
  Map<String, Object?> _stats = const {};
  String? _error;
  Timer? _poll;

  Future<void> _startWith(FilamentBackend backend) async {
    setState(() => _error = null);
    try {
      final info = await FilamentSurface.start(backend: backend);
      if (!mounted) return;
      setState(() {
        _backend = backend;
        _textureId = (info['textureId'] as num?)?.toInt();
        _info = info;
      });
      _poll?.cancel();
      _poll = Timer.periodic(const Duration(milliseconds: 500), (_) => _refresh());
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  Future<void> _refresh() async {
    if (_backend == null) return;
    try {
      final info = await FilamentSurface.describe();
      final stats = await FilamentSurface.stats();
      if (!mounted) return;
      setState(() {
        _info = info;
        _stats = stats;
      });
    } catch (_) {
      // Between a stop() and the next poll's cancellation this can hit a
      // torn-down session; nothing to show for it, and the next poll after a
      // fresh start replaces it.
    }
  }

  Future<void> _recreateSurface() async {
    try {
      final info = await FilamentSurface.recreateSurface();
      if (!mounted) return;
      setState(() => _info = info);
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  Future<void> _back() async {
    _poll?.cancel();
    _poll = null;
    await FilamentSurface.stop();
    if (!mounted) return;
    setState(() {
      _backend = null;
      _textureId = null;
      _info = const {};
      _stats = const {};
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    FilamentSurface.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: _backend == null ? _buildPicker() : _buildRenderer(),
      ),
    );
  }

  Widget _buildPicker() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Orbis Android Spike',
            style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'Filament → ANativeWindow → Flutter texture',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: 32),
          if (_error != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                _error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 16),
          ],
          SizedBox(
            width: 260,
            height: 64,
            child: ElevatedButton(
              key: const Key('start_opengl'),
              onPressed: () => _startWith(FilamentBackend.openGL),
              child: const Text('OpenGL ES', style: TextStyle(fontSize: 18)),
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: 260,
            height: 64,
            child: ElevatedButton(
              key: const Key('start_vulkan'),
              onPressed: () => _startWith(FilamentBackend.vulkan),
              child: const Text('Vulkan', style: TextStyle(fontSize: 18)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRenderer() {
    final id = _textureId;
    return Column(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (id != null) Texture(textureId: id) else const ColoredBox(color: Colors.black),
              Positioned(
                left: 12,
                right: 12,
                top: 12,
                child: _InfoPanel(info: _info, stats: _stats),
              ),
              // Ordinary Flutter content drawn over the texture: if this
              // label is crisp and the cube behind it still turns, the
              // compositor is treating them as separate layers correctly.
              const Positioned(
                bottom: 12,
                left: 0,
                right: 0,
                child: Center(
                  child: Text(
                    'drawn by Flutter, not Filament',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      shadows: [Shadow(blurRadius: 6, color: Colors.black)],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    key: const Key('recreate_surface'),
                    onPressed: _recreateSurface,
                    child: const Text('Recreate surface'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    key: const Key('back'),
                    onPressed: _back,
                    child: const Text('Back'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _InfoPanel extends StatelessWidget {
  const _InfoPanel({required this.info, required this.stats});

  final Map<String, Object?> info;
  final Map<String, Object?> stats;

  @override
  Widget build(BuildContext context) {
    final lines = <String>[
      'backend=${info['backend'] ?? '?'}  size=${info['size'] ?? '?'}  gen=${info['surfaceGeneration'] ?? '?'}',
      'activeFL=${info['activeFeatureLevel'] ?? '?'}  supportedFL=${info['supportedFeatureLevel'] ?? '?'}  FL3=${info['featureLevel3Available'] ?? '?'}',
      'available=${info['surfaceAvailableCount'] ?? '?'}  cleanup=${info['surfaceCleanupCount'] ?? '?'}  '
          'forcedReattach=${info['forcedReattachCount'] ?? '?'}',
      'lastEvent=${info['lastLifecycleEvent'] ?? '?'}',
      'fps=${stats['fps'] ?? '?'}  rendered=${stats['renderedFrames'] ?? '?'}  skipped=${stats['skippedFrames'] ?? '?'}  '
          'worstMs=${stats['worstFrameIntervalMs'] ?? '?'}',
    ];
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final line in lines)
            Text(
              line,
              style: const TextStyle(color: Colors.white, fontSize: 11, fontFamily: 'monospace'),
            ),
        ],
      ),
    );
  }
}
