import 'package:flutter/material.dart';
import 'package:orbis_filament/orbis_filament.dart';

void main() => runApp(const ViewportApp());

class ViewportApp extends StatelessWidget {
  const ViewportApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Orbis Viewport',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFC25E22),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF111419),
      ),
      home: const ViewportPage(),
    );
  }
}

/// The M1 proof: a Filament scene laid out as a widget among widgets.
///
/// The point of the surrounding chrome is not decoration. A platform view
/// would sit in its own window on top of everything; a texture takes part in
/// layout, so the panel can overlap it, the slider can resize it, and the
/// whole thing clips to a rounded rectangle.
class ViewportPage extends StatefulWidget {
  const ViewportPage({super.key});

  @override
  State<ViewportPage> createState() => _ViewportPageState();
}

class _ViewportPageState extends State<ViewportPage> {
  double _split = 0.62;
  bool _showOverlay = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _TitleBar(),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  flex: (_split * 100).round(),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          const OrbisView(),
                          if (_showOverlay)
                            const Positioned(
                              left: 14,
                              bottom: 14,
                              child: _Badge('Filament → CVPixelBuffer → Texture'),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                Expanded(
                  flex: 100 - (_split * 100).round(),
                  child: _Panel(
                    split: _split,
                    onSplit: (value) => setState(() => _split = value),
                    showOverlay: _showOverlay,
                    onOverlay: (value) => setState(() => _showOverlay = value),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TitleBar extends StatelessWidget {
  const _TitleBar();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 30, 18, 10),
      child: Row(
        children: [
          Text(
            'Orbis',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                ),
          ),
          const SizedBox(width: 10),
          const _Badge('M1 · macOS viewport'),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.split,
    required this.onSplit,
    required this.showOverlay,
    required this.onOverlay,
  });

  final double split;
  final ValueChanged<double> onSplit;
  final bool showOverlay;
  final ValueChanged<bool> onOverlay;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 16, 16),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF181C23),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF2C333E)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Inspector',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
              ),
              const SizedBox(height: 6),
              const Text(
                'Ordinary Flutter widgets, laid out beside a Filament surface '
                'in the same tree. Dragging the split resizes the render '
                'target, not just its box.',
                style: TextStyle(fontSize: 12.5, height: 1.5, color: Color(0xFF8A94A3)),
              ),
              const SizedBox(height: 22),
              const Text('Viewport width', style: TextStyle(fontSize: 12)),
              Slider(
                value: split,
                min: 0.25,
                max: 0.85,
                onChanged: onSplit,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Overlay label', style: TextStyle(fontSize: 12)),
                value: showOverlay,
                onChanged: onOverlay,
              ),
              const Spacer(),
              const Text(
                'The cube spins on a display link in native code. Flutter pulls '
                'the finished IOSurface each frame rather than being pushed '
                'pixels through the CPU.',
                style: TextStyle(fontSize: 11.5, height: 1.5, color: Color(0xFF6E7A8C)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xCC1F242D),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: const Color(0xFF2C333E)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 10.5,
          letterSpacing: 0.4,
          color: Color(0xFFA6B0BF),
        ),
      ),
    );
  }
}
